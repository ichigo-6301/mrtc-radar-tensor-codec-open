module mrtc_shallow_1rw_way #(
  parameter int AXIS_DATA_W      = 128,
  parameter int WAY_DEPTH_WORDS  = 32
) (
  input  logic                                      clk,
  input  logic                                      i_cmd_valid,
  input  logic                                      i_cmd_write,
  input  logic [$clog2(WAY_DEPTH_WORDS)-1:0]        i_cmd_addr,
  input  logic [AXIS_DATA_W-1:0]                    i_wr_data,
  output logic [AXIS_DATA_W-1:0]                    o_rd_data
);
  localparam int AXIS_DATA_W_CHECK = 1 / ((AXIS_DATA_W > 0) ? 1 : 0);
  localparam int WAY_DEPTH_CHECK = 1 / ((WAY_DEPTH_WORDS > 1) ? 1 : 0);

`ifdef RDTC_BOUNDED_ASIC_REGISTER_EXPANDED
`define MRTC_SHALLOW_1RW_WAY_FORCE_REGISTERS
`endif
`ifdef RDTC_BOUNDED_DIRECT_ASIC_REGISTER_EXPANDED
`define MRTC_SHALLOW_1RW_WAY_FORCE_REGISTERS
`endif
`ifdef RDTC_BOUNDED_ASIC_SRAM
`define MRTC_SHALLOW_1RW_WAY_FORCE_SRAM
`endif
`ifdef RDTC_BOUNDED_DIRECT_ASIC_SRAM
`define MRTC_SHALLOW_1RW_WAY_FORCE_SRAM
`endif

`ifdef MRTC_SHALLOW_1RW_WAY_FORCE_REGISTERS
`ifdef MRTC_SHALLOW_1RW_WAY_FORCE_SRAM
  initial $fatal(1, "bounded ASIC register and SRAM profiles are mutually exclusive");
`endif
`endif

`ifdef MRTC_SHALLOW_1RW_WAY_FORCE_SRAM
  mrtc_rdtc_bounded_ring_1rw_32x128 u_sram (
    .clk0  (clk),
    .csb0  (~i_cmd_valid),
    .web0  (~i_cmd_write),
    .addr0 (i_cmd_addr),
    .din0  (i_wr_data),
    .dout0 (o_rd_data)
  );

  initial begin
    if ((AXIS_DATA_W != 128) || (WAY_DEPTH_WORDS != 32)) begin
      $fatal(1, "bounded ring SRAM requires AXIS_DATA_W=128 and WAY_DEPTH_WORDS=32");
    end
  end
`else
`ifdef MRTC_SHALLOW_1RW_WAY_FORCE_REGISTERS
  (* ram_style = "registers" *)
`else
  (* ram_style = "distributed" *)
`endif
  logic [AXIS_DATA_W-1:0] mem [0:WAY_DEPTH_WORDS-1];

  // A unified command/address port makes the 1RW behavior explicit to both
  // simulation and memory inference.
  always_ff @(posedge clk) begin
    if (i_cmd_valid) begin
      if (i_cmd_write) begin
        mem[i_cmd_addr] <= i_wr_data;
      end else begin
        o_rd_data <= mem[i_cmd_addr];
      end
    end
  end
`endif

`ifdef MRTC_SHALLOW_1RW_WAY_FORCE_REGISTERS
`undef MRTC_SHALLOW_1RW_WAY_FORCE_REGISTERS
`endif
`ifdef MRTC_SHALLOW_1RW_WAY_FORCE_SRAM
`undef MRTC_SHALLOW_1RW_WAY_FORCE_SRAM
`endif
endmodule
