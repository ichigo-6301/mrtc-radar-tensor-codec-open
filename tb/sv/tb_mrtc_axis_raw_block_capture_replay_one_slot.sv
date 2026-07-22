module tb_mrtc_axis_raw_block_capture_replay_one_slot;
  tb_mrtc_axis_raw_block_capture_replay #(
    .CAPTURE_SLOTS_PER_ENGINE(1)
  ) u_tb ();
endmodule
