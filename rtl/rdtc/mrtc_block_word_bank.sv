module mrtc_block_word_bank #(
  parameter int AXIS_DATA_W   = 128,
  parameter int LANES         = 4,
  parameter int BLOCK_SAMPLES = 1024,
`ifdef MRTC_FPGA_XILINX
  parameter string MEM_STYLE  = "block",
`endif
  parameter int READ_LATENCY  = 1
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   i_clear,
  input  logic                                   i_wr_en,
  input  logic [$clog2(BLOCK_SAMPLES/LANES)-1:0] i_wr_word_addr,
  input  logic [AXIS_DATA_W-1:0]                 i_wr_word_data,
  input  logic                                   i_rd_req,
  input  logic [$clog2(BLOCK_SAMPLES/LANES)-1:0] i_rd_word_addr,
  output logic                                   o_rd_valid,
  output logic [AXIS_DATA_W-1:0]                 o_rd_word_data
);
  localparam int BLOCK_WORDS = BLOCK_SAMPLES / LANES;
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
  localparam int READ_LATENCY_CHECK =
    1 / ((READ_LATENCY == 1) ? 1 : 0);

`ifdef MRTC_FPGA_XILINX
  (* ram_style = MEM_STYLE *)
`endif
  logic [AXIS_DATA_W-1:0] mem [0:BLOCK_WORDS-1];
  logic                   rd_valid_reg;
  logic [AXIS_DATA_W-1:0] rd_word_data_reg;

  assign o_rd_valid     = rst_n && rd_valid_reg;
  assign o_rd_word_data = (rst_n && rd_valid_reg) ? rd_word_data_reg : '0;

  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      mem[i_wr_word_addr] <= i_wr_word_data;
    end
    if (i_rd_req) begin
      rd_word_data_reg <= mem[i_rd_word_addr];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid_reg <= 1'b0;
    end else begin
      if (i_clear) begin
        rd_valid_reg <= 1'b0;
      end else begin
        rd_valid_reg <= i_rd_req;
      end
    end
  end
endmodule
