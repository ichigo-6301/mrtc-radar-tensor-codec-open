`timescale 1ns/1ps

module tb_rdtc_multi_block_filevec;
  tb_rdtc_encoder_filevec #(
    .CASE_DIR("vectors/rdtc_v1/smoke_multi_block"),
    .CFG_CODEC_MODE(1),
    .CFG_RICE_MODE(1),
    .CFG_FIXED_K(0),
    .CFG_FRAME_ID(1),
    .BLOCK_ID_BASE(6),
    .TENSOR_SPATIAL_SIZE(1),
    .TENSOR_DOPPLER_SIZE(64),
    .TENSOR_RANGE_SIZE(32)
  ) u_tb ();
endmodule
