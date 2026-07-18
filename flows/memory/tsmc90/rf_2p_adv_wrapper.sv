// Local integration adapter. The generated RF_2P_ADV model is proprietary and
// is supplied only through the ignored IC_EDA_FULL setup.
`ifndef RDTC_TSMC90_GENERATED_CELL
`define RDTC_TSMC90_GENERATED_CELL RF_2P_ADV
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

  `RDTC_TSMC90_GENERATED_CELL u_generated (
    .CLKA(clk1), .CENA(csb1), .AA(addr1), .QA(read_data),
    .CLKB(clk0), .CENB(csb0), .AB(addr0), .DB(din0),
    .EMAA(3'b000), .EMAB(3'b000)
  );

  assign dout1 = read_data;
endmodule
