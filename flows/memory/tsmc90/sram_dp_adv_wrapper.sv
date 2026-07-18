// Local integration adapter. The generated SRAM_DP_ADV model is proprietary
// and is supplied only through the ignored IC_EDA_FULL setup.
`ifndef RDTC_TSMC90_GENERATED_SRAM_CELL
`define RDTC_TSMC90_GENERATED_SRAM_CELL SRAM_DP_ADV
`endif

module mrtc_rdtc_prefix_1r1w_64x128 (
  input  logic         clk0,
  input  logic         csb0,
  input  logic [5:0]   addr0,
  input  logic [127:0] din0,
  input  logic         clk1,
  input  logic         csb1,
  input  logic [5:0]   addr1,
  output logic [127:0] dout1
);
  logic [127:0] read_data;
  logic [127:0] unused_write_port_data;

  `RDTC_TSMC90_GENERATED_SRAM_CELL u_generated (
    .CLKA(clk1),
    .CENA(csb1),
    .WENA(1'b1),
    .AA({1'b0, addr1}),
    .DA('0),
    .QA(read_data),
    .CLKB(clk0),
    .CENB(csb0),
    .WENB(1'b0),
    .AB({1'b0, addr0}),
    .DB(din0),
    .QB(unused_write_port_data),
    .EMAA(3'b000),
    .EMAB(3'b000)
  );

  assign dout1 = read_data;
endmodule
