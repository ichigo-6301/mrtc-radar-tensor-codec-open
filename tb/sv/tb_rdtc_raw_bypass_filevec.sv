module tb_rdtc_raw_bypass_filevec;
  tb_rdtc_encoder_filevec #(
    .CASE_DIR("vectors/rdtc_v1/smoke_raw_bypass"),
    .CFG_CODEC_MODE(1),
    .CFG_RICE_MODE(1),
    .CFG_FIXED_K(0),
    .CFG_FRAME_ID(1),
    .BLOCK_ID_BASE(4),
    .TENSOR_RANGE_SIZE(16)
  ) u_tb ();
endmodule
