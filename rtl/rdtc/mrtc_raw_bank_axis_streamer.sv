module mrtc_raw_bank_axis_streamer #(
  parameter int AXIS_DATA_W = 128,
  parameter int BLOCK_WORDS = 256
) (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               i_start,
  output logic                               o_bank_rd_req,
  output logic [$clog2(BLOCK_WORDS)-1:0]     o_bank_rd_word_addr,
  input  logic                               i_bank_rd_valid,
  input  logic [AXIS_DATA_W-1:0]             i_bank_rd_word_data,
  output logic [AXIS_DATA_W-1:0]             m_axis_tdata,
  output logic                               m_axis_tvalid,
  input  logic                               m_axis_tready,
  output logic                               m_axis_tlast,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0] m_axis_tvalid_bytes_minus1,
  output logic                               o_busy,
  output logic                               o_done
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);
  localparam int WORD_ADDR_W = (BLOCK_WORDS <= 1) ? 1 : $clog2(BLOCK_WORDS);
  localparam int COUNT_W = $clog2(BLOCK_WORDS + 1);
  localparam int FIFO_DEPTH = 4;
  localparam int FIFO_PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
  localparam int AXIS_WIDTH_SUPPORTED_CHECK =
    1 / (((AXIS_DATA_W == 32) ||
          (AXIS_DATA_W == 64) ||
          (AXIS_DATA_W == 128) ||
          (AXIS_DATA_W == 256) ||
          (AXIS_DATA_W == 512)) ? 1 : 0);

  logic active_reg;
  logic [WORD_ADDR_W-1:0] issue_word_idx_reg;
  logic [COUNT_W-1:0]     issued_count_reg;
  logic [COUNT_W-1:0]     resp_count_reg;
  logic [COUNT_W-1:0]     accepted_count_reg;
  logic [AXIS_DATA_W-1:0] fifo_data_reg [0:FIFO_DEPTH-1];
  logic                   fifo_last_reg [0:FIFO_DEPTH-1];
  logic [FIFO_PTR_W-1:0]  fifo_head_reg;
  logic [FIFO_PTR_W-1:0]  fifo_tail_reg;
  logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_count_reg;

  logic                   pop_axis;
  logic                   issue_req;
  logic                   push_resp;
  logic                   fifo_empty;
  logic                   fifo_full;
  logic [COUNT_W-1:0]     outstanding_count;
  logic [COUNT_W-1:0]     total_occupancy;
  logic [COUNT_W-1:0]     total_after_pop;
  logic [FIFO_PTR_W-1:0]  fifo_head_next;
  logic [FIFO_PTR_W-1:0]  fifo_tail_next;
  logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_count_next;
  logic [AXIS_DATA_W-1:0] fifo_data_next [0:FIFO_DEPTH-1];
  logic                   fifo_last_next [0:FIFO_DEPTH-1];
  logic                   final_accept;
  logic                   push_last;

  assign fifo_empty = (fifo_count_reg == 2'd0);
  assign fifo_full  = (fifo_count_reg == FIFO_DEPTH);

  assign m_axis_tvalid              = !fifo_empty;
  assign m_axis_tdata               = fifo_data_reg[fifo_head_reg];
  assign m_axis_tlast               = fifo_last_reg[fifo_head_reg];
  assign m_axis_tvalid_bytes_minus1 = VALID_BYTE_COUNT_W'(AXIS_BYTES - 1);
  assign o_busy                     = active_reg;

  assign pop_axis  = m_axis_tvalid && m_axis_tready;
  assign push_resp = active_reg && i_bank_rd_valid;
  assign outstanding_count = issued_count_reg - resp_count_reg;
  assign total_occupancy   = outstanding_count + COUNT_W'(fifo_count_reg);
  assign total_after_pop   = total_occupancy - (pop_axis ? COUNT_W'(1) : COUNT_W'(0));
  assign issue_req =
    active_reg &&
    (issued_count_reg < COUNT_W'(BLOCK_WORDS)) &&
    (total_after_pop < COUNT_W'(FIFO_DEPTH));

  assign o_bank_rd_req       = issue_req;
  assign o_bank_rd_word_addr = issue_word_idx_reg;

  always_ff @(posedge clk or negedge rst_n) begin : p_stream
    if (!rst_n) begin
      active_reg         <= 1'b0;
      issue_word_idx_reg <= '0;
      issued_count_reg   <= '0;
      resp_count_reg     <= '0;
      accepted_count_reg <= '0;
      fifo_head_reg      <= '0;
      fifo_tail_reg      <= '0;
      fifo_count_reg     <= '0;
      for (int idx = 0; idx < FIFO_DEPTH; idx = idx + 1) begin
        fifo_data_reg[idx] <= '0;
        fifo_last_reg[idx] <= 1'b0;
      end
      o_done <= 1'b0;
    end else begin
      o_done <= 1'b0;

      if (!active_reg) begin
        if (i_start) begin
          active_reg         <= 1'b1;
          issue_word_idx_reg <= '0;
          issued_count_reg   <= '0;
          resp_count_reg     <= '0;
          accepted_count_reg <= '0;
          fifo_head_reg      <= '0;
          fifo_tail_reg      <= '0;
          fifo_count_reg     <= '0;
          for (int idx = 0; idx < FIFO_DEPTH; idx = idx + 1) begin
            fifo_data_reg[idx] <= '0;
            fifo_last_reg[idx] <= 1'b0;
          end
        end
      end else begin
        fifo_head_next  = fifo_head_reg;
        fifo_tail_next  = fifo_tail_reg;
        fifo_count_next = fifo_count_reg;
        for (int idx = 0; idx < FIFO_DEPTH; idx = idx + 1) begin
          fifo_data_next[idx] = fifo_data_reg[idx];
          fifo_last_next[idx] = fifo_last_reg[idx];
        end

        if (pop_axis) begin
          fifo_head_next = fifo_head_reg + FIFO_PTR_W'(1);
          fifo_count_next = fifo_count_next - 1'b1;
        end

        if (push_resp) begin
          push_last = (resp_count_reg == COUNT_W'(BLOCK_WORDS - 1));
          fifo_data_next[fifo_tail_next] = i_bank_rd_word_data;
          fifo_last_next[fifo_tail_next] = push_last;
          fifo_tail_next = fifo_tail_next + FIFO_PTR_W'(1);
          fifo_count_next = fifo_count_next + 1'b1;
          resp_count_reg <= resp_count_reg + COUNT_W'(1);
        end

        fifo_head_reg  <= fifo_head_next;
        fifo_tail_reg  <= fifo_tail_next;
        fifo_count_reg <= fifo_count_next;
        for (int idx = 0; idx < FIFO_DEPTH; idx = idx + 1) begin
          fifo_data_reg[idx] <= fifo_data_next[idx];
          fifo_last_reg[idx] <= fifo_last_next[idx];
        end

        if (issue_req) begin
          issued_count_reg <= issued_count_reg + COUNT_W'(1);
          if (issue_word_idx_reg != WORD_ADDR_W'(BLOCK_WORDS - 1)) begin
            issue_word_idx_reg <= issue_word_idx_reg + WORD_ADDR_W'(1);
          end
        end

        if (pop_axis) begin
          accepted_count_reg <= accepted_count_reg + COUNT_W'(1);
        end

        final_accept =
          pop_axis &&
          fifo_last_reg[fifo_head_reg] &&
          (accepted_count_reg == COUNT_W'(BLOCK_WORDS - 1));
        if (final_accept) begin
          active_reg <= 1'b0;
          o_done     <= 1'b1;
        end
      end
    end
  end
endmodule
