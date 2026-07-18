module mrtc_block_sample_mem #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 1024,
  parameter int ADDR_W = 10,
`ifdef MRTC_FPGA_XILINX
  parameter string MEM_STYLE = "auto",
`endif
  parameter bit ASYNC_READ   = 1'b1,
  parameter int READ_LATENCY = 0
) (
  input  logic              clk,
  input  logic              wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [DATA_W-1:0] wr_data,
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [DATA_W-1:0] rd_data
);
  // Zero-latency reg-array wrapper used as a cleanup step before any future
  // RAM-style refactor. This keeps the current async-read behavior intact.
  //
  // Stage 13B-2C metadata policy:
  // - active supported mode is ASYNC_READ=1 and READ_LATENCY=0
  // - non-default latency behavior is future work and is not implemented here
  // - MEM_STYLE is only a synthesis hint hook; it is not an ASIC SRAM wrapper
  //   contract and is disabled unless an external flow explicitly enables it
`ifdef MRTC_FPGA_XILINX
  (* ram_style = MEM_STYLE *)
`endif
  logic [DATA_W-1:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      mem[wr_addr] <= wr_data;
    end
  end

  assign rd_data = mem[rd_addr];
endmodule
