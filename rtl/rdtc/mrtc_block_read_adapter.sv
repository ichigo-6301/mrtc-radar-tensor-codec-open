module mrtc_block_read_adapter #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 1024,
  parameter int ADDR_W = 10,
  parameter int READ_LATENCY = 0
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic [DEPTH*DATA_W-1:0] i_block_mem_flat,
  input  logic                    i_rd_req,
  input  logic [ADDR_W-1:0]       i_rd_addr,
  output logic                    o_rd_valid,
  output logic [DATA_W-1:0]       o_rd_data,
  output logic                    o_error
);
  genvar gi;
  logic [DATA_W-1:0] sample_words [0:DEPTH-1];

  generate
    for (gi = 0; gi < DEPTH; gi = gi + 1) begin : g_sample_words
      assign sample_words[gi] = i_block_mem_flat[(gi*DATA_W) +: DATA_W];
    end
  endgenerate

  generate
    if (READ_LATENCY == 0) begin : g_read_latency_0
      logic [DATA_W-1:0] rd_data_comb;
      int unsigned idx;

      always @* begin
        rd_data_comb = '0;
        for (idx = 0; idx < DEPTH; idx = idx + 1) begin
          if (i_rd_addr == ADDR_W'(idx)) begin
            rd_data_comb = sample_words[idx];
          end
        end
      end

      assign o_rd_valid = i_rd_req;
      assign o_rd_data  = rd_data_comb;
      assign o_error    = 1'b0;
    end else begin : g_read_latency_unsupported
      assign o_rd_valid = 1'b0;
      assign o_rd_data  = '0;
      assign o_error    = i_rd_req;
    end
  endgenerate

  // Stage 14B-1 protocol bring-up note:
  // - this adapter is a standalone req/valid bridge over the existing
  //   whole-block flat memory view
  // - it is not instantiated in the active encoder/decoder datapath
  // - it is not the final SRAM/BRAM-friendly structure
  // - READ_LATENCY=1 remains future work and is intentionally unsupported here
  logic unused_clk;
  logic unused_rst_n;
  assign unused_clk   = clk;
  assign unused_rst_n = rst_n;
endmodule
