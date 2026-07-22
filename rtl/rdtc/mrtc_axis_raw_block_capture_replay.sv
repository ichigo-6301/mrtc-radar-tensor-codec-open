module mrtc_axis_raw_block_capture_replay #(
  parameter int AXIS_DATA_W = mrtc_pkg::MRTC_AXIS_DATA_W,
  parameter int TUSER_W = 8,
  parameter int BLOCK_BEATS = mrtc_pkg::MRTC_BLOCK_BEATS,
  parameter int BLOCK_WORDS = BLOCK_BEATS,
  parameter int CAPTURE_SLOTS_PER_ENGINE = 2,
`ifdef RDTC_ICARUS
  parameter RAM_STYLE = "block",
`else
  parameter string RAM_STYLE = "block",
`endif
  parameter int WORD_ADDR_W = (BLOCK_BEATS <= 1) ? 1 : $clog2(BLOCK_BEATS),
  parameter int SLOT_W = (CAPTURE_SLOTS_PER_ENGINE <= 1) ? 1 : $clog2(CAPTURE_SLOTS_PER_ENGINE)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,
  input  logic                   i_replay_start_ready,

  input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,
  input  logic [TUSER_W-1:0]     s_axis_tuser,

  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic [TUSER_W-1:0]     m_axis_tuser,

  output logic [31:0]            stat_capture_accepted_blocks,
  output logic [31:0]            stat_replay_started_blocks,
  output logic [31:0]            stat_replay_completed_blocks,
  output logic [31:0]            stat_slot_full_cycles,
  output logic [31:0]            stat_active_input_bubble_cycles,
  output logic [31:0]            stat_metadata_mismatch_count,
  output logic [31:0]            stat_error_flags,
  output logic [3:0]             stat_current_occupancy_slots,
  output logic [3:0]             stat_max_occupancy_slots,
  output logic [1:0]             stat_slot0_state,
  output logic [1:0]             stat_slot1_state
);
  import mrtc_pkg::*;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int AXIS_BYTE_ALIGN_CHECK = 1 / (((AXIS_DATA_W % 8) == 0) ? 1 : 0);
  localparam int AXIS_SAMPLE_ALIGN_CHECK =
    1 / (((AXIS_DATA_W % MRTC_COMPLEX_SAMPLE_W) == 0) ? 1 : 0);
  localparam int TUSER_CHECK = 1 / ((TUSER_W == 8) ? 1 : 0);
  localparam int BLOCK_CHECK = 1 / ((BLOCK_WORDS == BLOCK_BEATS) ? 1 : 0);
  localparam int SLOT_CHECK =
    1 / (((CAPTURE_SLOTS_PER_ENGINE == 1) ||
          (CAPTURE_SLOTS_PER_ENGINE == 2)) ? 1 : 0);
  localparam int MEM_DEPTH = CAPTURE_SLOTS_PER_ENGINE * BLOCK_BEATS;
  localparam int MEM_ADDR_W = (MEM_DEPTH <= 1) ? 1 : $clog2(MEM_DEPTH);
  localparam int READY_COUNT_W = $clog2(CAPTURE_SLOTS_PER_ENGINE + 1);

  localparam int ERR_TLAST_EARLY = 0;
  localparam int ERR_TLAST_MISSING = 1;
  localparam int ERR_METADATA_MISMATCH = 2;

  typedef enum logic [1:0] {
    SLOT_FREE      = 2'd0,
    SLOT_FILLING   = 2'd1,
    SLOT_READY     = 2'd2,
    SLOT_REPLAYING = 2'd3
  } slot_state_t;

  function automatic logic [MEM_ADDR_W-1:0] slot_word_addr(
    input logic [SLOT_W-1:0] slot_id,
    input logic [WORD_ADDR_W-1:0] word_id
  );
    slot_word_addr = MEM_ADDR_W'((slot_id * BLOCK_BEATS) + word_id);
  endfunction

  function automatic logic [SLOT_W-1:0] next_slot_ptr(
    input logic [SLOT_W-1:0] slot_id
  );
    if (slot_id == SLOT_W'(CAPTURE_SLOTS_PER_ENGINE - 1)) begin
      next_slot_ptr = '0;
    end else begin
      next_slot_ptr = slot_id + SLOT_W'(1);
    end
  endfunction

`ifdef MRTC_FPGA_XILINX
  (* ram_style = RAM_STYLE *)
