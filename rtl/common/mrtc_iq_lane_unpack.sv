module mrtc_iq_lane_unpack #(
  parameter int LANES = 4
) (
  input  logic [(LANES*32)-1:0] i_tdata,
  output logic [(LANES*16)-1:0] o_i_flat,
  output logic [(LANES*16)-1:0] o_q_flat
);
  localparam int LANES_SUPPORTED_CHECK =
    1 / (((LANES == 1) ||
          (LANES == 2) ||
          (LANES == 4) ||
          (LANES == 8) ||
          (LANES == 16)) ? 1 : 0);

  generate
    genvar lane_idx;
    for (lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin : g_lane_unpack
      assign o_i_flat[(lane_idx*16) +: 16] = i_tdata[(lane_idx*32) +: 16];
      assign o_q_flat[(lane_idx*16) +: 16] = i_tdata[(lane_idx*32) + 16 +: 16];
    end
  endgenerate
endmodule
