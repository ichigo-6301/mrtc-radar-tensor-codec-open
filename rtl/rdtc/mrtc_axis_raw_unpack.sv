module mrtc_axis_raw_unpack (
  input  logic [127:0] i_tdata,
  output logic [31:0]  o_sample0,
  output logic [31:0]  o_sample1,
  output logic [31:0]  o_sample2,
  output logic [31:0]  o_sample3
);
  // Legacy fixed-width helper for the active 128-bit encoder input path.
  // Stage 16B-1A adds the generic lane-order scaffold in mrtc_iq_lane_unpack.
  assign o_sample0 = i_tdata[31:0];
  assign o_sample1 = i_tdata[63:32];
  assign o_sample2 = i_tdata[95:64];
  assign o_sample3 = i_tdata[127:96];
endmodule
