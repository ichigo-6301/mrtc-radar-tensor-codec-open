module mrtc_residual_map (
  input  logic signed [17:0] i_residual,
  output logic [31:0]        o_mapped
);
  always_comb begin
    if (i_residual >= 0) begin
      o_mapped = $unsigned(i_residual <<< 1);
    end else begin
      o_mapped = $unsigned((-i_residual <<< 1) - 1);
    end
  end
endmodule