`endif
  logic [AXIS_DATA_W-1:0] slot_mem [0:MEM_DEPTH-1];

  slot_state_t slot_state_reg [0:CAPTURE_SLOTS_PER_ENGINE-1];
  logic [TUSER_W-1:0] slot_tuser_reg [0:CAPTURE_SLOTS_PER_ENGINE-1];
  logic [SLOT_W-1:0] ready_slot_queue_reg [0:CAPTURE_SLOTS_PER_ENGINE-1];
  logic [SLOT_W-1:0] ready_wr_ptr_reg;
  logic [SLOT_W-1:0] ready_rd_ptr_reg;
  logic [READY_COUNT_W-1:0] ready_count_reg;

  logic fill_active_reg;
  logic [SLOT_W-1:0] fill_slot_reg;
  logic [WORD_ADDR_W-1:0] fill_word_index_reg;

  logic replay_slot_active_reg;
  logic [SLOT_W-1:0] replay_slot_reg;
  logic [WORD_ADDR_W-1:0] replay_issue_word_index_reg;
  logic replay_issue_done_reg;
  logic replay_out_valid_reg;
  logic [AXIS_DATA_W-1:0] replay_out_data_reg;
  logic replay_out_last_reg;
  logic [TUSER_W-1:0] replay_out_tuser_reg;

  logic free_available;
  logic [SLOT_W-1:0] free_slot_comb;
  logic ready_available;
  logic [SLOT_W-1:0] ready_slot_comb;
  logic [3:0] occupancy_comb;
  logic [SLOT_W-1:0] capture_slot_comb;
  logic [WORD_ADDR_W-1:0] capture_addr_comb;
  logic capture_accept;
  logic replay_accept;
  logic can_refill_output_comb;
  logic can_start_new_replay_comb;
  logic issue_read_comb;
  logic issue_from_current_comb;
  logic [SLOT_W-1:0] issue_slot_comb;
  logic [WORD_ADDR_W-1:0] issue_word_comb;
  logic issue_last_comb;
  logic complete_current_replay_comb;
  logic capture_complete_comb;
  logic start_new_replay_comb;

  always_comb begin
    free_available = 1'b0;
    free_slot_comb = '0;
    ready_available = (ready_count_reg != READY_COUNT_W'(0));
    ready_slot_comb = ready_slot_queue_reg[ready_rd_ptr_reg];
    occupancy_comb = 4'd0;

    for (int slot = 0; slot < CAPTURE_SLOTS_PER_ENGINE; slot++) begin
      if (slot_state_reg[slot] != SLOT_FREE) begin
        occupancy_comb = occupancy_comb + 4'd1;
      end
      if (!free_available && (slot_state_reg[slot] == SLOT_FREE)) begin
        free_available = 1'b1;
        free_slot_comb = SLOT_W'(slot);
      end
    end
  end

  assign capture_slot_comb = fill_active_reg ? fill_slot_reg : free_slot_comb;
  assign capture_addr_comb = fill_active_reg ? fill_word_index_reg : '0;
  assign s_axis_tready = fill_active_reg ? 1'b1 : free_available;
  assign capture_accept = s_axis_tvalid && s_axis_tready;

  assign m_axis_tvalid = rst_n && replay_out_valid_reg;
  assign m_axis_tdata = rst_n ? replay_out_data_reg : '0;
  assign m_axis_tlast = rst_n && replay_out_last_reg;
  assign m_axis_tuser = rst_n ? replay_out_tuser_reg : '0;
  assign replay_accept = m_axis_tvalid && m_axis_tready;

  assign can_refill_output_comb = !replay_out_valid_reg || replay_accept;
  assign complete_current_replay_comb = replay_accept && replay_out_last_reg;
  assign can_start_new_replay_comb =
    can_refill_output_comb &&
    i_replay_start_ready &&
    ready_available &&
    (!replay_slot_active_reg || complete_current_replay_comb);
  assign issue_from_current_comb =
    can_refill_output_comb &&
    replay_slot_active_reg &&
    !replay_issue_done_reg;
  assign issue_read_comb = issue_from_current_comb || can_start_new_replay_comb;
  assign issue_slot_comb = issue_from_current_comb ? replay_slot_reg : ready_slot_comb;
  assign issue_word_comb = issue_from_current_comb ? replay_issue_word_index_reg : '0;
  assign issue_last_comb = (issue_word_comb == WORD_ADDR_W'(BLOCK_BEATS - 1));
  assign capture_complete_comb =
    capture_accept && (capture_addr_comb == WORD_ADDR_W'(BLOCK_BEATS - 1));
  assign start_new_replay_comb = issue_read_comb && !issue_from_current_comb;

  assign stat_current_occupancy_slots = occupancy_comb;
  assign stat_slot0_state = slot_state_reg[0];
  generate
    if (CAPTURE_SLOTS_PER_ENGINE > 1) begin : g_slot1_state
      assign stat_slot1_state = slot_state_reg[1];
    end else begin : g_no_slot1_state
      assign stat_slot1_state = SLOT_FREE;
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int slot = 0; slot < CAPTURE_SLOTS_PER_ENGINE; slot++) begin
        slot_state_reg[slot] <= SLOT_FREE;
        slot_tuser_reg[slot] <= '0;
        ready_slot_queue_reg[slot] <= '0;
      end
      ready_wr_ptr_reg <= '0;
      ready_rd_ptr_reg <= '0;
      ready_count_reg <= '0;
      fill_active_reg <= 1'b0;
      fill_slot_reg <= '0;
      fill_word_index_reg <= '0;
      replay_slot_active_reg <= 1'b0;
      replay_slot_reg <= '0;
      replay_issue_word_index_reg <= '0;
      replay_issue_done_reg <= 1'b0;
      stat_capture_accepted_blocks <= 32'd0;
      stat_replay_started_blocks <= 32'd0;
      stat_replay_completed_blocks <= 32'd0;
      stat_slot_full_cycles <= 32'd0;
      stat_active_input_bubble_cycles <= 32'd0;
      stat_metadata_mismatch_count <= 32'd0;
      stat_error_flags <= 32'd0;
      stat_max_occupancy_slots <= 4'd0;
    end else begin
      if (i_clear_status) begin
        stat_capture_accepted_blocks <= 32'd0;
        stat_replay_started_blocks <= 32'd0;
        stat_replay_completed_blocks <= 32'd0;
        stat_slot_full_cycles <= 32'd0;
        stat_active_input_bubble_cycles <= 32'd0;
        stat_metadata_mismatch_count <= 32'd0;
        stat_error_flags <= 32'd0;
        stat_max_occupancy_slots <= occupancy_comb;
      end else begin
        if (occupancy_comb > stat_max_occupancy_slots) begin
          stat_max_occupancy_slots <= occupancy_comb;
        end

        if (s_axis_tvalid && !s_axis_tready) begin
          stat_slot_full_cycles <= stat_slot_full_cycles + 32'd1;
          if (fill_active_reg) begin
            stat_active_input_bubble_cycles <= stat_active_input_bubble_cycles + 32'd1;
          end
        end

        if (capture_accept && fill_active_reg &&
            (s_axis_tuser[3:1] != slot_tuser_reg[capture_slot_comb][3:1])) begin
            stat_metadata_mismatch_count <= stat_metadata_mismatch_count + 32'd1;
            stat_error_flags[ERR_METADATA_MISMATCH] <= 1'b1;
        end

        if (capture_accept) begin
          if (s_axis_tlast && (capture_addr_comb != WORD_ADDR_W'(BLOCK_BEATS - 1))) begin
            stat_error_flags[ERR_TLAST_EARLY] <= 1'b1;
          end
          if (!s_axis_tlast && (capture_addr_comb == WORD_ADDR_W'(BLOCK_BEATS - 1))) begin
            stat_error_flags[ERR_TLAST_MISSING] <= 1'b1;
          end

          if (capture_complete_comb) begin
            stat_capture_accepted_blocks <= stat_capture_accepted_blocks + 32'd1;
          end
        end

        if (complete_current_replay_comb) begin
          stat_replay_completed_blocks <= stat_replay_completed_blocks + 32'd1;
        end

        if (start_new_replay_comb) begin
          stat_replay_started_blocks <= stat_replay_started_blocks + 32'd1;
        end
      end

      if (capture_accept) begin
        if (!fill_active_reg) begin
          slot_state_reg[capture_slot_comb] <= SLOT_FILLING;
          fill_active_reg <= 1'b1;
          fill_slot_reg <= capture_slot_comb;
          fill_word_index_reg <= '0;
          slot_tuser_reg[capture_slot_comb] <= s_axis_tuser;
        end

        if (capture_complete_comb) begin
          slot_state_reg[capture_slot_comb] <= SLOT_READY;
          fill_active_reg <= 1'b0;
          fill_word_index_reg <= '0;
        end else begin
          fill_word_index_reg <= capture_addr_comb + WORD_ADDR_W'(1);
        end
      end

      if (complete_current_replay_comb) begin
        slot_state_reg[replay_slot_reg] <= SLOT_FREE;
        replay_slot_active_reg <= 1'b0;
        replay_issue_done_reg <= 1'b0;
        replay_issue_word_index_reg <= '0;
      end

      if (issue_read_comb) begin
        if (issue_from_current_comb) begin
          if (issue_last_comb) begin
            replay_issue_done_reg <= 1'b1;
          end else begin
            replay_issue_word_index_reg <= issue_word_comb + WORD_ADDR_W'(1);
          end
        end else begin
          replay_slot_active_reg <= 1'b1;
          replay_slot_reg <= issue_slot_comb;
          replay_issue_word_index_reg <= WORD_ADDR_W'(1);
          replay_issue_done_reg <= issue_last_comb;
          slot_state_reg[issue_slot_comb] <= SLOT_REPLAYING;
        end
      end

      case ({capture_complete_comb, start_new_replay_comb})
        2'b10: begin
          ready_slot_queue_reg[ready_wr_ptr_reg] <= capture_slot_comb;
          ready_wr_ptr_reg <= next_slot_ptr(ready_wr_ptr_reg);
          ready_count_reg <= ready_count_reg + READY_COUNT_W'(1);
        end
        2'b01: begin
          ready_rd_ptr_reg <= next_slot_ptr(ready_rd_ptr_reg);
          ready_count_reg <= ready_count_reg - READY_COUNT_W'(1);
        end
        2'b11: begin
          ready_slot_queue_reg[ready_wr_ptr_reg] <= capture_slot_comb;
          ready_wr_ptr_reg <= next_slot_ptr(ready_wr_ptr_reg);
          ready_rd_ptr_reg <= next_slot_ptr(ready_rd_ptr_reg);
        end
        default: begin
        end
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (capture_accept) begin
      slot_mem[slot_word_addr(capture_slot_comb, capture_addr_comb)] <= s_axis_tdata;
    end

    if (!rst_n) begin
      replay_out_valid_reg <= 1'b0;
    end else if (issue_read_comb) begin
      replay_out_valid_reg <= 1'b1;
      replay_out_data_reg <= slot_mem[slot_word_addr(issue_slot_comb, issue_word_comb)];
      replay_out_last_reg <= issue_last_comb;
      replay_out_tuser_reg <= slot_tuser_reg[issue_slot_comb];
    end else if (replay_accept) begin
      replay_out_valid_reg <= 1'b0;
    end
  end

  logic unused_static_checks;
  assign unused_static_checks = ^{1'b0, AXIS_BYTE_ALIGN_CHECK[0], AXIS_SAMPLE_ALIGN_CHECK[0],
                                  TUSER_CHECK[0], BLOCK_CHECK[0], SLOT_CHECK[0]};
endmodule
