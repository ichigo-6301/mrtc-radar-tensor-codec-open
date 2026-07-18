module mrtc_rice_bit_count (
  input  logic [31:0] i_mapped,
  input  logic [3:0]  i_k,
  output logic [31:0] o_bit_count
);
  always_comb begin
    o_bit_count = (i_mapped >> i_k) + 32'd1 + {28'd0, i_k};
  end
endmodule
