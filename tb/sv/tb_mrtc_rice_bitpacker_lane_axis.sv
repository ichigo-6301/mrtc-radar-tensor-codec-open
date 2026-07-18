`timescale 1ns/1ps

module tb_mrtc_rice_bitpacker_lane_axis;
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W        = 128;
  localparam int LANES              = MRTC_LANES;
  localparam int BLOCK_SAMPLES      = MRTC_BLOCK_SAMPLES;
  localparam int BLOCK_WORDS        = BLOCK_SAMPLES / LANES;
  localparam int WORD_ADDR_W        = $clog2(BLOCK_WORDS);
  localparam int SAMPLE_ADDR_W      = $clog2(BLOCK_SAMPLES);
  localparam int AXIS_BYTES         = AXIS_DATA_W / 8;
  localparam int MAX_PAYLOAD_BYTES  = MRTC_MAX_PAYLOAD_BYTES;
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);

  logic clk;
  logic rst_n;

  logic bank_clear;
  logic bank_wr_en;
  logic [WORD_ADDR_W-1:0] bank_wr_addr;
  logic [AXIS_DATA_W-1:0] bank_wr_data;

  logic [7:0] codec_mode;
  logic [7:0] selected_k;
  logic old_start;
  logic cand1_start;
  logic cand4_start;
  logic [(BLOCK_SAMPLES*32)-1:0] block_mem_flat;

  logic old_bank_rd_req;
  logic [WORD_ADDR_W-1:0] old_bank_rd_addr;
  logic old_bank_rd_valid;
  logic [AXIS_DATA_W-1:0] old_bank_rd_data;
  logic old_sample_rd_valid;
  logic [31:0] old_sample_rd_data;
  logic old_rd_req;
  logic [SAMPLE_ADDR_W-1:0] old_rd_addr;
  logic old_busy;
  logic old_done;
  logic [AXIS_DATA_W-1:0] old_tdata;
  logic old_tvalid;
  logic old_tready;
  logic old_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] old_tvalid_bytes_minus1;
  logic [31:0] old_payload_bits_counted;
  logic [31:0] old_payload_bytes_counted;
  logic old_count_mismatch;
  logic old_overflow;

  logic cand1_rd_req;
  logic [WORD_ADDR_W-1:0] cand1_rd_addr;
  logic cand1_rd_valid;
  logic [AXIS_DATA_W-1:0] cand1_rd_data;
  logic cand1_busy;
  logic cand1_done;
  logic [AXIS_DATA_W-1:0] cand1_tdata;
  logic cand1_tvalid;
  logic cand1_tready;
  logic cand1_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] cand1_tvalid_bytes_minus1;
  logic [31:0] cand1_payload_bits_counted;
  logic [31:0] cand1_payload_bytes_counted;
  logic cand1_overflow;
  logic cand1_long_unary_used;
  logic cand1_group_fallback_used;

  logic cand4_rd_req;
  logic [WORD_ADDR_W-1:0] cand4_rd_addr;
  logic cand4_rd_valid;
  logic [AXIS_DATA_W-1:0] cand4_rd_data;
  logic cand4_busy;
  logic cand4_done;
  logic [AXIS_DATA_W-1:0] cand4_tdata;
  logic cand4_tvalid;
  logic cand4_tready;
  logic cand4_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] cand4_tvalid_bytes_minus1;
  logic [31:0] cand4_payload_bits_counted;
  logic [31:0] cand4_payload_bytes_counted;
  logic cand4_overflow;
  logic cand4_long_unary_used;
  logic cand4_group_fallback_used;

  logic [(MAX_PAYLOAD_BYTES*8)-1:0] comb_payload_flat;
  logic [31:0] comb_payload_bits;
  logic [31:0] comb_payload_bytes;

  integer old_protocol_error_count;
  integer cand1_protocol_error_count;
  integer cand4_protocol_error_count;

  byte old_actual_bytes [0:MAX_PAYLOAD_BYTES-1];
  byte cand_actual_bytes [0:MAX_PAYLOAD_BYTES-1];
  integer old_actual_byte_count;
  integer cand_actual_byte_count;
  integer old_actual_beat_count;
  integer cand_actual_beat_count;
  integer old_actual_last_count;
  integer cand_actual_last_count;
  integer old_actual_final_valid_bytes;
  integer cand_actual_final_valid_bytes;

  integer cycle_count;
  integer old_req_count;
  integer cand1_req_count;
  integer cand4_req_count;
  integer old_addr_mismatch_count;
  integer cand1_addr_mismatch_count;
  integer cand4_addr_mismatch_count;
  logic [SAMPLE_ADDR_W-1:0] old_expected_addr_q;
  logic [WORD_ADDR_W-1:0] cand1_expected_addr_q;
  logic [WORD_ADDR_W-1:0] cand4_expected_addr_q;
  logic old_req_monitor_active;
  logic cand1_req_monitor_active;
  logic cand4_req_monitor_active;

  integer packer_lane_mode;
  integer run_full_matrix;
  string  result_csv_path;
  integer result_fd;

  logic run_active;
  logic backpressure_enable;
  integer start_cycle_q;
  logic old_done_seen;
  logic sel_done_seen;
  integer old_done_cycle_q;
  integer sel_done_cycle_q;
  integer ready_state;

  logic [AXIS_DATA_W-1:0]         sel_tdata;
  logic                           sel_tvalid;
  logic                           sel_tlast;
  logic [VALID_BYTE_COUNT_W-1:0]  sel_tvalid_bytes_minus1;

  function automatic logic [31:0] sample_word(
    input logic signed [15:0] i_s16,
    input logic signed [15:0] q_s16
  );
    sample_word = {q_s16[15:0], i_s16[15:0]};
  endfunction

  function automatic string codec_name(input logic [7:0] cfg_codec_mode);
    begin
      case (cfg_codec_mode)
        MRTC_CODEC_ZERO_RICE:  codec_name = "ZERO_RICE";
        MRTC_CODEC_DELTA_RICE: codec_name = "DELTA_RICE";
        MRTC_CODEC_RAW:        codec_name = "RAW";
        default:               codec_name = "UNKNOWN";
      endcase
    end
  endfunction

  function automatic integer valid_bytes_from_axis(
    input logic                        tlast,
    input logic [VALID_BYTE_COUNT_W-1:0] tuser
  );
    begin
      if (tlast) begin
        valid_bytes_from_axis = integer'(tuser) + 1;
      end else begin
        valid_bytes_from_axis = AXIS_BYTES;
      end
    end
  endfunction

  task automatic fill_all_zero;
    int unsigned idx;
    begin
      for (idx = 0; idx < BLOCK_SAMPLES; idx = idx + 1) begin
        block_mem_flat[(idx*32) +: 32] = 32'd0;
      end
    end
  endtask

  task automatic fill_ramp;
    int unsigned idx;
    logic signed [15:0] i_val;
    logic signed [15:0] q_val;
    begin
      for (idx = 0; idx < BLOCK_SAMPLES; idx = idx + 1) begin
        i_val = $signed(16'(idx));
        q_val = $signed(16'((idx * 5) & 16'h7FFF));
        block_mem_flat[(idx*32) +: 32] = sample_word(i_val, q_val);
      end
    end
  endtask

  task automatic fill_zero_sparse;
    begin
      fill_all_zero();
      block_mem_flat[(17*32) +: 32]  = sample_word(16'sd64, -16'sd32);
      block_mem_flat[(173*32) +: 32] = sample_word(16'sd1234, -16'sd2048);
      block_mem_flat[(701*32) +: 32] = sample_word(-16'sd819, 16'sd511);
    end
  endtask

  task automatic fill_single_peak;
    begin
      fill_all_zero();
      block_mem_flat[(173*32) +: 32] = sample_word(16'sd1234, -16'sd2048);
    end
  endtask

  task automatic fill_delta_sparse;
    int unsigned idx;
    begin
      fill_all_zero();
      for (idx = 128; idx < 160; idx = idx + 1) begin
        block_mem_flat[(idx*32) +: 32] = sample_word(16'sd2048, -16'sd1024);
      end
      for (idx = 512; idx < 544; idx = idx + 1) begin
        block_mem_flat[(idx*32) +: 32] = sample_word(-16'sd1536, 16'sd768);
      end
      for (idx = 900; idx < 912; idx = idx + 1) begin
        block_mem_flat[(idx*32) +: 32] = sample_word(16'sd256, 16'sd256);
      end
    end
  endtask

  task automatic fill_pseudo_random;
    int unsigned idx;
    logic [31:0] lfsr;
    logic signed [15:0] i_val;
    logic signed [15:0] q_val;
    begin
      lfsr = 32'h1ACE_B00C;
      for (idx = 0; idx < BLOCK_SAMPLES; idx = idx + 1) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        // Keep the random amplitude in a bounded range so the standalone
        // compressed payload remains inside a practical golden buffer.
        i_val = $signed({{6{lfsr[9]}},  lfsr[9:0]});
        q_val = $signed({{6{lfsr[19]}}, lfsr[19:10]});
        block_mem_flat[(idx*32) +: 32] = sample_word(i_val, q_val);
      end
    end
  endtask

  task automatic fill_long_unary_zero;
    begin
      fill_all_zero();
      // Keep quotient > TOKEN_W while staying well below MAX_PAYLOAD_BYTES.
      block_mem_flat[(0*32) +: 32] = sample_word(16'sd200, -16'sd200);
    end
  endtask

  task automatic fill_long_unary_delta;
    begin
      fill_all_zero();
      block_mem_flat[(0*32) +: 32] = sample_word(16'sd0, 16'sd0);
      block_mem_flat[(1*32) +: 32] = sample_word(16'sd200, -16'sd200);
    end
  endtask

  task automatic apply_pattern(input string pattern_name);
    begin
      if (pattern_name == "all_zero") begin
        fill_all_zero();
      end else if (pattern_name == "ramp") begin
        fill_ramp();
      end else if (pattern_name == "zero_sparse") begin
        fill_zero_sparse();
      end else if (pattern_name == "single_peak") begin
        fill_single_peak();
      end else if (pattern_name == "delta_sparse") begin
        fill_delta_sparse();
      end else if (pattern_name == "pseudo_random") begin
        fill_pseudo_random();
      end else if (pattern_name == "long_unary_zero") begin
        fill_long_unary_zero();
      end else if (pattern_name == "long_unary_delta") begin
        fill_long_unary_delta();
      end else begin
        $fatal(1, "Unknown pattern %s", pattern_name);
      end
    end
  endtask

  task automatic clear_actuals;
    int idx;
    begin
      for (idx = 0; idx < MAX_PAYLOAD_BYTES; idx = idx + 1) begin
        old_actual_bytes[idx] = 8'h00;
        cand_actual_bytes[idx] = 8'h00;
      end
      old_actual_byte_count = 0;
      cand_actual_byte_count = 0;
      old_actual_beat_count = 0;
      cand_actual_beat_count = 0;
      old_actual_last_count = 0;
      cand_actual_last_count = 0;
      old_actual_final_valid_bytes = 0;
      cand_actual_final_valid_bytes = 0;
    end
  endtask

  task automatic load_banks;
    int unsigned word_idx;
    begin
      bank_clear  <= 1'b1;
      bank_wr_en  <= 1'b0;
      bank_wr_addr <= '0;
      bank_wr_data <= '0;
      @(posedge clk);
      bank_clear <= 1'b0;
      for (word_idx = 0; word_idx < BLOCK_WORDS; word_idx = word_idx + 1) begin
        bank_wr_en   <= 1'b1;
        bank_wr_addr <= WORD_ADDR_W'(word_idx);
        bank_wr_data <= block_mem_flat[(word_idx*AXIS_DATA_W) +: AXIS_DATA_W];
        @(posedge clk);
      end
      bank_wr_en   <= 1'b0;
      bank_wr_addr <= '0;
      bank_wr_data <= '0;
      @(posedge clk);
    end
  endtask

  task automatic reset_run_flags;
    begin
      clear_actuals();
      run_active       = 1'b0;
      backpressure_enable = 1'b0;
      old_done_seen    = 1'b0;
      sel_done_seen    = 1'b0;
      start_cycle_q    = -1;
      old_done_cycle_q = -1;
      sel_done_cycle_q = -1;
    end
  endtask

  task automatic execute_run(
    input string case_name,
    input bit    enable_backpressure,
    output integer old_cycles,
    output integer new_cycles,
    output bit    long_unary_used,
    output bit    group_fallback_used
  );
    integer old_req_before;
    integer cand_req_before;
    integer old_addr_mismatch_before;
    integer cand_addr_mismatch_before;
    integer old_proto_before;
    integer cand_proto_before;
    integer expected_final_valid_bytes;
    integer byte_idx;
    begin
      reset_run_flags();
      old_req_before           = old_req_count;
      old_addr_mismatch_before = old_addr_mismatch_count;
      old_proto_before         = old_protocol_error_count;

      if (packer_lane_mode == 4) begin
        cand_req_before           = cand4_req_count;
        cand_addr_mismatch_before = cand4_addr_mismatch_count;
        cand_proto_before         = cand4_protocol_error_count;
      end else begin
        cand_req_before           = cand1_req_count;
        cand_addr_mismatch_before = cand1_addr_mismatch_count;
        cand_proto_before         = cand1_protocol_error_count;
      end

      @(posedge clk);
      run_active          = 1'b1;
      backpressure_enable = enable_backpressure;
      start_cycle_q       = cycle_count;
      old_start           <= 1'b1;
      cand1_start         <= (packer_lane_mode == 1);
      cand4_start         <= (packer_lane_mode == 4);
      @(posedge clk);
      old_start           <= 1'b0;
      cand1_start         <= 1'b0;
      cand4_start         <= 1'b0;

      while (!(old_done_seen && sel_done_seen)) begin
        @(posedge clk);
      end

      run_active          = 1'b0;
      backpressure_enable = 1'b0;
      @(posedge clk);

      old_cycles = old_done_cycle_q - start_cycle_q + 1;
      new_cycles = sel_done_cycle_q - start_cycle_q + 1;

      if (old_count_mismatch !== 1'b0) begin
        $fatal(1, "FAIL %s old_count_mismatch mode=%0d", case_name, packer_lane_mode);
      end
      if (old_overflow !== 1'b0) begin
        $fatal(1, "FAIL %s old_overflow mode=%0d", case_name, packer_lane_mode);
      end
      if ((packer_lane_mode == 4) ? (cand4_overflow !== 1'b0) : (cand1_overflow !== 1'b0)) begin
        $fatal(1, "FAIL %s candidate_overflow mode=%0d", case_name, packer_lane_mode);
      end

      if ((old_protocol_error_count - old_proto_before) != 0) begin
        $fatal(1, "FAIL %s old_protocol_errors=%0d mode=%0d",
               case_name, old_protocol_error_count - old_proto_before, packer_lane_mode);
      end
      if (((packer_lane_mode == 4) ? cand4_protocol_error_count : cand1_protocol_error_count) - cand_proto_before != 0) begin
        $fatal(1, "FAIL %s candidate_protocol_errors=%0d mode=%0d",
               case_name,
               ((packer_lane_mode == 4) ? cand4_protocol_error_count : cand1_protocol_error_count) - cand_proto_before,
               packer_lane_mode);
      end

      if ((old_req_count - old_req_before) != BLOCK_SAMPLES) begin
        $fatal(1, "FAIL %s old_req_count exp=%0d got=%0d mode=%0d",
               case_name, BLOCK_SAMPLES, old_req_count - old_req_before, packer_lane_mode);
      end
      if (((packer_lane_mode == 4) ? cand4_req_count : cand1_req_count) - cand_req_before != BLOCK_WORDS) begin
        $fatal(1, "FAIL %s candidate_req_count exp=%0d got=%0d mode=%0d",
               case_name, BLOCK_WORDS,
               ((packer_lane_mode == 4) ? cand4_req_count : cand1_req_count) - cand_req_before,
               packer_lane_mode);
      end

      if ((old_addr_mismatch_count - old_addr_mismatch_before) != 0) begin
        $fatal(1, "FAIL %s old_addr_sequence mismatches=%0d mode=%0d",
               case_name, old_addr_mismatch_count - old_addr_mismatch_before, packer_lane_mode);
      end
      if ((((packer_lane_mode == 4) ? cand4_addr_mismatch_count : cand1_addr_mismatch_count) - cand_addr_mismatch_before) != 0) begin
        $fatal(1, "FAIL %s candidate_addr_sequence mismatches=%0d mode=%0d",
               case_name,
               ((packer_lane_mode == 4) ? cand4_addr_mismatch_count : cand1_addr_mismatch_count) - cand_addr_mismatch_before,
               packer_lane_mode);
      end

      if (old_payload_bits_counted !== comb_payload_bits) begin
        $fatal(1, "FAIL %s old_payload_bits exp=%0d got=%0d mode=%0d",
               case_name, comb_payload_bits, old_payload_bits_counted, packer_lane_mode);
      end
      if (old_payload_bytes_counted !== comb_payload_bytes) begin
        $fatal(1, "FAIL %s old_payload_bytes exp=%0d got=%0d mode=%0d",
               case_name, comb_payload_bytes, old_payload_bytes_counted, packer_lane_mode);
      end

      if (packer_lane_mode == 4) begin
        if (cand4_payload_bits_counted !== comb_payload_bits) begin
          $fatal(1, "FAIL %s cand4_payload_bits exp=%0d got=%0d",
                 case_name, comb_payload_bits, cand4_payload_bits_counted);
        end
        if (cand4_payload_bytes_counted !== comb_payload_bytes) begin
          $fatal(1, "FAIL %s cand4_payload_bytes exp=%0d got=%0d",
                 case_name, comb_payload_bytes, cand4_payload_bytes_counted);
        end
        long_unary_used    = cand4_long_unary_used;
        group_fallback_used = cand4_group_fallback_used;
      end else begin
        if (cand1_payload_bits_counted !== comb_payload_bits) begin
          $fatal(1, "FAIL %s cand1_payload_bits exp=%0d got=%0d",
                 case_name, comb_payload_bits, cand1_payload_bits_counted);
        end
        if (cand1_payload_bytes_counted !== comb_payload_bytes) begin
          $fatal(1, "FAIL %s cand1_payload_bytes exp=%0d got=%0d",
                 case_name, comb_payload_bytes, cand1_payload_bytes_counted);
        end
        long_unary_used    = cand1_long_unary_used;
        group_fallback_used = cand1_group_fallback_used;
      end

      if (old_actual_byte_count != comb_payload_bytes) begin
        $fatal(1, "FAIL %s old_actual_bytes exp=%0d got=%0d mode=%0d",
               case_name, comb_payload_bytes, old_actual_byte_count, packer_lane_mode);
      end
      if (cand_actual_byte_count != comb_payload_bytes) begin
        $fatal(1, "FAIL %s candidate_actual_bytes exp=%0d got=%0d mode=%0d",
               case_name, comb_payload_bytes, cand_actual_byte_count, packer_lane_mode);
      end
      if (old_actual_last_count != 1) begin
        $fatal(1, "FAIL %s old_last_count=%0d mode=%0d",
               case_name, old_actual_last_count, packer_lane_mode);
      end
      if (cand_actual_last_count != 1) begin
        $fatal(1, "FAIL %s candidate_last_count=%0d mode=%0d",
               case_name, cand_actual_last_count, packer_lane_mode);
      end
      if (old_actual_beat_count != cand_actual_beat_count) begin
        $fatal(1, "FAIL %s beat_count old=%0d cand=%0d mode=%0d",
               case_name, old_actual_beat_count, cand_actual_beat_count, packer_lane_mode);
      end
      expected_final_valid_bytes =
        (comb_payload_bytes == 0) ? 0 :
        (comb_payload_bytes - ((old_actual_beat_count - 1) * AXIS_BYTES));
      if (old_actual_final_valid_bytes != expected_final_valid_bytes) begin
        $fatal(1, "FAIL %s old_final_valid exp=%0d got=%0d mode=%0d",
               case_name, expected_final_valid_bytes, old_actual_final_valid_bytes, packer_lane_mode);
      end
      if (cand_actual_final_valid_bytes != expected_final_valid_bytes) begin
        $fatal(1, "FAIL %s candidate_final_valid exp=%0d got=%0d mode=%0d",
               case_name, expected_final_valid_bytes, cand_actual_final_valid_bytes, packer_lane_mode);
      end

      for (byte_idx = 0; byte_idx < comb_payload_bytes; byte_idx = byte_idx + 1) begin
        if (old_actual_bytes[byte_idx] !== comb_payload_flat[(byte_idx*8) +: 8]) begin
          $fatal(1, "FAIL %s old_payload byte=%0d exp=%02x got=%02x mode=%0d",
                 case_name, byte_idx, comb_payload_flat[(byte_idx*8) +: 8], old_actual_bytes[byte_idx], packer_lane_mode);
        end
        if (cand_actual_bytes[byte_idx] !== comb_payload_flat[(byte_idx*8) +: 8]) begin
          $fatal(1, "FAIL %s candidate_payload byte=%0d exp=%02x got=%02x mode=%0d",
                 case_name, byte_idx, comb_payload_flat[(byte_idx*8) +: 8], cand_actual_bytes[byte_idx], packer_lane_mode);
        end
      end
    end
  endtask

  task automatic run_case(
    input string      case_name,
    input string      pattern_name,
    input logic [7:0] cfg_codec_mode,
    input logic [7:0] cfg_selected_k,
    input bit         expect_long_unary
  );
    integer old_cycles_nbp;
    integer new_cycles_nbp;
    integer old_cycles_bp;
    integer new_cycles_bp;
    bit     long_unary_used_nbp;
    bit     group_fallback_used_nbp;
    bit     long_unary_used_bp;
    bit     group_fallback_used_bp;
    bit     backpressure_pass;
    real    speedup_real;
    string  note_str;
    begin
      apply_pattern(pattern_name);
      load_banks();
      codec_mode = cfg_codec_mode;
      selected_k = cfg_selected_k;

      execute_run(
        case_name,
        1'b0,
        old_cycles_nbp,
        new_cycles_nbp,
        long_unary_used_nbp,
        group_fallback_used_nbp
      );

      execute_run(
        case_name,
        1'b1,
        old_cycles_bp,
        new_cycles_bp,
        long_unary_used_bp,
        group_fallback_used_bp
      );
      backpressure_pass = 1'b1;

      if (expect_long_unary && !long_unary_used_nbp) begin
        $fatal(1, "FAIL %s expected long-unary fallback mode=%0d", case_name, packer_lane_mode);
      end
      if (expect_long_unary && !long_unary_used_bp) begin
        $fatal(1, "FAIL %s expected long-unary fallback under backpressure mode=%0d", case_name, packer_lane_mode);
      end

      speedup_real = (new_cycles_nbp == 0) ? 0.0 : (1.0 * old_cycles_nbp) / (1.0 * new_cycles_nbp);
      $sformat(
        note_str,
        "lane_mode=%0d;group_fallback=%0d;bp_old_cycles=%0d;bp_new_cycles=%0d",
        packer_lane_mode,
        group_fallback_used_nbp,
        old_cycles_bp,
        new_cycles_bp
      );

      $fwrite(
        result_fd,
        "lane_mode%0d,%s,%s,%0d,%0d,%0d,%.6f,%0d,%0d,%0d,%0d,%0d,%s\n",
        packer_lane_mode,
        case_name,
        codec_name(cfg_codec_mode),
        cfg_selected_k,
        old_cycles_nbp,
        new_cycles_nbp,
        speedup_real,
        comb_payload_bytes,
        comb_payload_bits,
        1,
        backpressure_pass,
        long_unary_used_nbp,
        note_str
      );
    end
  endtask

  task automatic run_suite;
    begin
      if (run_full_matrix != 0) begin
        run_case("zero_all_zero_k0",       "all_zero",          MRTC_CODEC_ZERO_RICE,  8'd0,  1'b0);
        run_case("zero_all_zero_k1",       "all_zero",          MRTC_CODEC_ZERO_RICE,  8'd1,  1'b0);
        run_case("zero_all_zero_k2",       "all_zero",          MRTC_CODEC_ZERO_RICE,  8'd2,  1'b0);
        run_case("zero_all_zero_k4",       "all_zero",          MRTC_CODEC_ZERO_RICE,  8'd4,  1'b0);
        run_case("zero_all_zero_k8",       "all_zero",          MRTC_CODEC_ZERO_RICE,  8'd8,  1'b0);
        run_case("zero_all_zero_k14",      "all_zero",          MRTC_CODEC_ZERO_RICE,  8'd14, 1'b0);
        run_case("zero_zero_sparse_k4",    "zero_sparse",       MRTC_CODEC_ZERO_RICE,  8'd4,  1'b0);
        run_case("zero_single_peak_k4",    "single_peak",       MRTC_CODEC_ZERO_RICE,  8'd4,  1'b0);
        run_case("zero_random_k8",         "pseudo_random",     MRTC_CODEC_ZERO_RICE,  8'd8,  1'b0);
        run_case("zero_long_unary_k0",     "long_unary_zero",   MRTC_CODEC_ZERO_RICE,  8'd0,  1'b1);

        run_case("delta_all_zero_k0",      "all_zero",          MRTC_CODEC_DELTA_RICE, 8'd0,  1'b0);
        run_case("delta_all_zero_k1",      "all_zero",          MRTC_CODEC_DELTA_RICE, 8'd1,  1'b0);
        run_case("delta_all_zero_k2",      "all_zero",          MRTC_CODEC_DELTA_RICE, 8'd2,  1'b0);
        run_case("delta_all_zero_k4",      "all_zero",          MRTC_CODEC_DELTA_RICE, 8'd4,  1'b0);
        run_case("delta_all_zero_k8",      "all_zero",          MRTC_CODEC_DELTA_RICE, 8'd8,  1'b0);
        run_case("delta_all_zero_k14",     "all_zero",          MRTC_CODEC_DELTA_RICE, 8'd14, 1'b0);
        run_case("delta_ramp_k1",          "ramp",              MRTC_CODEC_DELTA_RICE, 8'd1,  1'b0);
        run_case("delta_ramp_k4",          "ramp",              MRTC_CODEC_DELTA_RICE, 8'd4,  1'b0);
        run_case("delta_ramp_k8",          "ramp",              MRTC_CODEC_DELTA_RICE, 8'd8,  1'b0);
        run_case("delta_sparse_k4",        "delta_sparse",      MRTC_CODEC_DELTA_RICE, 8'd4,  1'b0);
        run_case("delta_random_k8",        "pseudo_random",     MRTC_CODEC_DELTA_RICE, 8'd8,  1'b0);
        run_case("delta_long_unary_k0",    "long_unary_delta",  MRTC_CODEC_DELTA_RICE, 8'd0,  1'b1);
      end else begin
        run_case("smoke_zero_sparse_k4",   "zero_sparse",       MRTC_CODEC_ZERO_RICE,  8'd4,  1'b0);
        run_case("smoke_zero_long_k0",     "long_unary_zero",   MRTC_CODEC_ZERO_RICE,  8'd0,  1'b1);
        run_case("smoke_delta_ramp_k4",    "ramp",              MRTC_CODEC_DELTA_RICE, 8'd4,  1'b0);
        run_case("smoke_delta_random_k8",  "pseudo_random",     MRTC_CODEC_DELTA_RICE, 8'd8,  1'b0);
      end
    end
  endtask

  initial clk = 1'b0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_n) begin
    integer valid_bytes;
    integer byte_idx;
    integer base_idx;
    if (!rst_n) begin
      cycle_count   <= 0;
      ready_state   <= 32'h1234_5678;
      old_tready    <= 1'b0;
      cand1_tready  <= 1'b0;
      cand4_tready  <= 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;
      ready_state <= (ready_state * 32'd1664525) + 32'd1013904223;

      if (run_active && backpressure_enable) begin
        old_tready   <= ready_state[0] | ready_state[2] | ready_state[5];
        cand1_tready <= ready_state[0] | ready_state[2] | ready_state[5];
        cand4_tready <= ready_state[0] | ready_state[2] | ready_state[5];
      end else begin
        old_tready   <= 1'b1;
        cand1_tready <= 1'b1;
        cand4_tready <= 1'b1;
      end

      if (run_active && old_done && !old_done_seen) begin
        old_done_seen    <= 1'b1;
        old_done_cycle_q <= cycle_count;
      end
      if (run_active && ((packer_lane_mode == 4) ? cand4_done : cand1_done) && !sel_done_seen) begin
        sel_done_seen    <= 1'b1;
        sel_done_cycle_q <= cycle_count;
      end

      if (run_active && old_tvalid && old_tready) begin
        valid_bytes = valid_bytes_from_axis(old_tlast, old_tvalid_bytes_minus1);
        base_idx = old_actual_byte_count;
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          old_actual_bytes[base_idx + byte_idx] <= old_tdata[(byte_idx*8) +: 8];
        end
        old_actual_byte_count <= old_actual_byte_count + valid_bytes;
        old_actual_beat_count <= old_actual_beat_count + 1;
        if (old_tlast) begin
          old_actual_last_count <= old_actual_last_count + 1;
          old_actual_final_valid_bytes <= valid_bytes;
        end
      end

      if (run_active && sel_tvalid && ((packer_lane_mode == 4) ? cand4_tready : cand1_tready)) begin
        valid_bytes = valid_bytes_from_axis(sel_tlast, sel_tvalid_bytes_minus1);
        base_idx = cand_actual_byte_count;
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          cand_actual_bytes[base_idx + byte_idx] <= sel_tdata[(byte_idx*8) +: 8];
        end
        cand_actual_byte_count <= cand_actual_byte_count + valid_bytes;
        cand_actual_beat_count <= cand_actual_beat_count + 1;
        if (sel_tlast) begin
          cand_actual_last_count <= cand_actual_last_count + 1;
          cand_actual_final_valid_bytes <= valid_bytes;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      old_req_count            <= 0;
      cand1_req_count          <= 0;
      cand4_req_count          <= 0;
      old_addr_mismatch_count  <= 0;
      cand1_addr_mismatch_count <= 0;
      cand4_addr_mismatch_count <= 0;
      old_expected_addr_q      <= '0;
      cand1_expected_addr_q    <= '0;
      cand4_expected_addr_q    <= '0;
      old_req_monitor_active   <= 1'b0;
      cand1_req_monitor_active <= 1'b0;
      cand4_req_monitor_active <= 1'b0;
    end else begin
      if (old_start) begin
        old_expected_addr_q     <= '0;
        old_req_monitor_active  <= 1'b1;
      end
      if (cand1_start) begin
        cand1_expected_addr_q    <= '0;
        cand1_req_monitor_active <= 1'b1;
      end
      if (cand4_start) begin
        cand4_expected_addr_q    <= '0;
        cand4_req_monitor_active <= 1'b1;
      end

      if (old_rd_req) begin
        old_req_count <= old_req_count + 1;
        if (old_req_monitor_active) begin
          if (old_rd_addr !== old_expected_addr_q) begin
            old_addr_mismatch_count <= old_addr_mismatch_count + 1;
          end
          old_expected_addr_q <= old_expected_addr_q + SAMPLE_ADDR_W'(1);
        end
      end

      if (cand1_rd_req) begin
        cand1_req_count <= cand1_req_count + 1;
        if (cand1_req_monitor_active) begin
          if (cand1_rd_addr !== cand1_expected_addr_q) begin
            cand1_addr_mismatch_count <= cand1_addr_mismatch_count + 1;
          end
          cand1_expected_addr_q <= cand1_expected_addr_q + WORD_ADDR_W'(1);
        end
      end

      if (cand4_rd_req) begin
        cand4_req_count <= cand4_req_count + 1;
        if (cand4_req_monitor_active) begin
          if (cand4_rd_addr !== cand4_expected_addr_q) begin
            cand4_addr_mismatch_count <= cand4_addr_mismatch_count + 1;
          end
          cand4_expected_addr_q <= cand4_expected_addr_q + WORD_ADDR_W'(1);
        end
      end

      if (old_done) begin
        old_req_monitor_active <= 1'b0;
      end
      if (cand1_done) begin
        cand1_req_monitor_active <= 1'b0;
      end
      if (cand4_done) begin
        cand4_req_monitor_active <= 1'b0;
      end
    end
  end

  always_comb begin
    if (packer_lane_mode == 4) begin
      sel_tdata               = cand4_tdata;
      sel_tvalid              = cand4_tvalid;
      sel_tlast               = cand4_tlast;
      sel_tvalid_bytes_minus1 = cand4_tvalid_bytes_minus1;
    end else begin
      sel_tdata               = cand1_tdata;
      sel_tvalid              = cand1_tvalid;
      sel_tlast               = cand1_tlast;
      sel_tvalid_bytes_minus1 = cand1_tvalid_bytes_minus1;
    end
  end

  initial begin
    rst_n = 1'b0;
    bank_clear = 1'b0;
    bank_wr_en = 1'b0;
    bank_wr_addr = '0;
    bank_wr_data = '0;
    codec_mode = MRTC_CODEC_ZERO_RICE;
    selected_k = 8'd0;
    old_start = 1'b0;
    cand1_start = 1'b0;
    cand4_start = 1'b0;
    block_mem_flat = '0;
    packer_lane_mode = 1;
    run_full_matrix = 0;
    result_csv_path = "sim/stage16d1/raw/default.csv";
    void'($value$plusargs("PACKER_LANE_MODE=%d", packer_lane_mode));
    void'($value$plusargs("RUN_FULL_MATRIX=%d", run_full_matrix));
    void'($value$plusargs("RESULT_CSV=%s", result_csv_path));
    if (!((packer_lane_mode == 1) || (packer_lane_mode == LANES))) begin
      $fatal(1, "Unsupported PACKER_LANE_MODE=%0d", packer_lane_mode);
    end

    reset_run_flags();
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    result_fd = $fopen(result_csv_path, "w");
    if (result_fd == 0) begin
      $fatal(1, "Failed to open %s", result_csv_path);
    end
    $fwrite(
      result_fd,
      "packer_arch,scenario,codec,selected_k,old_cycles,new_cycles,speedup,payload_bytes,payload_bits,bitstream_match,backpressure_pass,long_unary_used,notes\n"
    );

    run_suite();
    $fclose(result_fd);
    $display("PASS tb_mrtc_rice_bitpacker_lane_axis PACKER_LANE_MODE=%0d RUN_FULL_MATRIX=%0d csv=%s",
             packer_lane_mode, run_full_matrix, result_csv_path);
    $finish;
  end

  initial begin
    repeat (4000000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_rice_bitpacker_lane_axis PACKER_LANE_MODE=%0d", packer_lane_mode);
  end

  mrtc_block_word_bank #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (LANES),
    .BLOCK_SAMPLES(BLOCK_SAMPLES),
    .READ_LATENCY (1)
  ) u_old_word_bank (
    .clk           (clk),
    .rst_n         (rst_n),
    .i_clear       (bank_clear),
    .i_wr_en       (bank_wr_en),
    .i_wr_word_addr(bank_wr_addr),
    .i_wr_word_data(bank_wr_data),
    .i_rd_req      (old_bank_rd_req),
    .i_rd_word_addr(old_bank_rd_addr),
    .o_rd_valid    (old_bank_rd_valid),
    .o_rd_word_data(old_bank_rd_data)
  );

  mrtc_block_word_bank #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (LANES),
    .BLOCK_SAMPLES(BLOCK_SAMPLES),
    .READ_LATENCY (1)
  ) u_cand1_word_bank (
    .clk           (clk),
    .rst_n         (rst_n),
    .i_clear       (bank_clear),
    .i_wr_en       (bank_wr_en),
    .i_wr_word_addr(bank_wr_addr),
    .i_wr_word_data(bank_wr_data),
    .i_rd_req      (cand1_rd_req),
    .i_rd_word_addr(cand1_rd_addr),
    .o_rd_valid    (cand1_rd_valid),
    .o_rd_word_data(cand1_rd_data)
  );

  mrtc_block_word_bank #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (LANES),
    .BLOCK_SAMPLES(BLOCK_SAMPLES),
    .READ_LATENCY (1)
  ) u_cand4_word_bank (
    .clk           (clk),
    .rst_n         (rst_n),
    .i_clear       (bank_clear),
    .i_wr_en       (bank_wr_en),
    .i_wr_word_addr(bank_wr_addr),
    .i_wr_word_data(bank_wr_data),
    .i_rd_req      (cand4_rd_req),
    .i_rd_word_addr(cand4_rd_addr),
    .o_rd_valid    (cand4_rd_valid),
    .o_rd_word_data(cand4_rd_data)
  );

  mrtc_block_sample_read_adapter #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (LANES),
    .BLOCK_SAMPLES(BLOCK_SAMPLES)
  ) u_old_sample_adapter (
    .clk               (clk),
    .rst_n             (rst_n),
    .i_sample_rd_req   (old_rd_req),
    .i_sample_rd_addr  (old_rd_addr),
    .o_bank_rd_req     (old_bank_rd_req),
    .o_bank_rd_word_addr(old_bank_rd_addr),
    .i_bank_rd_valid   (old_bank_rd_valid),
    .i_bank_rd_word_data(old_bank_rd_data),
    .o_sample_rd_valid (old_sample_rd_valid),
    .o_sample_rd_data  (old_sample_rd_data)
  );

  mrtc_rice_bitpacker #(
    .BLOCK_SAMPLES     (BLOCK_SAMPLES),
    .MAX_PAYLOAD_BYTES (MAX_PAYLOAD_BYTES)
  ) u_comb_golden (
    .i_enable        ((codec_mode == MRTC_CODEC_ZERO_RICE) || (codec_mode == MRTC_CODEC_DELTA_RICE)),
    .i_block_mem_flat(block_mem_flat),
    .i_codec_mode    (codec_mode),
    .i_selected_k    (selected_k),
    .o_payload_flat  (comb_payload_flat),
    .o_payload_bits  (comb_payload_bits),
    .o_payload_bytes (comb_payload_bytes)
  );

  mrtc_rice_bitpacker_axis #(
    .AXIS_DATA_W   (AXIS_DATA_W),
    .BLOCK_SAMPLES (BLOCK_SAMPLES),
    .ADDR_W        (SAMPLE_ADDR_W),
    .FRAG_W        (32)
  ) u_old_axis (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .i_start                 (old_start),
    .i_codec_mode            (codec_mode),
    .i_selected_k            (selected_k),
    .i_expected_length_valid (1'b1),
    .i_expected_payload_bits (comb_payload_bits),
    .i_expected_payload_bytes(comb_payload_bytes),
    .o_rd_req                (old_rd_req),
    .o_rd_addr               (old_rd_addr),
    .i_rd_valid              (old_sample_rd_valid),
    .i_rd_data               (old_sample_rd_data),
    .m_axis_tdata            (old_tdata),
    .m_axis_tvalid           (old_tvalid),
    .m_axis_tready           (old_tready),
    .m_axis_tlast            (old_tlast),
    .m_axis_tvalid_bytes_minus1(old_tvalid_bytes_minus1),
    .o_busy                  (old_busy),
    .o_done                  (old_done),
    .o_payload_bits_counted  (old_payload_bits_counted),
    .o_payload_bytes_counted (old_payload_bytes_counted),
    .o_count_mismatch        (old_count_mismatch),
    .o_overflow              (old_overflow)
  );

  mrtc_rice_bitpacker_lane_axis #(
    .AXIS_DATA_W      (AXIS_DATA_W),
    .LANES            (LANES),
    .BLOCK_SAMPLES    (BLOCK_SAMPLES),
    .ADDR_W           (WORD_ADDR_W),
    .PACKER_LANE_MODE (1),
    .TOKEN_W          (256),
    .WORD_FIFO_DEPTH  (4)
  ) u_cand_mode1 (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .i_start                 (cand1_start),
    .i_codec_mode            (codec_mode),
    .i_selected_k            (selected_k),
    .o_word_rd_req           (cand1_rd_req),
    .o_word_rd_addr_base     (cand1_rd_addr),
    .i_word_rd_valid         (cand1_rd_valid),
    .i_word_rd_data          (cand1_rd_data),
    .m_axis_tdata            (cand1_tdata),
    .m_axis_tvalid           (cand1_tvalid),
    .m_axis_tready           (cand1_tready),
    .m_axis_tlast            (cand1_tlast),
    .m_axis_tvalid_bytes_minus1(cand1_tvalid_bytes_minus1),
    .o_busy                  (cand1_busy),
    .o_done                  (cand1_done),
    .o_payload_bits_counted  (cand1_payload_bits_counted),
    .o_payload_bytes_counted (cand1_payload_bytes_counted),
    .o_overflow              (cand1_overflow),
    .o_long_unary_used       (cand1_long_unary_used),
    .o_group_fallback_used   (cand1_group_fallback_used)
  );

  mrtc_rice_bitpacker_lane_axis #(
    .AXIS_DATA_W      (AXIS_DATA_W),
    .LANES            (LANES),
    .BLOCK_SAMPLES    (BLOCK_SAMPLES),
    .ADDR_W           (WORD_ADDR_W),
    .PACKER_LANE_MODE (LANES),
    .TOKEN_W          (256),
    .WORD_FIFO_DEPTH  (4)
  ) u_cand_mode4 (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .i_start                 (cand4_start),
    .i_codec_mode            (codec_mode),
    .i_selected_k            (selected_k),
    .o_word_rd_req           (cand4_rd_req),
    .o_word_rd_addr_base     (cand4_rd_addr),
    .i_word_rd_valid         (cand4_rd_valid),
    .i_word_rd_data          (cand4_rd_data),
    .m_axis_tdata            (cand4_tdata),
    .m_axis_tvalid           (cand4_tvalid),
    .m_axis_tready           (cand4_tready),
    .m_axis_tlast            (cand4_tlast),
    .m_axis_tvalid_bytes_minus1(cand4_tvalid_bytes_minus1),
    .o_busy                  (cand4_busy),
    .o_done                  (cand4_done),
    .o_payload_bits_counted  (cand4_payload_bits_counted),
    .o_payload_bytes_counted (cand4_payload_bytes_counted),
    .o_overflow              (cand4_overflow),
    .o_long_unary_used       (cand4_long_unary_used),
    .o_group_fallback_used   (cand4_group_fallback_used)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W    (VALID_BYTE_COUNT_W),
    .NAME       ("lane_old_axis")
  ) u_old_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(old_tdata),
    .tvalid(old_tvalid),
    .tready(old_tready),
    .tlast(old_tlast),
    .tuser(old_tvalid_bytes_minus1),
    .protocol_error_count(old_protocol_error_count)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W    (VALID_BYTE_COUNT_W),
    .NAME       ("lane_cand1")
  ) u_cand1_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(cand1_tdata),
    .tvalid(cand1_tvalid),
    .tready(cand1_tready),
    .tlast(cand1_tlast),
    .tuser(cand1_tvalid_bytes_minus1),
    .protocol_error_count(cand1_protocol_error_count)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W    (VALID_BYTE_COUNT_W),
    .NAME       ("lane_cand4")
  ) u_cand4_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(cand4_tdata),
    .tvalid(cand4_tvalid),
    .tready(cand4_tready),
    .tlast(cand4_tlast),
    .tuser(cand4_tvalid_bytes_minus1),
    .protocol_error_count(cand4_protocol_error_count)
  );
endmodule
