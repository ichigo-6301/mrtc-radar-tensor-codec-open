module mrtc_rice_decoder (
  input  logic [7:0]        i_codec_mode,
  input  logic signed [15:0] i_prev_sample,
  input  logic [31:0]       i_mapped,
  input  logic              i_is_first_sample,
  output logic signed [15:0] o_sample,
  output logic               o_error
);
  import mrtc_pkg::*;

  logic signed [31:0] residual;
  logic signed [31:0] pred;
  logic signed [31:0] value;

  mrtc_residual_unmap u_residual_unmap (
    .i_mapped  (i_mapped),
    .o_residual(residual)
  );

  always_comb begin
    pred = 32'sd0;
    if ((i_codec_mode == MRTC_CODEC_DELTA_RICE) && !i_is_first_sample) begin
      pred = $signed(i_prev_sample);
    end
    value = pred + residual;
    o_error = (value < -32'sd32768) || (value > 32'sd32767);
    o_sample = value[15:0];
  end
endmodule
