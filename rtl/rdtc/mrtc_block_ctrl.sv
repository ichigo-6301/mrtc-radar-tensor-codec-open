module mrtc_block_ctrl #(
  parameter int BLOCK_SAMPLES = 1024,
  parameter int BLOCK_RANGE_LEN = 16
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [15:0] i_block_id_base,
  input  logic       i_block_consume,
  input  logic       i_beat_accept,
  input  logic       i_tlast,
  output logic [9:0] o_wr_addr_base,
  output logic       o_block_ready,
  output logic       o_block_last,
  output logic [15:0] o_block_id,
  output logic [15:0] o_block_range_start,
  output logic [31:0] o_stat_error,
  output logic [10:0] o_sample_count
);
  logic [10:0] sample_count_reg;
  logic [15:0] block_id_reg;
  logic [15:0] block_range_start_reg;
  logic        block_ready_reg;
  logic        block_last_reg;
  logic [31:0] stat_error_reg;

  assign o_wr_addr_base = sample_count_reg[10:2] * 4;
  assign o_block_ready = block_ready_reg;
  assign o_block_last = block_last_reg;
  assign o_block_id = block_id_reg;
  assign o_block_range_start = block_range_start_reg;
  assign o_stat_error = stat_error_reg;
  assign o_sample_count = sample_count_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sample_count_reg      <= '0;
      block_id_reg          <= i_block_id_base;
      block_range_start_reg <= '0;
      block_ready_reg       <= 1'b0;
      block_last_reg        <= 1'b0;
      stat_error_reg        <= 32'd0;
    end else begin
      if (i_block_consume) begin
        sample_count_reg      <= '0;
        block_ready_reg       <= 1'b0;
        block_last_reg        <= 1'b0;
        block_id_reg          <= block_id_reg + 16'd1;
        block_range_start_reg <= block_range_start_reg + BLOCK_RANGE_LEN[15:0];
      end

      if (i_beat_accept && !block_ready_reg) begin
        if ((sample_count_reg + 11'd4) < BLOCK_SAMPLES && i_tlast) begin
          stat_error_reg <= 32'd1;
        end

        sample_count_reg <= sample_count_reg + 11'd4;
        if ((sample_count_reg + 11'd4) == BLOCK_SAMPLES) begin
          block_ready_reg <= 1'b1;
          block_last_reg  <= i_tlast;
        end
      end
    end
  end
endmodule
