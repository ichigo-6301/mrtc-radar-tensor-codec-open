`timescale 1ns/1ps

module tb_mrtc_bounded_axis_wrapper_errors;
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;

  logic clk;
  logic rst_n;
  logic clear_status;
  logic desc_valid;
  logic desc_ready;
  logic [7:0] desc_codec;
  logic [7:0] desc_rice;
  logic [127:0] raw_tdata;
  logic raw_tvalid;
  logic raw_tready;
  logic raw_tlast;
  logic [127:0] out_tdata;
  logic out_tvalid;
  logic out_tready;
  logic out_tlast;
  logic [7:0] out_tuser;
  logic stat_busy;
  logic [31:0] stat_error;
  logic [31:0] stat_num_blocks;
  logic [4:0] stat_fifo_level;
  logic [4:0] stat_fifo_max_level;

  integer output_beats;
  integer output_packets;

  initial clk = 1'b0;
  always #2.5 clk = ~clk;

  function automatic logic [AXIS_DATA_W-1:0] test_word(
    input int variant,
    input int word_index
  );
    logic [AXIS_DATA_W-1:0] value;
    int sample_index;
    int i_value;
    int q_value;
    begin
      value = '0;
      for (int lane = 0; lane < MRTC_LANES; lane = lane + 1) begin
        sample_index = (word_index * MRTC_LANES) + lane;
        case (variant)
          1: begin
            i_value = ((sample_index * 5 + 3) % 15) - 7;
            q_value = ((sample_index * 7 + 1) % 13) - 6;
          end
          2: begin
            i_value = ((word_index == 80) && (lane == 0)) ? -61 : 0;
            q_value = 0;
          end
          default: begin
            i_value = 0;
            q_value = 0;
          end
        endcase
        value[(lane * 32) +: 16] = 16'(i_value);
        value[(lane * 32) + 16 +: 16] = 16'(q_value);
      end
      test_word = value;
    end
  endfunction

  task automatic clear_drivers;
    begin
      desc_valid = 1'b0;
      desc_codec = MRTC_CODEC_ZERO_RICE;
      desc_rice = MRTC_RICE_BLOCK_ADAPTIVE_K;
      raw_tdata = '0;
      raw_tvalid = 1'b0;
      raw_tlast = 1'b0;
      out_tready = 1'b1;
      clear_status = 1'b0;
    end
  endtask

  task automatic apply_reset;
    begin
      rst_n = 1'b0;
      clear_drivers();
      repeat (5) @(posedge clk);
      rst_n = 1'b1;
      repeat (3) @(posedge clk);
      if ((stat_error != MRTC_ERR_NONE) || stat_busy || !desc_ready) begin
        $fatal(1, "direct reset failed error=%0d busy=%0d desc_ready=%0d",
               stat_error, stat_busy, desc_ready);
      end
    end
  endtask

  task automatic pulse_clear_status;
    begin
      @(negedge clk);
      clear_status = 1'b1;
      @(negedge clk);
      clear_status = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic send_descriptor(
    input logic [7:0] codec,
    input logic [7:0] rice
  );
    begin
      @(negedge clk);
      desc_codec = codec;
      desc_rice = rice;
      desc_valid = 1'b1;
      do begin
        @(posedge clk);
      end while (!desc_ready);
      @(negedge clk);
      desc_valid = 1'b0;
    end
  endtask

  task automatic drive_words(
    input int variant,
    input int word_limit,
    input int tlast_word,
    input bit stop_on_error
  );
    begin : drive_loop
      for (int word_index = 0; word_index < word_limit; word_index = word_index + 1) begin
        @(negedge clk);
        raw_tdata = test_word(variant, word_index);
        raw_tvalid = 1'b1;
        raw_tlast = (word_index == tlast_word);
        @(posedge clk);
        if (!raw_tready) begin
          if (stop_on_error && (stat_error != MRTC_ERR_NONE)) begin
            disable drive_loop;
          end
          $fatal(1, "unexpected direct input stall word=%0d error=%0d",
                 word_index, stat_error);
        end
      end
      @(negedge clk);
      raw_tdata = '0;
      raw_tvalid = 1'b0;
      raw_tlast = 1'b0;
    end
  endtask

  task automatic expect_error(
    input logic [31:0] expected_error,
    input string label
  );
    begin
      for (int wait_cycle = 0;
           (wait_cycle < 2000) && (stat_error == MRTC_ERR_NONE);
           wait_cycle = wait_cycle + 1) begin
        @(posedge clk);
      end
      #1;
      if (stat_error != expected_error) begin
        $fatal(1, "%s expected error=%0d got=%0d",
               label, expected_error, stat_error);
      end
      repeat (3) @(posedge clk);
      if (raw_tready || desc_ready || out_tvalid) begin
        $fatal(1, "%s fail-stop violation raw_ready=%0d desc_ready=%0d out_valid=%0d",
               label, raw_tready, desc_ready, out_tvalid);
      end
      pulse_clear_status();
      if ((stat_error != expected_error) || raw_tready || desc_ready) begin
        $fatal(1, "%s clear_status incorrectly recovered fatal", label);
      end
      $display("PASS direct_error label=%s error=%0d output_beats=%0d packets=%0d",
               label, stat_error, output_beats, output_packets);
    end
  endtask

  task automatic run_legal_recovery;
    integer packets_before;
    begin
      packets_before = output_packets;
      send_descriptor(MRTC_CODEC_ZERO_RICE, MRTC_RICE_BLOCK_ADAPTIVE_K);
      drive_words(0, BLOCK_WORDS, BLOCK_WORDS - 1, 1'b0);
      for (int wait_cycle = 0;
           (wait_cycle < 5000) && (output_packets == packets_before);
           wait_cycle = wait_cycle + 1) begin
        @(posedge clk);
      end
      if ((output_packets != (packets_before + 1)) ||
          (stat_error != MRTC_ERR_NONE) || (stat_num_blocks != 1)) begin
        $fatal(1,
               "post-error recovery failed packets=%0d/%0d error=%0d blocks=%0d",
               output_packets, packets_before + 1, stat_error, stat_num_blocks);
      end
      $display("PASS direct_error post_reset_recovery");
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      output_beats <= 0;
      output_packets <= 0;
    end else if (out_tvalid && out_tready) begin
      output_beats <= output_beats + 1;
      if (out_tlast) begin
        output_packets <= output_packets + 1;
      end
    end
  end

  initial begin
    rst_n = 1'b0;
    clear_drivers();

    apply_reset();
    @(negedge clk);
    raw_tvalid = 1'b1;
    raw_tdata = '0;
    raw_tlast = 1'b0;
    @(posedge clk);
    @(negedge clk);
    raw_tvalid = 1'b0;
    expect_error(MRTC_ERR_BLOCK_NOT_READY, "data_before_descriptor");

    apply_reset();
    send_descriptor(MRTC_CODEC_DELTA_RICE, MRTC_RICE_BLOCK_ADAPTIVE_K);
    expect_error(MRTC_ERR_UNSUPPORTED_CODEC, "invalid_codec");

    apply_reset();
    send_descriptor(MRTC_CODEC_ZERO_RICE, MRTC_RICE_FIXED_K);
    expect_error(MRTC_ERR_UNSUPPORTED_RICE, "invalid_rice");

    apply_reset();
    send_descriptor(MRTC_CODEC_ZERO_RICE, MRTC_RICE_BLOCK_ADAPTIVE_K);
    drive_words(0, 1, 0, 1'b1);
    expect_error(MRTC_ERR_TLAST_EARLY, "early_tlast");

    apply_reset();
    send_descriptor(MRTC_CODEC_ZERO_RICE, MRTC_RICE_BLOCK_ADAPTIVE_K);
    drive_words(0, BLOCK_WORDS, -1, 1'b1);
    expect_error(MRTC_ERR_INPUT_TOO_SHORT, "late_tlast");

    apply_reset();
    send_descriptor(MRTC_CODEC_ZERO_RICE, MRTC_RICE_BLOCK_ADAPTIVE_K);
    drive_words(2, 160, -1, 1'b1);
    expect_error(MRTC_ERR_BOUNDED_RICE_WORD, "word_129_bits");

    apply_reset();
    send_descriptor(MRTC_CODEC_ZERO_RICE, MRTC_RICE_BLOCK_ADAPTIVE_K);
    fork
      drive_words(1, BLOCK_WORDS, BLOCK_WORDS - 1, 1'b1);
      begin
        wait (output_beats == 5);
        @(negedge clk);
        out_tready = 1'b0;
      end
    join
    expect_error(MRTC_ERR_OUTPUT_CREDIT, "output_credit_exhausted");
    if ((output_beats != 5) || (output_packets != 0) ||
        (stat_fifo_max_level != 16)) begin
      $fatal(1,
             "credit exhaustion visibility mismatch beats=%0d packets=%0d fifo_max=%0d",
             output_beats, output_packets, stat_fifo_max_level);
    end

    apply_reset();
    run_legal_recovery();

    $display("PASS tb_mrtc_bounded_axis_wrapper_errors");
    $finish;
  end

  initial begin
    repeat (100000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_bounded_axis_wrapper_errors error=%0d", stat_error);
  end

  mrtc_rdtc_bounded_axis_multiengine_wrapper u_dut (
    .clk,
    .rst_n,
    .i_clear_status              (clear_status),
    .s_desc_valid                (desc_valid),
    .s_desc_ready                (desc_ready),
    .s_desc_block_id             (16'd0),
    .s_desc_block_range_start    (16'd0),
    .s_desc_frame_id             (16'hda02),
    .s_desc_codec_mode           (desc_codec),
    .s_desc_rice_mode            (desc_rice),
    .s_desc_fixed_k              (4'd0),
    .s_desc_tensor_spatial_size  (16'd1),
    .s_desc_tensor_doppler_size  (16'd64),
    .s_desc_tensor_range_size    (16'd16),
    .s_desc_last_block           (1'b1),
    .s_axis_raw_tdata            (raw_tdata),
    .s_axis_raw_tvalid           (raw_tvalid),
    .s_axis_raw_tready           (raw_tready),
    .s_axis_raw_tlast            (raw_tlast),
    .m_axis_comp_tdata           (out_tdata),
    .m_axis_comp_tvalid          (out_tvalid),
    .m_axis_comp_tready          (out_tready),
    .m_axis_comp_tlast           (out_tlast),
    .m_axis_comp_tuser           (out_tuser),
    .stat_busy,
    .stat_done                   (),
    .stat_num_blocks,
    .stat_raw_bytes              (),
    .stat_comp_bytes             (),
    .stat_error,
    .stat_stall_input_cycles     (),
    .stat_stall_output_cycles    (),
    .stat_desc_accepted          (),
    .stat_input_blocks           (),
    .stat_output_packets         (),
    .stat_output_fifo_level      (stat_fifo_level),
    .stat_output_fifo_max_level  (stat_fifo_max_level)
  );
endmodule
