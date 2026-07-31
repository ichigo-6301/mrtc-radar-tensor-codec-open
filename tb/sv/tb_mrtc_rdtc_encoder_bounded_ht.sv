`timescale 1ns/1ps

module tb_mrtc_rdtc_encoder_bounded_ht #(
  parameter int WAY_COUNT = 4,
  parameter int PAYLOAD_DEPTH = 512
);
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;
  localparam int PREFIX_WORDS = 128 / MRTC_LANES;

  logic clk;
  logic rst_n;
  logic scoped_reset;
  logic clear_status;
  logic dut_rst_n;

  logic [AXIS_DATA_W-1:0] s_tdata;
  logic                   s_tvalid;
  logic                   s_tready;
  logic                   s_tlast;
  logic [7:0]             s_tuser;

  logic [AXIS_DATA_W-1:0] enc_tdata;
  logic                   enc_tvalid;
  logic                   enc_tready;
  logic                   enc_tlast;
  logic [7:0]             enc_tuser;
  logic                   packet_input_enable;
  logic                   packet_commit;
  logic                   packet_abort;

  logic                   packet_valid;
  logic                   packet_s_ready;
  logic [AXIS_DATA_W-1:0] packet_tdata;
  logic                   packet_tvalid;
  logic                   packet_tready;
  logic                   packet_tlast;
  logic [7:0]             packet_tuser;
  logic                   decoder_comp_ready;
  logic                   packet_overflow;
  logic [31:0]            packets_written;

  logic [AXIS_DATA_W-1:0] dec_tdata;
  logic                   dec_tvalid;
  logic                   dec_tready;
  logic                   dec_tlast;
  logic [7:0]             dec_tuser;

  logic [7:0]             cfg_codec_mode;
  logic [7:0]             cfg_rice_mode;
  logic [3:0]             cfg_fixed_k;

  logic                   stat_busy;
  logic                   stat_done;
  logic [31:0]            stat_num_blocks;
  logic [31:0]            stat_error;
  logic [31:0]            stat_input_stalls;
  logic [31:0]            stat_output_stalls;
  logic [31:0]            dec_num_blocks;
  logic [31:0]            dec_error;

  integer cycle_count;
  integer observed_k;
  integer observed_k_cycle;
  integer observed_read_requests;
  integer observed_first_read_cycle;
  integer observed_last_read_cycle;
  integer observed_last_token_cycle;
  integer observed_commit_cycle;
  integer observed_max_word_cost;
  integer expected_decode_variant;
  integer decode_word_index;
  integer decoded_blocks_seen;
  integer partial_encoder_beats;
  integer way_first_write [0:3];
  integer way_last_write [0:3];
  integer way_first_read [0:3];
  integer way_last_read [0:3];
  logic [31:0] previous_stat_num_blocks;

  assign dut_rst_n = rst_n && !scoped_reset;
  assign enc_tready = packet_input_enable && !scoped_reset &&
                      packet_s_ready;
  assign packet_tready = decoder_comp_ready;
  assign dec_tready = 1'b1;

  initial clk = 1'b0;
  always #2.5 clk = ~clk;

  function automatic integer signed_to_mapped(input integer value);
    if (value < 0) begin
      signed_to_mapped = ((-value) * 2) - 1;
    end else begin
      signed_to_mapped = value * 2;
    end
  endfunction

  function automatic logic [AXIS_DATA_W-1:0] test_word(
    input integer variant,
    input integer word_index
  );
    logic [AXIS_DATA_W-1:0] value;
    integer sample_index;
    integer i_value;
    integer q_value;
    begin
      value = '0;
      for (int lane = 0; lane < MRTC_LANES; lane = lane + 1) begin
        sample_index = (word_index * MRTC_LANES) + lane;
        case (variant)
          0: begin
            i_value = 0;
            q_value = 0;
          end
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

  function automatic integer word_bit_cost(
    input integer variant,
    input integer word_index,
    input integer k_value
  );
    integer total;
    integer i_value;
    integer q_value;
    logic [AXIS_DATA_W-1:0] value;
    begin
      value = test_word(variant, word_index);
      total = 0;
      for (int lane = 0; lane < MRTC_LANES; lane = lane + 1) begin
        i_value = $signed(value[(lane * 32) +: 16]);
        q_value = $signed(value[(lane * 32) + 16 +: 16]);
        total = total + (signed_to_mapped(i_value) >> k_value) + 1 + k_value;
        total = total + (signed_to_mapped(q_value) >> k_value) + 1 + k_value;
      end
      word_bit_cost = total;
    end
  endfunction

  function automatic integer prefix_selected_k_ref(input integer variant);
    integer best_k;
    integer best_cost;
    integer candidate_cost;
    begin
      best_k = 0;
      best_cost = 32'h7fff_ffff;
      for (int k_value = 0; k_value < 16; k_value = k_value + 1) begin
        candidate_cost = 0;
        for (int word_index = 0; word_index < PREFIX_WORDS;
             word_index = word_index + 1) begin
          candidate_cost = candidate_cost +
                           word_bit_cost(variant, word_index, k_value);
        end
        if (candidate_cost < best_cost) begin
          best_cost = candidate_cost;
          best_k = k_value;
        end
      end
      prefix_selected_k_ref = best_k;
    end
  endfunction

  task automatic clear_drivers;
    begin
      s_tdata = '0;
      s_tvalid = 1'b0;
      s_tlast = 1'b0;
      s_tuser = '0;
    end
  endtask

  task automatic apply_global_reset;
    begin
      rst_n = 1'b0;
      scoped_reset = 1'b0;
      clear_status = 1'b0;
      packet_input_enable = 1'b1;
      cfg_codec_mode = MRTC_CODEC_ZERO_RICE;
      cfg_rice_mode = MRTC_RICE_BLOCK_ADAPTIVE_K;
      cfg_fixed_k = 4'd0;
      expected_decode_variant = -1;
      clear_drivers();
      repeat (6) @(posedge clk);
      rst_n = 1'b1;
      repeat (3) @(posedge clk);
    end
  endtask

  task automatic apply_scoped_reset;
    begin
      clear_drivers();
      packet_input_enable = 1'b1;
      @(negedge clk);
      scoped_reset = 1'b1;
      repeat (3) @(posedge clk);
      @(negedge clk);
      scoped_reset = 1'b0;
      repeat (3) @(posedge clk);
      if ((stat_error != MRTC_ERR_NONE) || stat_busy || packet_valid) begin
        $fatal(1,
               "scoped reset failed error=%0d busy=%0d packet_valid=%0d",
               stat_error, stat_busy, packet_valid);
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

  task automatic send_complete_block(input integer variant);
    begin
      for (int word_index = 0; word_index < BLOCK_WORDS;
           word_index = word_index + 1) begin
        @(negedge clk);
        s_tdata = test_word(variant, word_index);
        s_tvalid = 1'b1;
        s_tlast = (word_index == (BLOCK_WORDS - 1));
        s_tuser = '0;
        s_tuser[0] = 1'b1;
        #1;
        if (!s_tready) begin
          $fatal(1,
                 "block-internal input stall way_count=%0d word=%0d error=%0d",
                 WAY_COUNT, word_index, stat_error);
        end
        @(posedge clk);
      end
      @(negedge clk);
      clear_drivers();
    end
  endtask

  task automatic drive_until_halt(
    input integer variant,
    input integer max_words
  );
    begin : drive_loop
      for (int word_index = 0; word_index < max_words;
           word_index = word_index + 1) begin
        @(negedge clk);
        s_tdata = test_word(variant, word_index);
        s_tvalid = 1'b1;
        s_tlast = 1'b0;
        s_tuser = '0;
        #1;
        if (!s_tready) begin
          disable drive_loop;
        end
        @(posedge clk);
      end
    end
    @(negedge clk);
    clear_drivers();
  endtask

  task automatic expect_error(
    input logic [31:0] expected_error,
    input string label,
    input integer decoded_before,
    input bit require_partial_packet
  );
    begin
      for (int wait_cycle = 0;
           (wait_cycle < 200) && (stat_error == MRTC_ERR_NONE);
           wait_cycle = wait_cycle + 1) begin
        @(posedge clk);
      end
      #1;
      if (stat_error != expected_error) begin
        $fatal(1, "%s expected error=%0d got=%0d", label,
               expected_error, stat_error);
      end
      repeat (8) @(posedge clk);
      if (s_tready || enc_tvalid || packet_valid ||
          (packets_written != 0) || (decoded_blocks_seen != decoded_before) ||
          (stat_num_blocks != 0)) begin
        $fatal(1,
               "%s fail-stop violation ready=%0d enc_valid=%0d packet=%0d written=%0d decoded=%0d/%0d stats=%0d",
               label, s_tready, enc_tvalid, packet_valid, packets_written,
               decoded_blocks_seen, decoded_before, stat_num_blocks);
      end
      if (require_partial_packet && (partial_encoder_beats == 0)) begin
        $fatal(1, "%s did not exercise a partial unpublished packet", label);
      end
      pulse_clear_status();
      if ((stat_error != expected_error) || s_tready) begin
        $fatal(1, "%s i_clear_status incorrectly recovered the engine", label);
      end
      $display("PASS bounded negative label=%s error=%0d partial_beats=%0d",
               label, stat_error, partial_encoder_beats);
    end
  endtask

  task automatic run_legal_case(input integer variant, input string label);
    integer decoded_before;
    integer expected_k;
    integer max_cost;
    begin
      decoded_before = decoded_blocks_seen;
      expected_k = prefix_selected_k_ref(variant);
      expected_decode_variant = variant;
      partial_encoder_beats = 0;
      send_complete_block(variant);
      for (int wait_cycle = 0;
           (wait_cycle < 10000) &&
           ((decoded_blocks_seen == decoded_before) || stat_busy);
           wait_cycle = wait_cycle + 1) begin
        @(posedge clk);
      end
      repeat (3) @(posedge clk);
      if ((stat_error != MRTC_ERR_NONE) || (dec_error != MRTC_ERR_NONE) ||
          (decoded_blocks_seen != (decoded_before + 1)) ||
          (stat_num_blocks != 1) || packet_overflow) begin
        $fatal(1,
               "%s legal case failed enc_error=%0d dec_error=%0d decoded=%0d/%0d blocks=%0d overflow=%0d",
               label, stat_error, dec_error, decoded_blocks_seen,
               decoded_before + 1, stat_num_blocks, packet_overflow);
      end
      if (observed_k != expected_k) begin
        $fatal(1, "%s selected-k mismatch expected=%0d got=%0d",
               label, expected_k, observed_k);
      end
      if ((observed_k_cycle < 38) || (observed_k_cycle > 44)) begin
        $fatal(1, "%s k latency outside bounded target cycle=%0d",
               label, observed_k_cycle);
      end
      if ((observed_read_requests != BLOCK_WORDS) ||
          ((observed_last_read_cycle - observed_first_read_cycle) !=
           (BLOCK_WORDS - 1))) begin
        $fatal(1,
               "%s read issue mismatch count=%0d first=%0d last=%0d",
               label, observed_read_requests, observed_first_read_cycle,
               observed_last_read_cycle);
      end
      if ((observed_last_token_cycle < observed_last_read_cycle) ||
          (observed_commit_cycle <= observed_last_token_cycle)) begin
        $fatal(1,
               "%s completion ordering mismatch last_read=%0d last_token=%0d commit=%0d",
               label, observed_last_read_cycle, observed_last_token_cycle,
               observed_commit_cycle);
      end
      max_cost = 0;
      for (int word_index = 0; word_index < BLOCK_WORDS;
           word_index = word_index + 1) begin
        if (word_bit_cost(variant, word_index, expected_k) > max_cost) begin
          max_cost = word_bit_cost(variant, word_index, expected_k);
        end
      end
      if ((max_cost > 128) || (observed_max_word_cost != max_cost)) begin
        $fatal(1, "%s max word cost mismatch expected=%0d observed=%0d",
               label, max_cost, observed_max_word_cost);
      end
      if ((WAY_COUNT == 3) && (observed_first_read_cycle > 64)) begin
        $fatal(1, "%s 3-way first-read latency=%0d exceeds 64", label,
               observed_first_read_cycle);
      end
      if ((WAY_COUNT == 4) && (observed_first_read_cycle > 96)) begin
        $fatal(1, "%s 4-way first-read latency=%0d exceeds 96", label,
               observed_first_read_cycle);
      end
      $display(
        "PASS bounded legal label=%s ways=%0d k=%0d k_cycle=%0d first_read=%0d last_read=%0d last_token=%0d commit=%0d max_word_bits=%0d",
        label, WAY_COUNT, observed_k, observed_k_cycle,
        observed_first_read_cycle, observed_last_read_cycle,
        observed_last_token_cycle, observed_commit_cycle,
        observed_max_word_cost);
      for (int way = 0; way < WAY_COUNT; way = way + 1) begin
        $display(
          "WAY_INTERVAL ways=%0d way=%0d write=%0d:%0d read=%0d:%0d",
          WAY_COUNT, way, way_first_write[way], way_last_write[way],
          way_first_read[way], way_last_read[way]);
      end
      expected_decode_variant = -1;
    end
  endtask

  task automatic run_latched_config_case;
    integer decoded_before;
    integer expected_k;
    begin
      decoded_before = decoded_blocks_seen;
      expected_k = prefix_selected_k_ref(0);
      expected_decode_variant = 0;
      cfg_codec_mode = MRTC_CODEC_ZERO_RICE;
      cfg_rice_mode = MRTC_RICE_BLOCK_ADAPTIVE_K;
      fork
        send_complete_block(0);
        begin
          wait (u_dut.ingress_word_count_reg == 1);
          @(negedge clk);
          cfg_codec_mode = MRTC_CODEC_DELTA_RICE;
          cfg_rice_mode = MRTC_RICE_FIXED_K;
          cfg_fixed_k = 4'd15;
        end
      join
      for (int wait_cycle = 0;
           (wait_cycle < 10000) &&
           ((decoded_blocks_seen == decoded_before) || stat_busy);
           wait_cycle = wait_cycle + 1) begin
        @(posedge clk);
      end
      repeat (3) @(posedge clk);
      if ((stat_error != MRTC_ERR_NONE) ||
          (decoded_blocks_seen != (decoded_before + 1)) ||
          (observed_k != expected_k)) begin
        $fatal(1,
               "latched config case failed error=%0d decoded=%0d/%0d k=%0d/%0d",
               stat_error, decoded_blocks_seen, decoded_before + 1,
               observed_k, expected_k);
      end
      cfg_codec_mode = MRTC_CODEC_ZERO_RICE;
      cfg_rice_mode = MRTC_RICE_BLOCK_ADAPTIVE_K;
      cfg_fixed_k = 4'd0;
      expected_decode_variant = -1;
      $display("PASS bounded first-beat config latch");
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count <= 0;
      observed_k <= -1;
      observed_k_cycle <= -1;
      observed_read_requests <= 0;
      observed_first_read_cycle <= -1;
      observed_last_read_cycle <= -1;
      observed_last_token_cycle <= -1;
      observed_commit_cycle <= -1;
      observed_max_word_cost <= 0;
      decode_word_index <= 0;
      decoded_blocks_seen <= 0;
      partial_encoder_beats <= 0;
      previous_stat_num_blocks <= 32'd0;
      for (int way = 0; way < 4; way = way + 1) begin
        way_first_write[way] <= -1;
        way_last_write[way] <= -1;
        way_first_read[way] <= -1;
        way_last_read[way] <= -1;
      end
    end else begin
      cycle_count <= cycle_count + 1;
      if (!dut_rst_n) begin
        previous_stat_num_blocks <= 32'd0;
      end else begin
        if ((stat_num_blocks != previous_stat_num_blocks) && !packet_commit) begin
          $fatal(1, "encoder statistics changed before guarded commit");
        end
        if (packet_commit && !u_dut.payload_tlast_seen_reg) begin
          $fatal(1, "packet committed without an accepted payload TLAST");
        end
        previous_stat_num_blocks <= stat_num_blocks;
      end
      if (!dut_rst_n) begin
        observed_k <= -1;
        observed_k_cycle <= -1;
        observed_read_requests <= 0;
        observed_first_read_cycle <= -1;
        observed_last_read_cycle <= -1;
        observed_last_token_cycle <= -1;
        observed_commit_cycle <= -1;
        observed_max_word_cost <= 0;
        partial_encoder_beats <= 0;
      end else begin
        if (u_dut.block_start) begin
          observed_k <= -1;
          observed_k_cycle <= -1;
          observed_read_requests <= 0;
          observed_first_read_cycle <= -1;
          observed_last_read_cycle <= -1;
          observed_last_token_cycle <= -1;
          observed_commit_cycle <= -1;
          observed_max_word_cost <= 0;
          partial_encoder_beats <= 0;
          for (int way = 0; way < 4; way = way + 1) begin
            way_first_write[way] <= -1;
            way_last_write[way] <= -1;
            way_first_read[way] <= -1;
            way_last_read[way] <= -1;
          end
        end
        if (u_dut.prefix_done) begin
          observed_k <= u_dut.prefix_selected_k;
          observed_k_cycle <= u_dut.cycle_count_reg;
        end
        if (u_dut.guard_valid && u_dut.selected_k_valid_reg &&
            u_dut.guard_le_128_by_k[u_dut.selected_k_reg[3:0]]) begin
          if (word_bit_cost(expected_decode_variant,
                            u_dut.guard_word_index,
                            u_dut.selected_k_reg[3:0]) > observed_max_word_cost) begin
            observed_max_word_cost <=
              word_bit_cost(expected_decode_variant,
                            u_dut.guard_word_index,
                            u_dut.selected_k_reg[3:0]);
          end
        end
        if (u_dut.bpack_word_rd_req) begin
          if (u_dut.bpack_word_rd_addr != observed_read_requests[7:0]) begin
            $fatal(1, "read address mismatch request=%0d addr=%0d",
                   observed_read_requests, u_dut.bpack_word_rd_addr);
          end
          if (observed_read_requests == 0) begin
            observed_first_read_cycle <= u_dut.cycle_count_reg;
          end else if (u_dut.cycle_count_reg != (observed_last_read_cycle + 1)) begin
            $fatal(1, "read issue gap request=%0d prev=%0d current=%0d",
                   observed_read_requests, observed_last_read_cycle,
                   u_dut.cycle_count_reg);
          end
          observed_last_read_cycle <= u_dut.cycle_count_reg;
          observed_read_requests <= observed_read_requests + 1;
        end
        if (u_dut.u_bpack.token_valid_reg && u_dut.u_bpack.token_ready &&
            u_dut.u_bpack.token_last_reg) begin
          observed_last_token_cycle <= u_dut.cycle_count_reg;
        end
        if (packet_commit) begin
          observed_commit_cycle <= u_dut.cycle_count_reg;
        end
        if (enc_tvalid && enc_tready) begin
          partial_encoder_beats <= partial_encoder_beats + 1;
        end
        if (u_dut.u_way_ring.wr_accept_comb) begin
          if (way_first_write[u_dut.u_way_ring.wr_way_comb] < 0) begin
            way_first_write[u_dut.u_way_ring.wr_way_comb] <=
              u_dut.cycle_count_reg;
          end
          way_last_write[u_dut.u_way_ring.wr_way_comb] <=
            u_dut.cycle_count_reg;
        end
        if (u_dut.u_way_ring.rd_accept_comb) begin
          if (way_first_read[u_dut.u_way_ring.rd_way_comb] < 0) begin
            way_first_read[u_dut.u_way_ring.rd_way_comb] <=
              u_dut.cycle_count_reg;
          end
          way_last_read[u_dut.u_way_ring.rd_way_comb] <=
            u_dut.cycle_count_reg;
        end
      end

      if (dec_tvalid && dec_tready) begin
        if (expected_decode_variant < 0) begin
          $fatal(1, "unexpected decoded output word=%0d", decode_word_index);
        end
        if (dec_tdata !== test_word(expected_decode_variant,
                                    decode_word_index)) begin
          $fatal(1,
                 "decoder mismatch ways=%0d word=%0d expected=%032h got=%032h",
                 WAY_COUNT, decode_word_index,
                 test_word(expected_decode_variant, decode_word_index),
                 dec_tdata);
        end
        if (dec_tlast != (decode_word_index == (BLOCK_WORDS - 1))) begin
          $fatal(1, "decoder tlast mismatch word=%0d tlast=%0d",
                 decode_word_index, dec_tlast);
        end
        if (dec_tlast) begin
          decode_word_index <= 0;
          decoded_blocks_seen <= decoded_blocks_seen + 1;
        end else begin
          decode_word_index <= decode_word_index + 1;
        end
      end
    end
  end

  initial begin
    integer decoded_before;

    apply_global_reset();
    run_legal_case(0, "zero_sparse");
    apply_scoped_reset();
    run_legal_case(1, "bounded_random");
    apply_scoped_reset();
    run_latched_config_case();

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    cfg_codec_mode = MRTC_CODEC_DELTA_RICE;
    drive_until_halt(0, 8);
    expect_error(MRTC_ERR_UNSUPPORTED_CODEC, "invalid_codec",
                 decoded_before, 1'b0);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    cfg_codec_mode = MRTC_CODEC_ZERO_RICE;
    cfg_rice_mode = MRTC_RICE_FIXED_K;
    drive_until_halt(0, 8);
    expect_error(MRTC_ERR_UNSUPPORTED_RICE, "invalid_rice_mode",
                 decoded_before, 1'b0);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    cfg_rice_mode = MRTC_RICE_BLOCK_ADAPTIVE_K;
    expected_decode_variant = 2;
    drive_until_halt(2, 160);
    expect_error(MRTC_ERR_BOUNDED_RICE_WORD, "word_129_bits",
                 decoded_before, 1'b1);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    fork
      drive_until_halt(0, BLOCK_WORDS);
      begin
        wait (u_dut.read_request_count_reg == 12);
        @(negedge clk);
        force u_dut.u_bpack.bounded_req_valid_reg = 1'b0;
        @(negedge clk);
        release u_dut.u_bpack.bounded_req_valid_reg;
      end
    join
    expect_error(MRTC_ERR_BITPACK_II1, "forced_issue_gap",
                 decoded_before, 1'b1);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    fork
      drive_until_halt(0, BLOCK_WORDS);
      begin
        wait (u_dut.read_response_count_reg == 20);
        @(negedge clk);
        force u_dut.ring_rd_valid = 1'b0;
        @(negedge clk);
        release u_dut.ring_rd_valid;
      end
    join
    expect_error(MRTC_ERR_BITPACK_II1, "missing_ring_response",
                 decoded_before, 1'b1);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    fork
      drive_until_halt(0, BLOCK_WORDS);
      begin
        wait (u_dut.u_bpack.token_valid_reg);
        @(negedge clk);
        force u_dut.u_bpack.token_ready = 1'b0;
        @(negedge clk);
        release u_dut.u_bpack.token_ready;
      end
    join
    expect_error(MRTC_ERR_BITPACK_II1, "forced_token_queue_backpressure",
                 decoded_before, 1'b1);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    fork
      send_complete_block(0);
      begin
        wait (enc_tvalid && enc_tready && enc_tlast);
        force u_dut.bpack_bounded_word_error = 1'b1;
        @(posedge clk);
        #1;
        release u_dut.bpack_bounded_word_error;
      end
    join
    expect_error(MRTC_ERR_BOUNDED_RICE_WORD, "final_beat_error_abort",
                 decoded_before, 1'b1);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    fork
      send_complete_block(0);
      begin
        wait (u_dut.bpack_done);
        force u_dut.payload_tlast_seen_reg = 1'b0;
        wait (u_dut.output_state_reg == u_dut.OUT_COMMIT_GUARD);
        @(posedge clk);
        #1;
        release u_dut.payload_tlast_seen_reg;
      end
    join
    expect_error(MRTC_ERR_BITPACK_II1, "commit_guard_missing_tlast",
                 decoded_before, 1'b1);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    fork
      drive_until_halt(0, BLOCK_WORDS);
      begin
        wait (u_dut.capture_word_count_reg == 20);
        @(negedge clk);
        force u_dut.ring_way_conflict = 1'b1;
        @(negedge clk);
        release u_dut.ring_way_conflict;
      end
    join
    expect_error(MRTC_ERR_SRAM_WAY_CONFLICT, "forced_way_conflict",
                 decoded_before, 1'b0);

    apply_scoped_reset();
    decoded_before = decoded_blocks_seen;
    expected_decode_variant = 0;
    packet_input_enable = 1'b0;
    drive_until_halt(0, 160);
    expect_error(MRTC_ERR_RING_OVERFLOW, "ring_overflow",
                 decoded_before, 1'b0);

    apply_scoped_reset();
    cfg_codec_mode = MRTC_CODEC_ZERO_RICE;
    cfg_rice_mode = MRTC_RICE_BLOCK_ADAPTIVE_K;
    run_legal_case(0, "post_error_reset_recovery");

    $display(
      "PASS tb_mrtc_rdtc_encoder_bounded_ht WAY_COUNT=%0d decoded_blocks=%0d",
      WAY_COUNT, decoded_blocks_seen);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_rdtc_encoder_bounded_ht WAY_COUNT=%0d",
           WAY_COUNT);
  end

  mrtc_rdtc_encoder_bounded_ht #(
    .AXIS_DATA_W      (AXIS_DATA_W),
    .WAY_COUNT        (WAY_COUNT),
    .WAY_DEPTH_WORDS  (32),
    .PREFIX_SAMPLES   (128)
  ) u_dut (
    .clk,
    .rst_n                    (dut_rst_n),
    .i_clear_status           (clear_status),
    .s_axis_raw_tdata         (s_tdata),
    .s_axis_raw_tvalid        (s_tvalid),
    .s_axis_raw_tready        (s_tready),
    .s_axis_raw_tlast         (s_tlast),
    .s_axis_raw_tuser         (s_tuser),
    .m_axis_comp_tdata        (enc_tdata),
    .m_axis_comp_tvalid       (enc_tvalid),
    .m_axis_comp_tready       (enc_tready),
    .m_axis_comp_tlast        (enc_tlast),
    .m_axis_comp_tuser        (enc_tuser),
    .o_packet_commit          (packet_commit),
    .o_packet_abort           (packet_abort),
    .cfg_codec_mode,
    .cfg_rice_mode,
    .cfg_fixed_k,
    .cfg_frame_id             (16'hb001),
    .cfg_block_id_base        (16'd7),
    .cfg_tensor_spatial_size  (16'd1),
    .cfg_tensor_doppler_size  (16'd64),
    .cfg_tensor_range_size    (16'd16),
    .stat_busy,
    .stat_done,
    .stat_raw_bytes           (),
    .stat_comp_bytes          (),
    .stat_num_blocks,
    .stat_error,
    .stat_raw_bypass_blocks   (),
    .stat_stall_input_cycles  (stat_input_stalls),
    .stat_stall_output_cycles (stat_output_stalls)
  );

  mrtc_axis_payload_commit_store #(
    .AXIS_DATA_W       (AXIS_DATA_W),
    .TUSER_W           (8),
    .HEADER_BEATS      (MRTC_HEADER_BYTES / (AXIS_DATA_W / 8)),
    .MAX_PAYLOAD_BEATS (MRTC_RAW_BYTES / (AXIS_DATA_W / 8)),
    .PAYLOAD_DEPTH     (PAYLOAD_DEPTH)
  ) u_packet_buffer (
    .clk,
    .rst_n                (dut_rst_n),
    .i_clear_status       (clear_status),
    .i_reserve            (u_dut.block_start),
    .o_reserve_ready      (),
    .i_commit             (packet_commit),
    .i_abort              (packet_abort),
    .s_axis_tdata         (enc_tdata),
    .s_axis_tvalid        (enc_tvalid && packet_input_enable),
    .s_axis_tready        (packet_s_ready),
    .s_axis_tlast         (enc_tlast),
    .s_axis_tuser         (enc_tuser),
    .o_packet_valid       (packet_valid),
    .i_packet_start       (packet_valid),
    .m_axis_tdata         (packet_tdata),
    .m_axis_tvalid        (packet_tvalid),
    .m_axis_tready        (packet_tready),
    .m_axis_tlast         (packet_tlast),
    .m_axis_tuser         (packet_tuser),
    .o_busy               (),
    .o_full               (),
    .o_overflow           (packet_overflow),
    .o_error              (),
    .o_packets_written    (packets_written),
    .o_packets_read       (),
    .o_write_stall_cycles (),
    .o_read_stall_cycles  (),
    .o_max_occupancy      ()
  );

  mrtc_rdtc_decoder_top #(
    .AXIS_DATA_W (AXIS_DATA_W)
  ) u_decoder (
    .clk,
    .rst_n,
    .i_clear_status              (1'b0),
    .s_axis_comp_tdata           (packet_tdata),
    .s_axis_comp_tvalid          (packet_tvalid),
    .s_axis_comp_tready          (decoder_comp_ready),
    .s_axis_comp_tlast           (packet_tlast),
    .s_axis_comp_tuser           (packet_tuser),
    .m_axis_raw_tdata            (dec_tdata),
    .m_axis_raw_tvalid           (dec_tvalid),
    .m_axis_raw_tready           (dec_tready),
    .m_axis_raw_tlast            (dec_tlast),
    .m_axis_raw_tuser            (dec_tuser),
    .stat_busy                   (),
    .stat_done                   (),
    .stat_comp_bytes             (),
    .stat_raw_bytes              (),
    .stat_num_blocks             (dec_num_blocks),
    .stat_error                  (dec_error),
    .stat_error_blocks           (),
    .stat_stall_input_cycles     (),
    .stat_stall_output_cycles    ()
  );
endmodule
