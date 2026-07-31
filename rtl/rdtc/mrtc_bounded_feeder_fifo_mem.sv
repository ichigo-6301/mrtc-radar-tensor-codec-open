module mrtc_bounded_feeder_fifo_mem #(
  parameter int DATA_W = 128,
  parameter int DEPTH  = 64,
  parameter int ADDR_W = $clog2(DEPTH)
) (
  input  logic                  clk,
  input  logic                  i_wr_en,
  input  logic [ADDR_W-1:0]     i_wr_addr,
  input  logic [DATA_W-1:0]     i_wr_data,
  input  logic                  i_rd_en,
  input  logic [ADDR_W-1:0]     i_rd_addr,
  output logic [DATA_W-1:0]     o_rd_data
);
  localparam int DATA_W_CHECK = 1 / ((DATA_W == 128) ? 1 : 0);
  localparam int DEPTH_CHECK  = 1 / ((DEPTH == 64) ? 1 : 0);

`ifdef RDTC_BOUNDED_ASIC_REGISTER_EXPANDED
`ifdef RDTC_BOUNDED_ASIC_SRAM
  initial $fatal(1, "bounded ASIC register and SRAM profiles are mutually exclusive");
`endif
`endif

`ifdef RDTC_BOUNDED_ASIC_SRAM
  localparam int LANE_W = 32;
  localparam int LANES  = DATA_W / LANE_W;
  logic [DATA_W-1:0] macro_rd_data;

  for (genvar lane = 0; lane < LANES; lane = lane + 1) begin : g_sram_lane
    mrtc_rdtc_bounded_feeder_1rw1r_64x32 u_sram (
      .clk0  (clk),
      .csb0  (~i_wr_en),
      .web0  (1'b0),
      .addr0 (i_wr_addr),
      .din0  (i_wr_data[(lane*LANE_W) +: LANE_W]),
      .dout0 (),
      .clk1  (clk),
      .csb1  (~i_rd_en),
      .addr1 (i_rd_addr),
      .dout1 (macro_rd_data[(lane*LANE_W) +: LANE_W])
    );
  end

  assign o_rd_data = macro_rd_data;
`else
  (* ram_style = "registers" *) logic [DATA_W-1:0] mem [0:DEPTH-1];
  logic [DATA_W-1:0] rd_data_reg;

  assign o_rd_data = rd_data_reg;

  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      mem[i_wr_addr] <= i_wr_data;
    end
    if (i_rd_en) begin
      rd_data_reg <= mem[i_rd_addr];
    end
  end
`endif

`ifndef RDTC_BOUNDED_ASIC_REGISTER_EXPANDED
`ifndef RDTC_BOUNDED_ASIC_SRAM
  initial $fatal(1, "mrtc_bounded_feeder_fifo_mem requires a bounded ASIC storage profile");
`endif
`endif

  logic unused_static_checks;
  assign unused_static_checks = DATA_W_CHECK[0] ^ DEPTH_CHECK[0];
endmodule
