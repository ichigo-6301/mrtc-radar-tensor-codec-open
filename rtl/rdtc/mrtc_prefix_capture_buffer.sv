module mrtc_prefix_capture_buffer #(
  parameter int AXIS_DATA_W = 128,
  parameter int LANES = 4,
  parameter int PREFIX_SAMPLES = 256
) (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               i_wr_en,
  input  logic [$clog2(PREFIX_SAMPLES/LANES)-1:0] i_wr_word_addr,
  input  logic [AXIS_DATA_W-1:0]             i_wr_word_data,
  input  logic                               i_rd_req,
  input  logic [$clog2(PREFIX_SAMPLES)-1:0]  i_rd_addr,
  output logic                               o_rd_valid,
  output logic [31:0]                        o_rd_data
);
  localparam int PREFIX_WORDS = PREFIX_SAMPLES / LANES;
  localparam int LANE_IDX_W = (LANES <= 1) ? 1 : $clog2(LANES);
  localparam int PREFIX_SAMPLES_POSITIVE_CHECK =
    1 / ((PREFIX_SAMPLES > 0) ? 1 : 0);
  localparam int PREFIX_LANE_ALIGN_CHECK =
    1 / (((PREFIX_SAMPLES % LANES) == 0) ? 1 : 0);
  localparam int AXIS_DATA_W_CHECK =
    1 / ((AXIS_DATA_W == (LANES * 32)) ? 1 : 0);

  logic [AXIS_DATA_W-1:0] word_mem [0:PREFIX_WORDS-1];
  logic [AXIS_DATA_W-1:0] rd_word_reg;
  logic [LANE_IDX_W-1:0]  rd_lane_reg;
  logic                   rd_valid_reg;
  integer                 lane_idx_int;

  assign o_rd_valid = rst_n && rd_valid_reg;

  always_comb begin
    o_rd_data = 32'd0;
    for (lane_idx_int = 0; lane_idx_int < LANES; lane_idx_int = lane_idx_int + 1) begin
      if (rst_n && rd_valid_reg &&
          (rd_lane_reg == LANE_IDX_W'(lane_idx_int))) begin
        o_rd_data = rd_word_reg[(lane_idx_int * 32) +: 32];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      word_mem[i_wr_word_addr] <= i_wr_word_data;
    end
    if (i_rd_req) begin
      rd_word_reg <= word_mem[i_rd_addr / LANES];
      rd_lane_reg <= LANE_IDX_W'(i_rd_addr % LANES);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid_reg <= 1'b0;
    end else begin
      rd_valid_reg <= i_rd_req;
    end
  end
endmodule
