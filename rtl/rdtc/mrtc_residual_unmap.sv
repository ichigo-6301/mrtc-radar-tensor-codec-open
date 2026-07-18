module mrtc_residual_unmap (
  input  logic [31:0] i_mapped,
  output logic signed [31:0] o_residual
);
  always_comb begin
    if (i_mapped[0]) begin
      o_residual = -$signed({1'b0, ((i_mapped + 32'd1) >> 1)});
    end else begin
      o_residual = $signed({1'b0, (i_mapped >> 1)});
    end
  end
endmodule
