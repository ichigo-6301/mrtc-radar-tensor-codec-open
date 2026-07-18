`timescale 1ns/1ps

module tb_mrtc_rdtc_encoder_axis_bp_smallbuf;
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int LANES = 4;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / LANES;

  logic clk;
  logic rst_n;

  logic [AXIS_DATA_W-1:0] enc_s_tdata;
  logic enc_s_tvalid;
  logic enc_s_tready;
  logic enc_s_tlast;
  logic [7:0] enc_s_tuser;

  logic [AXIS_DATA_W-1:0] enc_m_tdata;
  logic enc_m_tvalid;
  logic enc_m_tready;
  logic enc_m_tlast;
  logic [7:0] enc_m_tuser;

  logic [AXIS_DATA_W-1:0] dec_s_tdata;
  logic dec_s_tvalid;
  logic dec_s_tready;
  logic dec_s_tlast;
  logic [7:0] dec_s_tuser;

  logic [AXIS_DATA_W-1:0] dec_m_tdata;
  logic dec_m_tvalid;
  logic dec_m_tready;
  logic dec_m_tlast;
  logic [7:0] dec_m_tuser;

  logic enc_busy;
  logic enc_done;
  logic [31:0] enc_raw_bytes;
  logic [31:0] enc_comp_bytes;
  logic [31:0] enc_num_blocks;
  logic [31:0] enc_error;
  logic [31:0] enc_raw_bypass_blocks;
  logic [31:0] enc_stall_input_cycles;
  logic [31:0] enc_stall_output_cycles;

  logic dec_busy;
  logic dec_done;
  logic [31:0] dec_comp_bytes;
  logic [31:0] dec_raw_bytes;
  logic [31:0] dec_num_blocks;
  logic [31:0] dec_error;
  logic [31:0] dec_error_blocks;
  logic [31:0] dec_stall_input_cycles;
  logic [31:0] dec_stall_output_cycles;

  logic link_ready_gate;
  logic enable_backpressure;
  logic driver_done;
  logic monitor_done;
  logic [7:0] active_codec_mode;
  string active_case_name;

  logic [AXIS_DATA_W-1:0] block_words [0:BLOCK_WORDS-1];

  initial clk = 1'b0;
  always #5 clk = ~clk;

  assign enc_m_tready = dec_s_tready && link_ready_gate;
  assign dec_s_tvalid = enc_m_tvalid && link_ready_gate;
  assign dec_s_tdata  = enc_m_tdata;
  assign dec_s_tlast  = enc_m_tlast;
  assign dec_s_tuser  = enc_m_tuser;

  mrtc_rdtc_encoder_top_axis_bp_smallbuf #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .PREFIX_SAMPLES(256),
    .ENABLE_INTERNAL_RAW_BYPASS(1'b0)
  ) u_encoder (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .i_clear_status         (1'b0),
    .s_axis_raw_tdata       (enc_s_tdata),
    .s_axis_raw_tvalid      (enc_s_tvalid),
    .s_axis_raw_tready      (enc_s_tready),
    .s_axis_raw_tlast       (enc_s_tlast),
    .s_axis_raw_tuser       (enc_s_tuser),
    .m_axis_comp_tdata      (enc_m_tdata),
    .m_axis_comp_tvalid     (enc_m_tvalid),
    .m_axis_comp_tready     (enc_m_tready),
    .m_axis_comp_tlast      (enc_m_tlast),
    .m_axis_comp_tuser      (enc_m_tuser),
    .cfg_codec_mode         (active_codec_mode),
    .cfg_rice_mode          (MRTC_RICE_BLOCK_ADAPTIVE_K),
    .cfg_fixed_k            (4'd0),
    .cfg_frame_id           (16'd19),
    .cfg_block_id_base      (16'd0),
    .cfg_tensor_spatial_size(16'd1),
    .cfg_tensor_doppler_size(16'd64),
    .cfg_tensor_range_size  (16'd16),
    .stat_busy              (enc_busy),
    .stat_done              (enc_done),
    .stat_raw_bytes         (enc_raw_bytes),
    .stat_comp_bytes        (enc_comp_bytes),
    .stat_num_blocks        (enc_num_blocks),
    .stat_error             (enc_error),
    .stat_raw_bypass_blocks (enc_raw_bypass_blocks),
    .stat_stall_input_cycles(enc_stall_input_cycles),
    .stat_stall_output_cycles(enc_stall_output_cycles)
  );

  mrtc_rdtc_decoder_top #(
    .AXIS_DATA_W(AXIS_DATA_W)
  ) u_decoder (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .i_clear_status         (1'b0),
    .s_axis_comp_tdata      (dec_s_tdata),
    .s_axis_comp_tvalid     (dec_s_tvalid),
    .s_axis_comp_tready     (dec_s_tready),
    .s_axis_comp_tlast      (dec_s_tlast),
    .s_axis_comp_tuser      (dec_s_tuser),
    .m_axis_raw_tdata       (dec_m_tdata),
    .m_axis_raw_tvalid      (dec_m_tvalid),
    .m_axis_raw_tready      (dec_m_tready),
    .m_axis_raw_tlast       (dec_m_tlast),
    .m_axis_raw_tuser       (dec_m_tuser),
    .stat_busy              (dec_busy),
    .stat_done              (dec_done),
    .stat_comp_bytes        (dec_comp_bytes),
    .stat_raw_bytes         (dec_raw_bytes),
    .stat_num_blocks        (dec_num_blocks),
    .stat_error             (dec_error),
    .stat_error_blocks      (dec_error_blocks),
    .stat_stall_input_cycles(dec_stall_input_cycles),
    .stat_stall_output_cycles(dec_stall_output_cycles)
  );

  function automatic logic [31:0] sample_word(
    input logic signed [15:0] i_s16,
    input logic signed [15:0] q_s16
  );
    sample_word = {q_s16[15:0], i_s16[15:0]};
  endfunction

  function automatic logic [AXIS_DATA_W-1:0] pack_word(
    input logic [31:0] s0,
    input logic [31:0] s1,
    input logic [31:0] s2,
    input logic [31:0] s3
  );
    pack_word = {s3, s2, s1, s0};
  endfunction

  task automatic fill_all_zero;
    for (int w = 0; w < BLOCK_WORDS; w = w + 1) begin
      block_words[w] = '0;
    end
  endtask

  task automatic fill_sparse;
    fill_all_zero();
    block_words[4] = pack_word(sample_word(16'sd16, -16'sd8), 32'd0, 32'd0, 32'd0);
    block_words[20] = pack_word(32'd0, sample_word(-16'sd31, 16'sd7), 32'd0, 32'd0);
    block_words[63] = pack_word(32'd0, 32'd0, sample_word(16'sd12, 16'sd12), 32'd0);
    block_words[130] = pack_word(sample_word(16'sd23, -16'sd19), 32'd0, 32'd0, 32'd0);
  endtask

  task automatic fill_ramp;
    logic [31:0] samples [0:LANES-1];
    for (int w = 0; w < BLOCK_WORDS; w = w + 1) begin
      for (int l = 0; l < LANES; l = l + 1) begin
        samples[l] = sample_word(16'((w * LANES) + l), 16'(((w * LANES) + l) * 2));
      end
      block_words[w] = pack_word(samples[0], samples[1], samples[2], samples[3]);
    end
  endtask

  task automatic fill_random_small;
    logic [31:0] lfsr;
    logic signed [15:0] i_val;
    logic signed [15:0] q_val;
    logic [31:0] samples [0:LANES-1];
    lfsr = 32'h19d0_5eed;
    for (int w = 0; w < BLOCK_WORDS; w = w + 1) begin
      for (int l = 0; l < LANES; l = l + 1) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        i_val = $signed({10'd0, lfsr[5:0]}) - 16'sd32;
        q_val = $signed({10'd0, lfsr[13:8]}) - 16'sd32;
        samples[l] = sample_word(i_val, q_val);
      end
      block_words[w] = pack_word(samples[0], samples[1], samples[2], samples[3]);
    end
  endtask

  task automatic fill_random_high_entropy;
    logic [31:0] lfsr;
    logic signed [15:0] i_val;
    logic signed [15:0] q_val;
    logic [31:0] samples [0:LANES-1];
    lfsr = 32'h19d1_9d0d;
    for (int w = 0; w < BLOCK_WORDS; w = w + 1) begin
      for (int l = 0; l < LANES; l = l + 1) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        i_val = $signed({6'd0, lfsr[9:0]}) - 16'sd512;
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        q_val = $signed({6'd0, lfsr[25:16]}) - 16'sd512;
        samples[l] = sample_word(i_val, q_val);
      end
      block_words[w] = pack_word(samples[0], samples[1], samples[2], samples[3]);
    end
  endtask

  task automatic apply_case(input string case_name);
    if (case_name == "zero_sparse") begin
      fill_sparse();
    end else if (case_name == "delta_ramp") begin
      fill_ramp();
    end else if (case_name == "random_small") begin
      fill_random_small();
    end else if (case_name == "random_high_entropy") begin
      fill_random_high_entropy();
    end else begin
      $fatal(1, "unknown smallbuf case %s", case_name);
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      link_ready_gate <= 1'b1;
      dec_m_tready <= 1'b1;
    end else if (enable_backpressure) begin
      link_ready_gate <= ($urandom_range(0, 3) != 0);
      dec_m_tready <= ($urandom_range(0, 3) != 0);
    end else begin
      link_ready_gate <= 1'b1;
      dec_m_tready <= 1'b1;
    end
  end

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      enc_s_tdata = '0;
      enc_s_tvalid = 1'b0;
      enc_s_tlast = 1'b0;
      enc_s_tuser = '0;
      enable_backpressure = 1'b0;
      driver_done = 1'b0;
      monitor_done = 1'b0;
      repeat (6) @(posedge clk);
      rst_n = 1'b1;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic drive_input;
    int word_idx;
    logic [AXIS_DATA_W-1:0] held_data;
    logic held_last;
    logic [7:0] held_user;
    begin
      word_idx = 0;
      held_data = '0;
      held_last = 1'b0;
      held_user = '0;
      enc_s_tvalid = 1'b0;
      enc_s_tdata = '0;
      enc_s_tlast = 1'b0;
      enc_s_tuser = '0;
      @(posedge clk);
      while (word_idx < BLOCK_WORDS) begin
        if (!enc_s_tvalid) begin
          enc_s_tvalid = 1'b1;
          enc_s_tdata = block_words[word_idx];
          enc_s_tlast = (word_idx == (BLOCK_WORDS - 1));
          enc_s_tuser = {4'd0, 1'b1, active_codec_mode[1:0], 1'b0};
          held_data = enc_s_tdata;
          held_last = enc_s_tlast;
          held_user = enc_s_tuser;
        end
        @(posedge clk);
        if (enc_s_tvalid && !enc_s_tready) begin
          if ((enc_s_tdata !== held_data) ||
              (enc_s_tlast !== held_last) ||
              (enc_s_tuser !== held_user)) begin
            $fatal(1, "AXI input source changed while stalled case=%s word=%0d", active_case_name, word_idx);
          end
        end
        if (enc_s_tvalid && enc_s_tready) begin
          word_idx = word_idx + 1;
          enc_s_tvalid = 1'b0;
          enc_s_tdata = '0;
          enc_s_tlast = 1'b0;
          enc_s_tuser = '0;
        end
      end
      driver_done = 1'b1;
    end
  endtask

  task automatic monitor_output;
    int word_idx;
    begin
      word_idx = 0;
      monitor_done = 1'b0;
      while (word_idx < BLOCK_WORDS) begin
        @(posedge clk);
        if (dec_m_tvalid && dec_m_tready) begin
          if (dec_m_tdata !== block_words[word_idx]) begin
            $fatal(1, "decode mismatch case=%s word=%0d exp=%032h got=%032h",
                   active_case_name, word_idx, block_words[word_idx], dec_m_tdata);
          end
          if (dec_m_tlast !== (word_idx == (BLOCK_WORDS - 1))) begin
            $fatal(1, "decode tlast mismatch case=%s word=%0d got=%0d",
                   active_case_name, word_idx, dec_m_tlast);
          end
          word_idx = word_idx + 1;
        end
      end
      monitor_done = 1'b1;
    end
  endtask

  task automatic run_case(
    input string case_name,
    input logic [7:0] codec_mode,
    input bit random_backpressure
  );
    begin
      reset_dut();
      active_case_name = case_name;
      active_codec_mode = codec_mode;
      enable_backpressure = random_backpressure;
      apply_case(case_name);
      fork
        drive_input();
        monitor_output();
      join
      wait (enc_num_blocks != 0);
      wait (dec_num_blocks != 0);
      #1;
      if (enc_error != MRTC_ERR_NONE) begin
        $fatal(1, "encoder error case=%s codec=%0d err=%0d", case_name, codec_mode, enc_error);
      end
      if (dec_error != MRTC_ERR_NONE) begin
        $fatal(1, "decoder error case=%s codec=%0d err=%0d", case_name, codec_mode, dec_error);
      end
      if (enc_raw_bypass_blocks != 0) begin
        $fatal(1, "smallbuf unexpectedly raw-bypassed case=%s", case_name);
      end
      if (enc_stall_input_cycles == 0) begin
        $fatal(1, "smallbuf did not assert input backpressure case=%s", case_name);
      end
      $display("PASS smallbuf case=%s codec=%0d bp=%0d selected_k=%0d prefix_bits=%0d comp_bytes=%0d input_stall=%0d output_stall=%0d",
               case_name, codec_mode, random_backpressure,
               u_encoder.selected_k_reg, u_encoder.prefix_bits_reg,
               enc_comp_bytes, enc_stall_input_cycles, enc_stall_output_cycles);
      repeat (10) @(posedge clk);
    end
  endtask

  initial begin
    string case_name;
    int full;
    int bp;
    active_case_name = "zero_sparse";
    active_codec_mode = MRTC_CODEC_ZERO_RICE;
    full = 0;
    bp = 0;
    void'($value$plusargs("CASE=%s", case_name));
    void'($value$plusargs("FULL=%d", full));
    void'($value$plusargs("BACKPRESSURE=%d", bp));
    if (case_name.len() == 0) begin
      case_name = "zero_sparse";
    end

    if (full != 0) begin
      run_case("zero_sparse", MRTC_CODEC_ZERO_RICE, 1'b0);
      run_case("zero_sparse", MRTC_CODEC_ZERO_RICE, 1'b1);
      run_case("delta_ramp", MRTC_CODEC_DELTA_RICE, 1'b0);
      run_case("delta_ramp", MRTC_CODEC_DELTA_RICE, 1'b1);
      run_case("random_small", MRTC_CODEC_ZERO_RICE, 1'b1);
      run_case("random_small", MRTC_CODEC_DELTA_RICE, 1'b1);
      run_case("random_high_entropy", MRTC_CODEC_ZERO_RICE, 1'b1);
    end else begin
      if (case_name == "delta_ramp") begin
        run_case(case_name, MRTC_CODEC_DELTA_RICE, bp != 0);
      end else if (case_name == "random_high_entropy") begin
        run_case(case_name, MRTC_CODEC_ZERO_RICE, bp != 0);
      end else begin
        run_case(case_name, MRTC_CODEC_ZERO_RICE, bp != 0);
      end
    end

    $display("PASS tb_mrtc_rdtc_encoder_axis_bp_smallbuf");
    $finish;
  end

  initial begin
    repeat (2000000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_rdtc_encoder_axis_bp_smallbuf");
  end
endmodule
