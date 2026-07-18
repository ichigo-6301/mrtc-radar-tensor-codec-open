module mrtc_block_sample_read_adapter #(
  parameter int AXIS_DATA_W   = 128,
  parameter int LANES         = 4,
  parameter int BLOCK_SAMPLES = 1024
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   i_sample_rd_req,
  input  logic [$clog2(BLOCK_SAMPLES)-1:0]       i_sample_rd_addr,
  output logic                                   o_bank_rd_req,
  output logic [$clog2(BLOCK_SAMPLES/LANES)-1:0] o_bank_rd_word_addr,
  input  logic                                   i_bank_rd_valid,
  input  logic [AXIS_DATA_W-1:0]                 i_bank_rd_word_data,
  output logic                                   o_sample_rd_valid,
  output logic [31:0]                            o_sample_rd_data
);
  localparam int BLOCK_WORDS = BLOCK_SAMPLES / LANES;
  localparam int LANE_IDX_W  = (LANES <= 1) ? 1 : $clog2(LANES);
  localparam int LANES_SUPPORTED_CHECK =
    1 / (((LANES == 1) ||
          (LANES == 2) ||
          (LANES == 4) ||
          (LANES == 8) ||
          (LANES == 16)) ? 1 : 0);
  localparam int AXIS_DATA_W_CHECK =
    1 / ((AXIS_DATA_W == (LANES * 32)) ? 1 : 0);
  localparam int BLOCK_SAMPLES_CHECK =
    1 / (((BLOCK_SAMPLES % LANES) == 0) ? 1 : 0);

  logic [LANE_IDX_W-1:0] lane_idx_reg;
  logic                  pending_reg;
  int                    lane_idx_int;

  assign o_bank_rd_req       = i_sample_rd_req;
  assign o_bank_rd_word_addr = (i_sample_rd_addr / LANES);
  assign o_sample_rd_valid   = i_bank_rd_valid && pending_reg;

  always_comb begin
    o_sample_rd_data = 32'd0;
    for (lane_idx_int = 0; lane_idx_int < LANES; lane_idx_int = lane_idx_int + 1) begin
      if (lane_idx_reg == LANE_IDX_W'(lane_idx_int)) begin
        o_sample_rd_data = i_bank_rd_word_data[(lane_idx_int*32) +: 32];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lane_idx_reg <= '0;
      pending_reg  <= 1'b0;
    end else begin
      if (i_sample_rd_req) begin
        lane_idx_reg <= LANE_IDX_W'(i_sample_rd_addr % LANES);
        pending_reg  <= 1'b1;
      end
      if (i_bank_rd_valid) begin
        pending_reg <= 1'b0;
      end
    end
  end
endmodule
