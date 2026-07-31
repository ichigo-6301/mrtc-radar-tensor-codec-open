module mrtc_axis_payload_commit_store #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8,
  parameter int HEADER_BEATS = 4,
  parameter int MAX_PAYLOAD_BEATS = 256,
  parameter int PAYLOAD_DEPTH = 512,
  parameter int SLOT_COUNT = PAYLOAD_DEPTH / MAX_PAYLOAD_BEATS,
  parameter int OCC_W = $clog2(SLOT_COUNT + 1)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,

  input  logic                   i_reserve,
  output logic                   o_reserve_ready,
  input  logic                   i_commit,
  input  logic                   i_abort,

  input  logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input  logic                   s_axis_tvalid,
  output logic                   s_axis_tready,
  input  logic                   s_axis_tlast,
  input  logic [TUSER_W-1:0]     s_axis_tuser,

  output logic                   o_packet_valid,
  input  logic                   i_packet_start,
  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic [TUSER_W-1:0]     m_axis_tuser,

  output logic                   o_busy,
  output logic                   o_full,
  output logic                   o_overflow,
  output logic [31:0]            o_error,
  output logic [31:0]            o_packets_written,
  output logic [31:0]            o_packets_read,
  output logic [31:0]            o_write_stall_cycles,
  output logic [31:0]            o_read_stall_cycles,
  output logic [OCC_W-1:0]       o_max_occupancy
);
  import mrtc_pkg::*;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int SLOT_W = (SLOT_COUNT <= 1) ? 1 : $clog2(SLOT_COUNT);
  localparam int HEADER_COUNT_W = $clog2(HEADER_BEATS + 1);
  localparam int PAYLOAD_INDEX_W = $clog2(MAX_PAYLOAD_BEATS);
  localparam int PAYLOAD_COUNT_W = $clog2(MAX_PAYLOAD_BEATS + 1);
  localparam int PAYLOAD_ADDR_W = $clog2(PAYLOAD_DEPTH);
  localparam int PAYLOAD_FIFO_DEPTH = 3;
  localparam int PAYLOAD_FIFO_PTR_W = $clog2(PAYLOAD_FIFO_DEPTH);
  localparam int PAYLOAD_FIFO_COUNT_W = $clog2(PAYLOAD_FIFO_DEPTH + 1);
  localparam int AXIS_DATA_W_CHECK = 1 / ((AXIS_DATA_W == 128) ? 1 : 0);
  localparam int HEADER_BEATS_CHECK = 1 / ((HEADER_BEATS == 4) ? 1 : 0);
  localparam int PAYLOAD_DEPTH_CHECK =
    1 / (((PAYLOAD_DEPTH == MAX_PAYLOAD_BEATS) ||
          (PAYLOAD_DEPTH == (2 * MAX_PAYLOAD_BEATS))) ? 1 : 0);
  localparam int SLOT_COUNT_CHECK =
    1 / (((SLOT_COUNT == 1) || (SLOT_COUNT == 2)) ? 1 : 0);
  localparam int SLOT_GEOMETRY_CHECK =
    1 / (((SLOT_COUNT * MAX_PAYLOAD_BEATS) == PAYLOAD_DEPTH) ? 1 : 0);
  localparam int OCC_W_CHECK =
    1 / ((OCC_W == $clog2(SLOT_COUNT + 1)) ? 1 : 0);

  typedef enum logic [1:0] {
    SLOT_FREE      = 2'd0,
    SLOT_RESERVED  = 2'd1,
    SLOT_COMMITTED = 2'd2,
    SLOT_READING   = 2'd3
  } slot_state_t;

  typedef enum logic [1:0] {
    WRITER_IDLE    = 2'd0,
    WRITER_HEADER  = 2'd1,
    WRITER_PAYLOAD = 2'd2,
    WRITER_SEALED  = 2'd3
  } writer_state_t;

  slot_state_t slot_state_reg [0:SLOT_COUNT-1];
  logic [AXIS_DATA_W-1:0] header_data_reg [0:SLOT_COUNT-1][0:HEADER_BEATS-1];
  logic [TUSER_W-1:0] header_user_reg [0:SLOT_COUNT-1][0:HEADER_BEATS-1];
  logic [PAYLOAD_COUNT_W-1:0] payload_beat_count_reg [0:SLOT_COUNT-1];
  logic [TUSER_W-1:0] payload_last_user_reg [0:SLOT_COUNT-1];

  logic [SLOT_W-1:0] alloc_slot_reg;
  logic [SLOT_W-1:0] read_slot_ptr_reg;
  logic [SLOT_W-1:0] write_slot_reg;
  logic [SLOT_W-1:0] active_read_slot_reg;
  logic [OCC_W-1:0] occupancy_reg;
  logic [OCC_W-1:0] committed_count_reg;

  writer_state_t writer_state_reg;
  logic reservation_active_reg;
  logic write_ready_reg;
  logic reserve_pending_reg;
  logic [SLOT_W-1:0] reserve_slot_reg;
  logic abort_pending_reg;
  logic commit_pending_reg;
  logic [HEADER_COUNT_W-1:0] header_count_reg;
  logic [PAYLOAD_COUNT_W-1:0] payload_write_count_reg;

  logic read_active_reg;
  logic read_payload_phase_reg;
  logic [$clog2(HEADER_BEATS)-1:0] read_header_index_reg;
  logic [PAYLOAD_INDEX_W-1:0] read_payload_index_reg;
  logic [PAYLOAD_COUNT_W-1:0] payload_reads_issued_reg;

  logic [AXIS_DATA_W-1:0] payload_fifo_data_0_reg;
  logic [AXIS_DATA_W-1:0] payload_fifo_data_1_reg;
  logic [AXIS_DATA_W-1:0] payload_fifo_data_2_reg;
  logic [AXIS_DATA_W-1:0] payload_fifo_front;
  logic [PAYLOAD_FIFO_PTR_W-1:0] payload_fifo_write_ptr_reg;
  logic [PAYLOAD_FIFO_PTR_W-1:0] payload_fifo_read_ptr_reg;
  logic [PAYLOAD_FIFO_COUNT_W-1:0] payload_fifo_count_reg;

  logic bram_write_cmd_valid_reg;
  logic [PAYLOAD_ADDR_W-1:0] bram_write_cmd_addr_reg;
  logic [AXIS_DATA_W-1:0] bram_write_cmd_data_reg;
  logic bram_read_cmd_valid_reg;
  logic [PAYLOAD_ADDR_W-1:0] bram_read_cmd_addr_reg;
  logic bram_read_response_pending_reg;
  logic [AXIS_DATA_W-1:0] bram_read_data;
  logic payload_mem_conflict;

  logic [31:0] error_reg;
  logic write_error_event;
  logic [31:0] write_error_code;
  logic read_error_event;
  logic reserve_request_fire;
  logic reserve_fire;
  logic write_fire;
  logic header_write_fire;
  logic payload_write_fire;
  logic payload_seal_fire;
  logic commit_request_fire;
  logic payload_commit_fire;
  logic abort_fire;
  logic packet_valid_raw;
  logic packet_start_fire;
  logic output_valid_raw;
  logic output_fire_candidate;
  logic output_fire;
  logic payload_output_fire_candidate;
  logic payload_output_fire;
  logic packet_finish_read_candidate;
  logic packet_finish_read;
  logic payload_fifo_push_candidate;
  logic payload_fifo_push;
  logic payload_fifo_pop;
  logic payload_read_candidate_raw;
  logic payload_read_candidate;
  logic payload_read_issue;
  logic [PAYLOAD_ADDR_W-1:0] payload_write_addr;
  logic [PAYLOAD_ADDR_W-1:0] payload_read_issue_addr;
  logic [PAYLOAD_COUNT_W-1:0] active_payload_count;

  function automatic logic [SLOT_W-1:0] next_slot(
    input logic [SLOT_W-1:0] slot
  );
    if (SLOT_COUNT == 1 || int'(slot) == (SLOT_COUNT - 1)) begin
      next_slot = '0;
    end else begin
      next_slot = slot + SLOT_W'(1);
    end
  endfunction

  function automatic logic [PAYLOAD_ADDR_W-1:0] payload_address(
    input logic [SLOT_W-1:0] slot,
    input logic [PAYLOAD_INDEX_W-1:0] beat_index
  );
    payload_address = PAYLOAD_ADDR_W'(
      (int'(slot) * MAX_PAYLOAD_BEATS) + int'(beat_index)
    );
  endfunction

  function automatic logic [PAYLOAD_FIFO_PTR_W-1:0] next_payload_fifo_ptr(
    input logic [PAYLOAD_FIFO_PTR_W-1:0] ptr
  );
    if (int'(ptr) == (PAYLOAD_FIFO_DEPTH - 1)) begin
      next_payload_fifo_ptr = '0;
    end else begin
      next_payload_fifo_ptr = ptr + PAYLOAD_FIFO_PTR_W'(1);
    end
  endfunction

  assign reservation_active_reg = (writer_state_reg != WRITER_IDLE);

  assign o_reserve_ready = rst_n && (error_reg == MRTC_ERR_NONE) &&
                           !reservation_active_reg &&
                           !reserve_pending_reg &&
                           !abort_pending_reg &&
                           (occupancy_reg < OCC_W'(SLOT_COUNT)) &&
                           (slot_state_reg[alloc_slot_reg] == SLOT_FREE);
  assign o_full = !o_reserve_ready;
  assign reserve_request_fire = i_reserve && o_reserve_ready;
  assign reserve_fire = reserve_pending_reg && !abort_pending_reg &&
                        !write_error_event && !read_error_event &&
                        (error_reg == MRTC_ERR_NONE);

  assign s_axis_tready = write_ready_reg;
  assign write_fire = s_axis_tvalid && s_axis_tready;
  assign header_write_fire = write_fire && (writer_state_reg == WRITER_HEADER);
  assign payload_write_fire = write_fire && (writer_state_reg == WRITER_PAYLOAD);
  assign payload_seal_fire = payload_write_fire && s_axis_tlast &&
                             !write_error_event && !abort_pending_reg;
  assign commit_request_fire = i_commit && reservation_active_reg &&
                               ((writer_state_reg == WRITER_SEALED) ||
                                payload_seal_fire) &&
                               !i_abort && !abort_pending_reg &&
                               !write_error_event && !read_error_event &&
                               (error_reg == MRTC_ERR_NONE);
  assign payload_commit_fire = (writer_state_reg == WRITER_SEALED) &&
                               commit_pending_reg &&
                               (error_reg == MRTC_ERR_NONE) &&
                               !i_abort && !abort_pending_reg &&
                               !write_error_event && !read_error_event;
  assign abort_fire = reservation_active_reg &&
                      (abort_pending_reg || write_error_event);

  assign payload_write_addr = payload_address(
    write_slot_reg,
    PAYLOAD_INDEX_W'(payload_write_count_reg)
  );

  assign packet_valid_raw = !read_active_reg &&
                            (committed_count_reg != OCC_W'(0)) &&
                            (slot_state_reg[read_slot_ptr_reg] == SLOT_COMMITTED);
  assign o_packet_valid = packet_valid_raw;
  assign packet_start_fire = i_packet_start && packet_valid_raw;
  assign active_payload_count = payload_beat_count_reg[active_read_slot_reg];

  assign output_valid_raw = read_active_reg &&
                            (!read_payload_phase_reg ||
                             (payload_fifo_count_reg != PAYLOAD_FIFO_COUNT_W'(0)));
  assign m_axis_tvalid = output_valid_raw;
  assign m_axis_tdata = read_payload_phase_reg ?
                        payload_fifo_front :
                        header_data_reg[active_read_slot_reg][read_header_index_reg];
  assign m_axis_tuser = read_payload_phase_reg ?
                        ((read_payload_index_reg ==
                          PAYLOAD_INDEX_W'(active_payload_count - PAYLOAD_COUNT_W'(1))) ?
                         payload_last_user_reg[active_read_slot_reg] :
                         TUSER_W'(AXIS_BYTES - 1)) :
                        header_user_reg[active_read_slot_reg][read_header_index_reg];
  assign m_axis_tlast = read_payload_phase_reg &&
                        (read_payload_index_reg ==
                         PAYLOAD_INDEX_W'(active_payload_count - PAYLOAD_COUNT_W'(1)));
  assign output_fire_candidate = output_valid_raw && m_axis_tready;
  assign output_fire = output_fire_candidate;
  assign payload_output_fire_candidate = output_fire_candidate &&
                                         read_payload_phase_reg;
  assign payload_output_fire = payload_output_fire_candidate;
  assign packet_finish_read_candidate = payload_output_fire_candidate &&
                                        m_axis_tlast;
  assign packet_finish_read = packet_finish_read_candidate &&
                               !read_error_event;
  assign payload_fifo_push_candidate = bram_read_response_pending_reg;
  assign payload_fifo_push = payload_fifo_push_candidate &&
                             !read_error_event;
  assign payload_fifo_pop = payload_output_fire;
  assign payload_read_issue_addr = payload_address(
    active_read_slot_reg,
    PAYLOAD_INDEX_W'(payload_reads_issued_reg)
  );

  always_comb begin
    case (payload_fifo_read_ptr_reg)
      PAYLOAD_FIFO_PTR_W'(0): payload_fifo_front = payload_fifo_data_0_reg;
      PAYLOAD_FIFO_PTR_W'(1): payload_fifo_front = payload_fifo_data_1_reg;
      default: payload_fifo_front = payload_fifo_data_2_reg;
    endcase
  end

  always_comb begin
    integer payload_reserved_slots;
    payload_reserved_slots = int'(payload_fifo_count_reg) +
                             (bram_read_cmd_valid_reg ? 1 : 0) +
                             (bram_read_response_pending_reg ? 1 : 0) -
                             (payload_output_fire_candidate ? 1 : 0);
    payload_read_candidate_raw = read_active_reg &&
                                 (payload_reads_issued_reg < active_payload_count) &&
                                 (payload_reserved_slots < PAYLOAD_FIFO_DEPTH);
    payload_read_candidate = payload_read_candidate_raw &&
                              !read_error_event;
    payload_read_issue = payload_read_candidate &&
                         !(bram_write_cmd_valid_reg &&
                           (bram_write_cmd_addr_reg ==
                            payload_read_issue_addr));
  end

  assign o_busy = (occupancy_reg != OCC_W'(0)) || reserve_pending_reg ||
                  reservation_active_reg || read_active_reg;
  assign o_error = error_reg;
  assign o_overflow = (error_reg != MRTC_ERR_NONE);

  assign read_error_event =
    (i_packet_start && !packet_valid_raw) ||
    (payload_fifo_push_candidate && !payload_output_fire_candidate &&
     (payload_fifo_count_reg ==
      PAYLOAD_FIFO_COUNT_W'(PAYLOAD_FIFO_DEPTH))) ||
    payload_mem_conflict ||
    (payload_read_candidate_raw && bram_write_cmd_valid_reg &&
     (bram_write_cmd_addr_reg == payload_read_issue_addr)) ||
    (packet_finish_read_candidate &&
     ((payload_reads_issued_reg != active_payload_count) ||
      bram_read_cmd_valid_reg || bram_read_response_pending_reg ||
      (payload_fifo_count_reg != PAYLOAD_FIFO_COUNT_W'(1))));

  always_comb begin
    write_error_event = 1'b0;
    write_error_code = MRTC_ERR_NONE;
    if (!i_abort && !abort_pending_reg && (error_reg == MRTC_ERR_NONE)) begin
      if (s_axis_tvalid && (writer_state_reg == WRITER_IDLE)) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end else if (s_axis_tvalid && (writer_state_reg == WRITER_SEALED)) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end else if (header_write_fire && s_axis_tlast) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end else if (header_write_fire &&
                   (s_axis_tuser != TUSER_W'(AXIS_BYTES - 1))) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end else if (payload_write_fire &&
                   (payload_write_count_reg >= PAYLOAD_COUNT_W'(MAX_PAYLOAD_BEATS))) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_PAYLOAD_TOO_LONG;
      end else if (payload_write_fire && !s_axis_tlast &&
                   (payload_write_count_reg ==
                    PAYLOAD_COUNT_W'(MAX_PAYLOAD_BEATS - 1))) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_PAYLOAD_TOO_LONG;
      end else if (payload_write_fire && !s_axis_tlast &&
                   (s_axis_tuser != TUSER_W'(AXIS_BYTES - 1))) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end else if (payload_write_fire && s_axis_tlast &&
                   (s_axis_tuser[TUSER_W-1:4] != '0)) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end else if (i_commit &&
                   (!reservation_active_reg ||
                    ((writer_state_reg != WRITER_SEALED) &&
                     !(payload_write_fire && s_axis_tlast)))) begin
        write_error_event = 1'b1;
        write_error_code = MRTC_ERR_INTERNAL_STATE;
      end
    end
  end

  (* keep_hierarchy = "yes" *)
  mrtc_axis_payload_bram #(
    .DATA_W (AXIS_DATA_W),
    .DEPTH  (PAYLOAD_DEPTH)
  ) u_payload_ram (
    .clk       (clk),
    .i_wr_en   (bram_write_cmd_valid_reg),
    .i_wr_addr (bram_write_cmd_addr_reg),
    .i_wr_data (bram_write_cmd_data_reg),
    .i_rd_en   (bram_read_cmd_valid_reg),
    .i_rd_addr (bram_read_cmd_addr_reg),
    .o_rd_data (bram_read_data),
    .o_conflict(payload_mem_conflict)
  );

  always_ff @(posedge clk) begin
    integer slot_idx;
    logic [OCC_W-1:0] occupancy_next;
    logic [OCC_W-1:0] committed_next;
    if (!rst_n) begin
      alloc_slot_reg <= '0;
      read_slot_ptr_reg <= '0;
      write_slot_reg <= '0;
      active_read_slot_reg <= '0;
      occupancy_reg <= '0;
      committed_count_reg <= '0;
      writer_state_reg <= WRITER_IDLE;
      write_ready_reg <= 1'b0;
      reserve_pending_reg <= 1'b0;
      reserve_slot_reg <= '0;
      abort_pending_reg <= 1'b0;
      commit_pending_reg <= 1'b0;
      header_count_reg <= '0;
      payload_write_count_reg <= '0;
      read_active_reg <= 1'b0;
      read_payload_phase_reg <= 1'b0;
      read_header_index_reg <= '0;
      read_payload_index_reg <= '0;
      payload_reads_issued_reg <= '0;
      payload_fifo_write_ptr_reg <= '0;
      payload_fifo_read_ptr_reg <= '0;
      payload_fifo_count_reg <= '0;
      bram_write_cmd_valid_reg <= 1'b0;
      bram_write_cmd_addr_reg <= '0;
      bram_write_cmd_data_reg <= '0;
      bram_read_cmd_valid_reg <= 1'b0;
      bram_read_cmd_addr_reg <= '0;
      bram_read_response_pending_reg <= 1'b0;
      error_reg <= MRTC_ERR_NONE;
      o_packets_written <= 32'd0;
      o_packets_read <= 32'd0;
      o_write_stall_cycles <= 32'd0;
      o_read_stall_cycles <= 32'd0;
      o_max_occupancy <= '0;
      for (slot_idx = 0; slot_idx < SLOT_COUNT; slot_idx = slot_idx + 1) begin
        slot_state_reg[slot_idx] <= SLOT_FREE;
        payload_beat_count_reg[slot_idx] <= '0;
        payload_last_user_reg[slot_idx] <= '0;
      end
    end else begin
      occupancy_next = occupancy_reg;
      committed_next = committed_count_reg;

      reserve_pending_reg <= reserve_request_fire;
      if (reserve_request_fire) begin
        reserve_slot_reg <= alloc_slot_reg;
      end
      abort_pending_reg <= i_abort || read_error_event;
      bram_write_cmd_valid_reg <= payload_write_fire &&
                                  !write_error_event && !abort_pending_reg;
      if (payload_write_fire && !write_error_event && !abort_pending_reg) begin
        bram_write_cmd_addr_reg <= payload_write_addr;
        bram_write_cmd_data_reg <= s_axis_tdata;
      end

      bram_read_cmd_valid_reg <= payload_read_issue;
      if (payload_read_issue) begin
        bram_read_cmd_addr_reg <= payload_read_issue_addr;
      end
      bram_read_response_pending_reg <= bram_read_cmd_valid_reg;

      if (i_clear_status) begin
        o_packets_written <= 32'd0;
        o_packets_read <= 32'd0;
        o_write_stall_cycles <= 32'd0;
        o_read_stall_cycles <= 32'd0;
        o_max_occupancy <= occupancy_reg;
      end

      if (s_axis_tvalid && !s_axis_tready) begin
        o_write_stall_cycles <= o_write_stall_cycles + 32'd1;
      end
      if (m_axis_tvalid && !m_axis_tready) begin
        o_read_stall_cycles <= o_read_stall_cycles + 32'd1;
      end

      if ((error_reg == MRTC_ERR_NONE) && write_error_event) begin
        error_reg <= write_error_code;
      end else if ((error_reg == MRTC_ERR_NONE) && read_error_event) begin
        error_reg <= MRTC_ERR_INTERNAL_STATE;
      end

      if (write_error_event || abort_fire) begin
        if (reservation_active_reg) begin
          slot_state_reg[write_slot_reg] <= SLOT_FREE;
          payload_beat_count_reg[write_slot_reg] <= '0;
          payload_last_user_reg[write_slot_reg] <= '0;
          occupancy_next = occupancy_next - OCC_W'(1);
        end
        writer_state_reg <= WRITER_IDLE;
        write_ready_reg <= 1'b0;
        commit_pending_reg <= 1'b0;
        header_count_reg <= '0;
        payload_write_count_reg <= '0;
      end else if (payload_commit_fire) begin
        slot_state_reg[write_slot_reg] <= SLOT_COMMITTED;
        writer_state_reg <= WRITER_IDLE;
        write_ready_reg <= 1'b0;
        commit_pending_reg <= 1'b0;
        header_count_reg <= '0;
        payload_write_count_reg <= '0;
        alloc_slot_reg <= next_slot(write_slot_reg);
        committed_next = committed_next + OCC_W'(1);
        o_packets_written <= o_packets_written + 32'd1;
      end else begin
        if (reserve_fire) begin
          write_slot_reg <= reserve_slot_reg;
          slot_state_reg[reserve_slot_reg] <= SLOT_RESERVED;
          writer_state_reg <= WRITER_HEADER;
          write_ready_reg <= 1'b1;
          commit_pending_reg <= 1'b0;
          header_count_reg <= '0;
          payload_write_count_reg <= '0;
          payload_beat_count_reg[reserve_slot_reg] <= '0;
          payload_last_user_reg[reserve_slot_reg] <= '0;
          occupancy_next = occupancy_next + OCC_W'(1);
        end else begin
          case (writer_state_reg)
            WRITER_HEADER: begin
              if (header_write_fire) begin
                header_data_reg[write_slot_reg][header_count_reg] <= s_axis_tdata;
                header_user_reg[write_slot_reg][header_count_reg] <= s_axis_tuser;
                header_count_reg <= header_count_reg + HEADER_COUNT_W'(1);
                if (header_count_reg == HEADER_COUNT_W'(HEADER_BEATS - 1)) begin
                  writer_state_reg <= WRITER_PAYLOAD;
                end
              end
            end
            WRITER_PAYLOAD: begin
              if (payload_write_fire) begin
                payload_write_count_reg <=
                  payload_write_count_reg + PAYLOAD_COUNT_W'(1);
                if (payload_seal_fire) begin
                  writer_state_reg <= WRITER_SEALED;
                  write_ready_reg <= 1'b0;
                  payload_beat_count_reg[write_slot_reg] <=
                    payload_write_count_reg + PAYLOAD_COUNT_W'(1);
                  payload_last_user_reg[write_slot_reg] <= s_axis_tuser;
                end
              end
            end
            default: begin
              writer_state_reg <= writer_state_reg;
            end
          endcase
        end

        if (commit_request_fire) begin
          commit_pending_reg <= 1'b1;
        end
      end

      if (packet_start_fire) begin
        active_read_slot_reg <= read_slot_ptr_reg;
        slot_state_reg[read_slot_ptr_reg] <= SLOT_READING;
        read_active_reg <= 1'b1;
        read_payload_phase_reg <= 1'b0;
        read_header_index_reg <= '0;
        read_payload_index_reg <= '0;
        payload_reads_issued_reg <= '0;
        payload_fifo_write_ptr_reg <= '0;
        payload_fifo_read_ptr_reg <= '0;
        payload_fifo_count_reg <= '0;
        bram_read_cmd_valid_reg <= 1'b0;
        bram_read_response_pending_reg <= 1'b0;
      end else begin
        if (payload_read_issue) begin
          payload_reads_issued_reg <=
            payload_reads_issued_reg + PAYLOAD_COUNT_W'(1);
        end

        if (payload_fifo_push) begin
          case (payload_fifo_write_ptr_reg)
            PAYLOAD_FIFO_PTR_W'(0): payload_fifo_data_0_reg <= bram_read_data;
            PAYLOAD_FIFO_PTR_W'(1): payload_fifo_data_1_reg <= bram_read_data;
            default: payload_fifo_data_2_reg <= bram_read_data;
          endcase
          payload_fifo_write_ptr_reg <=
            next_payload_fifo_ptr(payload_fifo_write_ptr_reg);
        end
        if (payload_fifo_pop) begin
          payload_fifo_read_ptr_reg <=
            next_payload_fifo_ptr(payload_fifo_read_ptr_reg);
        end
        case ({payload_fifo_push, payload_fifo_pop})
          2'b10: payload_fifo_count_reg <=
                    payload_fifo_count_reg + PAYLOAD_FIFO_COUNT_W'(1);
          2'b01: payload_fifo_count_reg <=
                    payload_fifo_count_reg - PAYLOAD_FIFO_COUNT_W'(1);
          default: payload_fifo_count_reg <= payload_fifo_count_reg;
        endcase
      end

      if (output_fire && !read_payload_phase_reg) begin
        if (read_header_index_reg == (HEADER_BEATS - 1)) begin
          read_payload_phase_reg <= 1'b1;
          read_payload_index_reg <= '0;
        end else begin
          read_header_index_reg <= read_header_index_reg + 1'b1;
        end
      end else if (payload_output_fire) begin
        if (!m_axis_tlast) begin
          read_payload_index_reg <= read_payload_index_reg + PAYLOAD_INDEX_W'(1);
        end
      end

      if (packet_finish_read) begin
        slot_state_reg[active_read_slot_reg] <= SLOT_FREE;
        payload_beat_count_reg[active_read_slot_reg] <= '0;
        payload_last_user_reg[active_read_slot_reg] <= '0;
        read_slot_ptr_reg <= next_slot(active_read_slot_reg);
        read_active_reg <= 1'b0;
        read_payload_phase_reg <= 1'b0;
        read_header_index_reg <= '0;
        read_payload_index_reg <= '0;
        payload_reads_issued_reg <= '0;
        payload_fifo_write_ptr_reg <= '0;
        payload_fifo_read_ptr_reg <= '0;
        payload_fifo_count_reg <= '0;
        bram_read_cmd_valid_reg <= 1'b0;
        bram_read_response_pending_reg <= 1'b0;
        occupancy_next = occupancy_next - OCC_W'(1);
        committed_next = committed_next - OCC_W'(1);
        o_packets_read <= o_packets_read + 32'd1;
      end

      occupancy_reg <= occupancy_next;
      committed_count_reg <= committed_next;
      if (occupancy_next > o_max_occupancy) begin
        o_max_occupancy <= occupancy_next;
      end

    end
  end

  logic unused_static_checks;
  assign unused_static_checks = AXIS_DATA_W_CHECK[0] ^ HEADER_BEATS_CHECK[0] ^
                                PAYLOAD_DEPTH_CHECK[0] ^ SLOT_COUNT_CHECK[0] ^
                                SLOT_GEOMETRY_CHECK[0] ^ OCC_W_CHECK[0];
endmodule
