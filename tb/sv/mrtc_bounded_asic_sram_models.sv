`timescale 1ns/1ps

module mrtc_rdtc_bounded_feeder_1rw1r_64x32 (
  input  logic        clk0,
  input  logic        csb0,
  input  logic        web0,
  input  logic [5:0]  addr0,
  input  logic [31:0] din0,
  output logic [31:0] dout0,
  input  logic        clk1,
  input  logic        csb1,
  input  logic [5:0]  addr1,
  output logic [31:0] dout1
);
  logic [31:0] mem [0:63];
  logic csb0_reg;
  logic web0_reg;
  logic [5:0] addr0_reg;
  logic [31:0] din0_reg;
  logic csb1_reg;
  logic [5:0] addr1_reg;

  always_ff @(posedge clk0) begin
    csb0_reg <= csb0;
    web0_reg <= web0;
    addr0_reg <= addr0;
    din0_reg <= din0;
  end

  always_ff @(posedge clk1) begin
    csb1_reg <= csb1;
    addr1_reg <= addr1;
  end

  always_ff @(negedge clk0) begin
    if (!csb0_reg) begin
      if (!web0_reg) mem[addr0_reg] <= din0_reg;
      else dout0 <= mem[addr0_reg];
    end
  end

  always_ff @(negedge clk1) begin
    if (!csb1_reg) dout1 <= mem[addr1_reg];
  end
endmodule

module mrtc_rdtc_bounded_ring_1rw_32x128 (
  input  logic         clk0,
  input  logic         csb0,
  input  logic         web0,
  input  logic [4:0]   addr0,
  input  logic [127:0] din0,
  output logic [127:0] dout0
);
  logic [127:0] mem [0:31];
  logic csb0_reg;
  logic web0_reg;
  logic [4:0] addr0_reg;
  logic [127:0] din0_reg;

  always_ff @(posedge clk0) begin
    csb0_reg <= csb0;
    web0_reg <= web0;
    addr0_reg <= addr0;
    din0_reg <= din0;
  end

  always_ff @(negedge clk0) begin
    if (!csb0_reg) begin
      if (!web0_reg) mem[addr0_reg] <= din0_reg;
      else dout0 <= mem[addr0_reg];
    end
  end
endmodule

module mrtc_rdtc_block_1rw_256x32 (
  input  logic        clk0,
  input  logic        csb0,
  input  logic        web0,
  input  logic [7:0]  addr0,
  input  logic [31:0] din0,
  output logic [31:0] dout0
);
  logic [31:0] mem [0:255];
  logic csb0_reg;
  logic web0_reg;
  logic [7:0] addr0_reg;
  logic [31:0] din0_reg;

  always_ff @(posedge clk0) begin
    csb0_reg <= csb0;
    web0_reg <= web0;
    addr0_reg <= addr0;
    din0_reg <= din0;
  end

  always_ff @(negedge clk0) begin
    if (!csb0_reg) begin
      if (!web0_reg) mem[addr0_reg] <= din0_reg;
      else dout0 <= mem[addr0_reg];
    end
  end
endmodule
