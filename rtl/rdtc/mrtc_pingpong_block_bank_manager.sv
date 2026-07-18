module mrtc_pingpong_block_bank_manager #(
  parameter int BLOCK_WORDS      = 256,
  parameter int BLOCK_RANGE_LEN  = 16
) (
  input  logic                             clk,
  input  logic                             rst_n,
  input  logic [15:0]                      i_block_id_base,
  input  logic                             i_capture_valid,
  input  logic                             i_capture_accept,
  input  logic                             i_capture_tlast,
  input  logic [7:0]                       i_capture_codec_mode,
  input  logic [7:0]                       i_capture_rice_mode,
  input  logic [3:0]                       i_capture_fixed_k,
  input  logic                             i_capture_last_block,
  input  logic [15:0]                      i_capture_frame_id,
  input  logic [15:0]                      i_capture_tensor_spatial_size,
  input  logic [15:0]                      i_capture_tensor_doppler_size,
  input  logic [15:0]                      i_capture_tensor_range_size,
  input  logic                             i_proc_take_ready,
  input  logic                             i_proc_done,
  output logic                             o_capture_can_accept,
  output logic                             o_fill_bank_valid,
  output logic                             o_fill_bank_sel,
  output logic [$clog2(BLOCK_WORDS)-1:0]   o_fill_word_addr,
  output logic                             o_proc_ready_valid,
  output logic                             o_proc_ready_bank_sel,
  output logic                             o_proc_active_valid,
  output logic                             o_proc_active_bank_sel,
  output logic [1:0]                       o_bank_state0,
  output logic [1:0]                       o_bank_state1,
  output logic [7:0]                       o_proc_codec_mode,
  output logic [7:0]                       o_proc_rice_mode,
  output logic [3:0]                       o_proc_fixed_k,
  output logic                             o_proc_last_block,
  output logic [15:0]                      o_proc_frame_id,
  output logic [15:0]                      o_proc_block_id,
  output logic [15:0]                      o_proc_block_range_start,
  output logic [15:0]                      o_proc_tensor_spatial_size,
  output logic [15:0]                      o_proc_tensor_doppler_size,
  output logic [15:0]                      o_proc_tensor_range_size,
  output logic [31:0]                      o_error,
  output logic [31:0]                      o_capture_accepted_blocks,
  output logic [31:0]                      o_processing_started_blocks,
  output logic [31:0]                      o_processing_done_blocks,
  output logic [31:0]                      o_pingpong_overlap_blocks
);
  import mrtc_pkg::*;

  typedef enum logic [1:0] {
    BANK_FREE       = 2'd0,
    BANK_FILLING    = 2'd1,
    BANK_READY      = 2'd2,
    BANK_PROCESSING = 2'd3
  } bank_state_t;

  bank_state_t bank_state_reg [0:1];
  logic [7:0]  bank_codec_mode_reg [0:1];
  logic [7:0]  bank_rice_mode_reg [0:1];
  logic [3:0]  bank_fixed_k_reg [0:1];
  logic        bank_last_block_reg [0:1];
  logic [15:0] bank_frame_id_reg [0:1];
  logic [15:0] bank_block_id_reg [0:1];
  logic [15:0] bank_block_range_start_reg [0:1];
  logic [15:0] bank_tensor_spatial_size_reg [0:1];
  logic [15:0] bank_tensor_doppler_size_reg [0:1];
  logic [15:0] bank_tensor_range_size_reg [0:1];
  logic [31:0] bank_ctrl_error_reg [0:1];
  logic [$clog2(BLOCK_WORDS+1)-1:0] bank_fill_count_reg [0:1];

  logic        fill_bank_active_reg;
  logic        fill_bank_sel_reg;
  logic        proc_bank_valid_reg;
  logic        proc_bank_sel_reg;
  logic [15:0] next_block_id_reg;
  logic [15:0] next_block_range_start_reg;
  logic [31:0] error_reg;
  logic [31:0] capture_accepted_blocks_reg;
  logic [31:0] processing_started_blocks_reg;
  logic [31:0] processing_done_blocks_reg;
  logic [31:0] pingpong_overlap_blocks_reg;
  logic        overlap_seen_reg [0:1];

  logic        free_bank_available;
  logic        free_bank_sel_comb;
  logic        ready_bank_available;
  logic        ready_bank_sel_comb;
  logic [$clog2(BLOCK_WORDS)-1:0] fill_word_addr_comb;

  assign free_bank_available = (bank_state_reg[0] == BANK_FREE) || (bank_state_reg[1] == BANK_FREE);
  assign free_bank_sel_comb  = (bank_state_reg[0] == BANK_FREE) ? 1'b0 : 1'b1;
  assign ready_bank_available = (bank_state_reg[0] == BANK_READY) || (bank_state_reg[1] == BANK_READY);
  assign ready_bank_sel_comb  = (bank_state_reg[0] == BANK_READY) ? 1'b0 : 1'b1;

  assign o_capture_can_accept = fill_bank_active_reg || free_bank_available;
  assign o_fill_bank_valid    = fill_bank_active_reg || (i_capture_valid && free_bank_available);
  assign o_fill_bank_sel      = fill_bank_active_reg ? fill_bank_sel_reg : free_bank_sel_comb;
  assign fill_word_addr_comb  = fill_bank_active_reg ? bank_fill_count_reg[fill_bank_sel_reg][$clog2(BLOCK_WORDS)-1:0] : '0;
  assign o_fill_word_addr     = fill_word_addr_comb;
  assign o_proc_ready_valid   = (!proc_bank_valid_reg) && ready_bank_available;
  assign o_proc_ready_bank_sel = ready_bank_sel_comb;
  assign o_proc_active_valid   = proc_bank_valid_reg;
  assign o_proc_active_bank_sel = proc_bank_sel_reg;

  assign o_bank_state0 = bank_state_reg[0];
  assign o_bank_state1 = bank_state_reg[1];
  assign o_proc_codec_mode          = proc_bank_valid_reg ? bank_codec_mode_reg[proc_bank_sel_reg] : 8'd0;
  assign o_proc_rice_mode           = proc_bank_valid_reg ? bank_rice_mode_reg[proc_bank_sel_reg] : 8'd0;
  assign o_proc_fixed_k             = proc_bank_valid_reg ? bank_fixed_k_reg[proc_bank_sel_reg] : 4'd0;
  assign o_proc_last_block          = proc_bank_valid_reg ? bank_last_block_reg[proc_bank_sel_reg] : 1'b0;
  assign o_proc_frame_id            = proc_bank_valid_reg ? bank_frame_id_reg[proc_bank_sel_reg] : 16'd0;
  assign o_proc_block_id            = proc_bank_valid_reg ? bank_block_id_reg[proc_bank_sel_reg] : 16'd0;
  assign o_proc_block_range_start   = proc_bank_valid_reg ? bank_block_range_start_reg[proc_bank_sel_reg] : 16'd0;
  assign o_proc_tensor_spatial_size = proc_bank_valid_reg ? bank_tensor_spatial_size_reg[proc_bank_sel_reg] : 16'd0;
  assign o_proc_tensor_doppler_size = proc_bank_valid_reg ? bank_tensor_doppler_size_reg[proc_bank_sel_reg] : 16'd0;
  assign o_proc_tensor_range_size   = proc_bank_valid_reg ? bank_tensor_range_size_reg[proc_bank_sel_reg] : 16'd0;
  assign o_error                    = error_reg;
  assign o_capture_accepted_blocks  = capture_accepted_blocks_reg;
  assign o_processing_started_blocks = processing_started_blocks_reg;
  assign o_processing_done_blocks    = processing_done_blocks_reg;
  assign o_pingpong_overlap_blocks   = pingpong_overlap_blocks_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    logic start_fill_now;
    logic fill_bank_sel_now;
    logic [1:0] fill_bank_state_other;
    if (!rst_n) begin
      bank_state_reg[0] <= BANK_FREE;
      bank_state_reg[1] <= BANK_FREE;
      bank_codec_mode_reg[0] <= 8'd0;
      bank_codec_mode_reg[1] <= 8'd0;
      bank_rice_mode_reg[0] <= 8'd0;
      bank_rice_mode_reg[1] <= 8'd0;
      bank_fixed_k_reg[0] <= 4'd0;
      bank_fixed_k_reg[1] <= 4'd0;
      bank_last_block_reg[0] <= 1'b0;
      bank_last_block_reg[1] <= 1'b0;
      bank_frame_id_reg[0] <= 16'd0;
      bank_frame_id_reg[1] <= 16'd0;
      bank_block_id_reg[0] <= 16'd0;
      bank_block_id_reg[1] <= 16'd0;
      bank_block_range_start_reg[0] <= 16'd0;
      bank_block_range_start_reg[1] <= 16'd0;
      bank_tensor_spatial_size_reg[0] <= 16'd0;
      bank_tensor_spatial_size_reg[1] <= 16'd0;
      bank_tensor_doppler_size_reg[0] <= 16'd0;
      bank_tensor_doppler_size_reg[1] <= 16'd0;
      bank_tensor_range_size_reg[0] <= 16'd0;
      bank_tensor_range_size_reg[1] <= 16'd0;
      bank_ctrl_error_reg[0] <= MRTC_ERR_NONE;
      bank_ctrl_error_reg[1] <= MRTC_ERR_NONE;
      bank_fill_count_reg[0] <= '0;
      bank_fill_count_reg[1] <= '0;
      fill_bank_active_reg <= 1'b0;
      fill_bank_sel_reg <= 1'b0;
      proc_bank_valid_reg <= 1'b0;
      proc_bank_sel_reg <= 1'b0;
      next_block_id_reg <= i_block_id_base;
      next_block_range_start_reg <= 16'd0;
      error_reg <= MRTC_ERR_NONE;
      capture_accepted_blocks_reg <= 32'd0;
      processing_started_blocks_reg <= 32'd0;
      processing_done_blocks_reg <= 32'd0;
      pingpong_overlap_blocks_reg <= 32'd0;
      overlap_seen_reg[0] <= 1'b0;
      overlap_seen_reg[1] <= 1'b0;
    end else begin
      start_fill_now = !fill_bank_active_reg && i_capture_valid && free_bank_available;
      fill_bank_sel_now = fill_bank_active_reg ? fill_bank_sel_reg : free_bank_sel_comb;
      fill_bank_state_other = bank_state_reg[~fill_bank_sel_now];

      if (start_fill_now) begin
        fill_bank_active_reg <= 1'b1;
        fill_bank_sel_reg    <= fill_bank_sel_now;
        bank_state_reg[fill_bank_sel_now] <= BANK_FILLING;
        bank_fill_count_reg[fill_bank_sel_now] <= '0;
        bank_codec_mode_reg[fill_bank_sel_now] <= i_capture_codec_mode;
        bank_rice_mode_reg[fill_bank_sel_now] <= i_capture_rice_mode;
        bank_fixed_k_reg[fill_bank_sel_now] <= i_capture_fixed_k;
        bank_last_block_reg[fill_bank_sel_now] <= i_capture_last_block;
        bank_frame_id_reg[fill_bank_sel_now] <= i_capture_frame_id;
        bank_block_id_reg[fill_bank_sel_now] <= next_block_id_reg;
        bank_block_range_start_reg[fill_bank_sel_now] <= next_block_range_start_reg;
        bank_tensor_spatial_size_reg[fill_bank_sel_now] <= i_capture_tensor_spatial_size;
        bank_tensor_doppler_size_reg[fill_bank_sel_now] <= i_capture_tensor_doppler_size;
        bank_tensor_range_size_reg[fill_bank_sel_now] <= i_capture_tensor_range_size;
        bank_ctrl_error_reg[fill_bank_sel_now] <= MRTC_ERR_NONE;
        overlap_seen_reg[fill_bank_sel_now] <= (fill_bank_state_other == BANK_PROCESSING);
      end

      if ((fill_bank_active_reg || start_fill_now) && i_capture_accept) begin
        if ((bank_fill_count_reg[fill_bank_sel_now] != BLOCK_WORDS-1) && i_capture_tlast) begin
          bank_ctrl_error_reg[fill_bank_sel_now] <= MRTC_ERR_TLAST_EARLY;
          error_reg <= MRTC_ERR_TLAST_EARLY;
          bank_state_reg[fill_bank_sel_now] <= BANK_FREE;
          bank_fill_count_reg[fill_bank_sel_now] <= '0;
          fill_bank_active_reg <= 1'b0;
        end else if (bank_fill_count_reg[fill_bank_sel_now] == BLOCK_WORDS-1) begin
          if (!i_capture_tlast) begin
            bank_ctrl_error_reg[fill_bank_sel_now] <= MRTC_ERR_BLOCK_SIZE;
            error_reg <= MRTC_ERR_BLOCK_SIZE;
            bank_state_reg[fill_bank_sel_now] <= BANK_FREE;
          end else begin
            bank_state_reg[fill_bank_sel_now] <= BANK_READY;
            capture_accepted_blocks_reg <= capture_accepted_blocks_reg + 32'd1;
            if (overlap_seen_reg[fill_bank_sel_now]) begin
              pingpong_overlap_blocks_reg <= pingpong_overlap_blocks_reg + 32'd1;
            end
            next_block_id_reg <= next_block_id_reg + 16'd1;
            next_block_range_start_reg <= next_block_range_start_reg + BLOCK_RANGE_LEN[15:0];
          end
          bank_fill_count_reg[fill_bank_sel_now] <= '0;
          fill_bank_active_reg <= 1'b0;
        end else begin
          bank_fill_count_reg[fill_bank_sel_now] <= bank_fill_count_reg[fill_bank_sel_now] + 1'b1;
        end
      end

      if (i_proc_take_ready) begin
        if (!ready_bank_available || proc_bank_valid_reg) begin
          error_reg <= MRTC_ERR_INTERNAL_STATE;
        end else begin
          proc_bank_valid_reg <= 1'b1;
          proc_bank_sel_reg   <= ready_bank_sel_comb;
          bank_state_reg[ready_bank_sel_comb] <= BANK_PROCESSING;
          processing_started_blocks_reg <= processing_started_blocks_reg + 32'd1;
        end
      end

      if (i_proc_done) begin
        if (!proc_bank_valid_reg) begin
          error_reg <= MRTC_ERR_INTERNAL_STATE;
        end else begin
          bank_state_reg[proc_bank_sel_reg] <= BANK_FREE;
          proc_bank_valid_reg <= 1'b0;
          processing_done_blocks_reg <= processing_done_blocks_reg + 32'd1;
        end
      end
    end
  end
endmodule
