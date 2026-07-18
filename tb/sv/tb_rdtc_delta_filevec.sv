`timescale 1ns/1ps

module tb_rdtc_delta_filevec;
  tb_rdtc_encoder_filevec #(
    .CASE_DIR("vectors/rdtc_v1/smoke_delta"),
    .CFG_CODEC_MODE(2),
    .CFG_RICE_MODE(1),
    .CFG_FIXED_K(0),
    .CFG_FRAME_ID(1),
    .BLOCK_ID_BASE(5),
    .TENSOR_SPATIAL_SIZE(1),
    .TENSOR_DOPPLER_SIZE(64),
    .TENSOR_RANGE_SIZE(16)
  ) u_tb ();
endmodule
