`timescale 1ns/1ps

// Historical Vivado/XSim testbench retained with its original three cases.
// The DUT's AXIS32 adapter ties the second core input inactive, so this test
// covers a single active input only and must not be cited as dual-engine FPGA
// verification, bitstream generation, or board execution evidence.
module tb_stage22f_r9c2p_pre_mrtc_axis32_wrapper;
  import mrtc_pkg::*;

  localparam int AXIS32_W = 32;
  localparam int AXIS32_BYTES = AXIS32_W / 8;
  localparam int CORE_AXIS_W = 128;
  localparam int CORE_AXIS_BYTES = CORE_AXIS_W / 8;
  localparam int BLOCK_BYTES = MRTC_COMP_BLOCK_BYTES;
  localparam int AXIS32_BEATS_PER_BLOCK = BLOCK_BYTES / AXIS32_BYTES;
  localparam int CORE_BEATS_PER_BLOCK = BLOCK_BYTES / CORE_AXIS_BYTES;
  localparam int MAX_BLOCKS = 4;

  logic clk;
  logic rst_n;
  logic clear_status;

  logic [31:0] s_tdata;
  logic [3:0] s_tkeep;
  logic s_tvalid;
  logic s_tready;
  logic s_tlast;
  logic [7:0] s_tuser;

  logic [31:0] m_tdata;
  logic [3:0] m_tkeep;
  logic m_tvalid;
  logic m_tready;
  logic m_tlast;
  logic [7:0] m_tuser;

  logic [127:0] repack_tdata;
  logic repack_tvalid;
  logic repack_tready;
  logic repack_tlast;
  logic [7:0] repack_tuser;
  logic [31:0] repack_error_count;
  logic repack_s_tready;
  logic output_ready_gate;

  logic [127:0] dec_tdata;
  logic dec_tvalid;
  logic dec_tready;
  logic dec_tlast;
  logic [7:0] dec_tuser;
  logic dec_busy;
  logic dec_done;
  logic [31:0] dec_comp_bytes;
  logic [31:0] dec_raw_bytes;
  logic [31:0] dec_num_blocks;
  logic [31:0] dec_error;
  logic [31:0] dec_error_blocks;
  logic [31:0] dec_stall_input_cycles;
  logic [31:0] dec_stall_output_cycles;

  logic [31:0] stat_input_beat_count;
  logic [31:0] stat_input_byte_count;
  logic [31:0] stat_input_stall_cycles;
  logic [31:0] stat_input_tkeep_error_count;
  logic [31:0] stat_input_tlast_error_count;
  logic [31:0] stat_packed_core_beat_count;
  logic [31:0] stat_output_beat_count;
  logic [31:0] stat_output_byte_count;
  logic [31:0] stat_output_packet_count;
  logic [31:0] stat_output_backpressure_cycles;
  logic [31:0] stat_output_last_tkeep;
  logic [31:0] stat_core_packet_count;
  logic [31:0] stat_core_error_flags;

  logic [127:0] expected_words [0:MAX_BLOCKS-1][0:CORE_BEATS_PER_BLOCK-1];
  logic [7:0] block_codec [0:MAX_BLOCKS-1];
  string active_case;
  int active_blocks;
  int active_output_bp;
  int active_input_gap;
  int cycle_count;
  int decoded_block_idx;
  int decoded_word_idx;
  int decode_mismatch_errors;
  int decode_tlast_errors;
  int out_tkeep_errors;
  int out_tlast_count;
  int out_packet_current_beats;
  int out_stability_errors;
  int out_backpressure_seen;
  int input_stall_seen;
  int total_cases;
  int failed_cases;
  logic [31:0] prev_m_tdata;
  logic [3:0] prev_m_tkeep;
  logic prev_m_tlast;
  logic [7:0] prev_m_tuser;
  logic prev_m_stalled;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  assign m_tready = repack_s_tready;
  assign dec_tready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count <= 0;
      output_ready_gate <= 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (active_output_bp) begin
        output_ready_gate <= ((cycle_count % 9) < 6);
      end else begin
        output_ready_gate <= 1'b1;
      end
    end
  end

  function automatic logic [31:0] sample_word(
    input logic signed [15:0] i_s16,
    input logic signed [15:0] q_s16
  );
    sample_word = {q_s16[15:0], i_s16[15:0]};
  endfunction

  function automatic logic signed [15:0] pattern_i(input int block_idx, input int word_idx, input int lane, input int pattern_id);
    logic [31:0] x;
    begin
      x = (32'h6D2B_79F5 ^ (32'(block_idx) * 32'h1021) ^
           (32'(word_idx) * 32'h45D9) ^ (32'(lane) * 32'h9E37));
      case (pattern_id)
        0: pattern_i = ((word_idx == (5 + block_idx)) && (lane == 0)) ? (16'sd16 + 16'(block_idx)) : 16'sd0;
        1: pattern_i = 16'((word_idx * 4) + lane + (block_idx * 7));
        2: pattern_i = $signed({10'd0, x[5:0]}) - 16'sd32;
        default: pattern_i = $signed({6'd0, x[9:0]}) - 16'sd512;
      endcase
    end
  endfunction

  function automatic logic signed [15:0] pattern_q(input int block_idx, input int word_idx, input int lane, input int pattern_id);
    logic [31:0] x;
    begin
      x = (32'hA341_316C ^ (32'(block_idx) * 32'h2111) ^
           (32'(word_idx) * 32'h1F5B) ^ (32'(lane) * 32'h7F4A));
      case (pattern_id)
        0: pattern_q = ((word_idx == (17 + block_idx)) && (lane == 2)) ? (-16'sd9 - 16'(block_idx)) : 16'sd0;
        1: pattern_q = 16'(((word_idx * 4) + lane) * 2 + block_idx);
        2: pattern_q = $signed({10'd0, x[13:8]}) - 16'sd32;
        default: pattern_q = $signed({6'd0, x[25:16]}) - 16'sd512;
      endcase
    end
  endfunction

  function automatic logic [31:0] raw_sample(input int block_idx, input int sample_idx, input int pattern_id);
    int word_idx;
    int lane;
    begin
      word_idx = sample_idx / 4;
      lane = sample_idx % 4;
      raw_sample = sample_word(
        pattern_i(block_idx, word_idx, lane, pattern_id),
        pattern_q(block_idx, word_idx, lane, pattern_id)
      );
    end
  endfunction

  task automatic prepare_expected(input int num_blocks, input bit first_delta);
    int blk;
    int word_idx;
    int pattern_id;
    begin
      for (blk = 0; blk < num_blocks; blk = blk + 1) begin
        pattern_id = blk % 4;
        block_codec[blk] = ((blk[0] ^ first_delta) == 1'b0) ?
                           MRTC_CODEC_ZERO_RICE : MRTC_CODEC_DELTA_RICE;
        for (word_idx = 0; word_idx < CORE_BEATS_PER_BLOCK; word_idx = word_idx + 1) begin
          expected_words[blk][word_idx] = {
            raw_sample(blk, (word_idx * 4) + 3, pattern_id),
            raw_sample(blk, (word_idx * 4) + 2, pattern_id),
            raw_sample(blk, (word_idx * 4) + 1, pattern_id),
            raw_sample(blk, (word_idx * 4) + 0, pattern_id)
          };
        end
      end
    end
  endtask

  task automatic reset_case_state;
    begin
      rst_n = 1'b0;
      clear_status = 1'b0;
      s_tdata = 32'd0;
      s_tkeep = 4'd0;
      s_tvalid = 1'b0;
      s_tlast = 1'b0;
      s_tuser = 8'd0;
      active_output_bp = 0;
      active_input_gap = 0;
      cycle_count = 0;
      decoded_block_idx = 0;
      decoded_word_idx = 0;
      decode_mismatch_errors = 0;
      decode_tlast_errors = 0;
      out_tkeep_errors = 0;
      out_tlast_count = 0;
      out_packet_current_beats = 0;
      out_stability_errors = 0;
      out_backpressure_seen = 0;
      input_stall_seen = 0;
      prev_m_tdata = 32'd0;
      prev_m_tkeep = 4'd0;
      prev_m_tlast = 1'b0;
      prev_m_tuser = 8'd0;
      prev_m_stalled = 1'b0;
      repeat (10) @(posedge clk);
      rst_n = 1'b1;
      repeat (4) @(posedge clk);
      @(negedge clk);
      clear_status = 1'b1;
      @(posedge clk);
      @(negedge clk);
      clear_status = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic send_axis32_word(
    input logic [31:0] data,
    input logic last,
    input logic [7:0] user
  );
    logic [31:0] hold_data;
    logic hold_last;
    logic [7:0] hold_user;
    int timeout;
    bit done;
    begin
      @(negedge clk);
      s_tdata = data;
      s_tkeep = 4'hF;
      s_tlast = last;
      s_tuser = user;
      s_tvalid = 1'b1;
      hold_data = data;
      hold_last = last;
      hold_user = user;
      timeout = 0;
      done = 1'b0;
      while (!done && timeout < 20000) begin
        @(posedge clk);
        if (s_tvalid && !s_tready) begin
          input_stall_seen = input_stall_seen + 1;
          if (s_tdata !== hold_data || s_tlast !== hold_last || s_tuser !== hold_user || s_tkeep !== 4'hF) begin
            $fatal(1, "R9C2P_PRE_FAIL case=%s reason=input_changed_while_stalled", active_case);
          end
        end
        if (s_tvalid && s_tready) begin
          done = 1'b1;
        end
        timeout = timeout + 1;
      end
      if (!done) begin
        $fatal(1, "R9C2P_PRE_FAIL case=%s reason=input_ready_timeout", active_case);
      end
      @(negedge clk);
      s_tvalid = 1'b0;
      s_tdata = 32'd0;
      s_tkeep = 4'd0;
      s_tlast = 1'b0;
      s_tuser = 8'd0;
      repeat (active_input_gap) @(posedge clk);
    end
  endtask

  task automatic drive_blocks(input int num_blocks);
    int blk;
    int sample_idx;
    logic [7:0] user;
    begin
      for (blk = 0; blk < num_blocks; blk = blk + 1) begin
        user = {4'd0, 1'b1, block_codec[blk][1:0], 1'b0};
        for (sample_idx = 0; sample_idx < AXIS32_BEATS_PER_BLOCK; sample_idx = sample_idx + 1) begin
          send_axis32_word(
            raw_sample(blk, sample_idx, blk % 4),
            (sample_idx == (AXIS32_BEATS_PER_BLOCK - 1)),
            user
          );
        end
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_m_stalled <= 1'b0;
    end else begin
      if (m_tvalid && !m_tready) begin
        out_backpressure_seen <= out_backpressure_seen + 1;
        if (prev_m_stalled &&
            ((m_tdata !== prev_m_tdata) || (m_tkeep !== prev_m_tkeep) ||
             (m_tlast !== prev_m_tlast) || (m_tuser !== prev_m_tuser))) begin
          out_stability_errors <= out_stability_errors + 1;
        end
        prev_m_stalled <= 1'b1;
      end else begin
        prev_m_stalled <= 1'b0;
      end

      if (m_tvalid && m_tready) begin
        if (m_tkeep == 4'd0) begin
          out_tkeep_errors <= out_tkeep_errors + 1;
        end
        if (!m_tlast && (m_tkeep != 4'hF)) begin
          out_tkeep_errors <= out_tkeep_errors + 1;
        end
        if (m_tlast) begin
          out_tlast_count <= out_tlast_count + 1;
          out_packet_current_beats <= 0;
        end else begin
          out_packet_current_beats <= out_packet_current_beats + 1;
        end
      end
      prev_m_tdata <= m_tdata;
      prev_m_tkeep <= m_tkeep;
      prev_m_tlast <= m_tlast;
      prev_m_tuser <= m_tuser;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      decoded_block_idx <= 0;
      decoded_word_idx <= 0;
      decode_mismatch_errors <= 0;
      decode_tlast_errors <= 0;
    end else if (dec_tvalid && dec_tready) begin
      if (decoded_block_idx >= active_blocks) begin
        decode_mismatch_errors <= decode_mismatch_errors + 1;
      end else begin
        if (dec_tdata !== expected_words[decoded_block_idx][decoded_word_idx]) begin
          decode_mismatch_errors <= decode_mismatch_errors + 1;
        end
        if (dec_tlast !== (decoded_word_idx == (CORE_BEATS_PER_BLOCK - 1))) begin
          decode_tlast_errors <= decode_tlast_errors + 1;
        end
      end
      if (decoded_word_idx == (CORE_BEATS_PER_BLOCK - 1)) begin
        decoded_word_idx <= 0;
        decoded_block_idx <= decoded_block_idx + 1;
      end else begin
        decoded_word_idx <= decoded_word_idx + 1;
      end
    end
  end

  task automatic wait_for_case_done(input int num_blocks);
    int timeout;
    begin
      timeout = 0;
      while ((decoded_block_idx < num_blocks) && timeout < 800000) begin
        @(posedge clk);
        timeout = timeout + 1;
      end
      if (timeout >= 800000) begin
        $fatal(1, "R9C2P_PRE_FAIL case=%s reason=decode_timeout decoded=%0d expected=%0d dec_err=%0d core_err=0x%08x",
               active_case, decoded_block_idx, num_blocks, dec_error, stat_core_error_flags);
      end
      repeat (20) @(posedge clk);
    end
  endtask

  task automatic check_case(input int num_blocks, input bit expect_backpressure);
    bit pass;
    string reason;
    begin
      pass = 1'b1;
      reason = "NONE";
      if (decode_mismatch_errors != 0 || dec_error != MRTC_ERR_NONE) begin
        pass = 1'b0;
        reason = "GOLDEN_COMPARE_FAIL";
      end else if (decode_tlast_errors != 0 || out_tlast_count != num_blocks) begin
        pass = 1'b0;
        reason = "PACKET_BOUNDARY_FAIL";
      end else if (out_tkeep_errors != 0 || repack_error_count != 0) begin
        pass = 1'b0;
        reason = "TKEEP_FAIL";
      end else if (stat_input_beat_count != 32'(num_blocks * AXIS32_BEATS_PER_BLOCK) ||
                   stat_packed_core_beat_count != 32'(num_blocks * CORE_BEATS_PER_BLOCK)) begin
        pass = 1'b0;
        reason = "WIDTH_PACK_COUNT_FAIL";
      end else if (stat_input_tkeep_error_count != 0 || stat_input_tlast_error_count != 0) begin
        pass = 1'b0;
        reason = "INPUT_BOUNDARY_FAIL";
      end else if (stat_output_packet_count != 32'(num_blocks) ||
                   stat_core_packet_count != 32'(num_blocks)) begin
        pass = 1'b0;
        reason = "OUTPUT_PACKET_COUNT_FAIL";
      end else if (stat_core_error_flags != 32'd0 || out_stability_errors != 0) begin
        pass = 1'b0;
        reason = "AXIS_PROTOCOL_FAIL";
      end else if (expect_backpressure && (out_backpressure_seen == 0 || stat_output_backpressure_cycles == 0)) begin
        pass = 1'b0;
        reason = "BACKPRESSURE_NOT_EXERCISED";
      end

      if (pass) begin
        $display(
          "R9C2P_PRE_CASE_PASS name=%s blocks=%0d input32_beats=%0d packed128_beats=%0d output32_beats=%0d output_packets=%0d output_bytes=%0d out_bp=%0d input_stalls=%0d last_tkeep=0x%0x dec_blocks=%0d",
          active_case,
          num_blocks,
          stat_input_beat_count,
          stat_packed_core_beat_count,
          stat_output_beat_count,
          stat_output_packet_count,
          stat_output_byte_count,
          stat_output_backpressure_cycles,
          input_stall_seen,
          stat_output_last_tkeep[3:0],
          dec_num_blocks
        );
      end else begin
        failed_cases = failed_cases + 1;
        $display(
          "R9C2P_PRE_CASE_FAIL name=%s reason=%s blocks=%0d mismatch=%0d dec_tlast=%0d out_tlast=%0d tkeep_err=%0d repack_err=%0d core_err=0x%08x",
          active_case,
          reason,
          num_blocks,
          decode_mismatch_errors,
          decode_tlast_errors,
          out_tlast_count,
          out_tkeep_errors,
          repack_error_count,
          stat_core_error_flags
        );
      end
    end
  endtask

  task automatic run_case(
    input string case_name,
    input int num_blocks,
    input bit output_bp,
    input int input_gap,
    input bit first_delta
  );
    begin
      active_case = case_name;
      active_blocks = num_blocks;
      total_cases = total_cases + 1;
      reset_case_state();
      active_output_bp = output_bp;
      active_input_gap = input_gap;
      prepare_expected(num_blocks, first_delta);
      fork
        drive_blocks(num_blocks);
        wait_for_case_done(num_blocks);
      join
      check_case(num_blocks, output_bp);
    end
  endtask

  mrtc_rdtc_axis32_wrapper u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(clear_status),
    .s_axis_tdata(s_tdata),
    .s_axis_tkeep(s_tkeep),
    .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast),
    .s_axis_tuser(s_tuser),
    .m_axis_tdata(m_tdata),
    .m_axis_tkeep(m_tkeep),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast),
    .m_axis_tuser(m_tuser),
    .cfg_codec_mode(8'(MRTC_CODEC_ZERO_RICE)),
    .cfg_rice_mode(8'(MRTC_RICE_BLOCK_ADAPTIVE_K)),
    .cfg_fixed_k(4'd0),
    .cfg_frame_id(16'd42),
    .cfg_block_id_base(16'd0),
    .cfg_tensor_spatial_size(16'd1),
    .cfg_tensor_doppler_size(16'd64),
    .cfg_tensor_range_size(16'd16),
    .stat_input_beat_count(stat_input_beat_count),
    .stat_input_byte_count(stat_input_byte_count),
    .stat_input_stall_cycles(stat_input_stall_cycles),
    .stat_input_tkeep_error_count(stat_input_tkeep_error_count),
    .stat_input_tlast_error_count(stat_input_tlast_error_count),
    .stat_packed_core_beat_count(stat_packed_core_beat_count),
    .stat_output_beat_count(stat_output_beat_count),
    .stat_output_byte_count(stat_output_byte_count),
    .stat_output_packet_count(stat_output_packet_count),
    .stat_output_backpressure_cycles(stat_output_backpressure_cycles),
    .stat_output_last_tkeep(stat_output_last_tkeep),
    .stat_core_packet_count(stat_core_packet_count),
    .stat_core_error_flags(stat_core_error_flags)
  );

  r9c2p_pre_axis32_to_axis128_repacker u_repacker (
    .clk(clk),
    .rst_n(rst_n),
    .s_axis_tdata(m_tdata),
    .s_axis_tkeep(m_tkeep),
    .s_axis_tvalid(m_tvalid),
    .s_axis_tready(repack_s_tready),
    .s_axis_tlast(m_tlast),
    .s_axis_tuser(m_tuser),
    .i_ready_gate(output_ready_gate),
    .m_axis_tdata(repack_tdata),
    .m_axis_tvalid(repack_tvalid),
    .m_axis_tready(repack_tready),
    .m_axis_tlast(repack_tlast),
    .m_axis_tuser(repack_tuser),
    .o_error_count(repack_error_count)
  );

  mrtc_rdtc_decoder_top #(
    .AXIS_DATA_W(CORE_AXIS_W)
  ) u_decoder (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(clear_status),
    .s_axis_comp_tdata(repack_tdata),
    .s_axis_comp_tvalid(repack_tvalid),
    .s_axis_comp_tready(repack_tready),
    .s_axis_comp_tlast(repack_tlast),
    .s_axis_comp_tuser(repack_tuser),
    .m_axis_raw_tdata(dec_tdata),
    .m_axis_raw_tvalid(dec_tvalid),
    .m_axis_raw_tready(dec_tready),
    .m_axis_raw_tlast(dec_tlast),
    .m_axis_raw_tuser(dec_tuser),
    .stat_busy(dec_busy),
    .stat_done(dec_done),
    .stat_comp_bytes(dec_comp_bytes),
    .stat_raw_bytes(dec_raw_bytes),
    .stat_num_blocks(dec_num_blocks),
    .stat_error(dec_error),
    .stat_error_blocks(dec_error_blocks),
    .stat_stall_input_cycles(dec_stall_input_cycles),
    .stat_stall_output_cycles(dec_stall_output_cycles)
  );

  initial begin
    total_cases = 0;
    failed_cases = 0;
    active_case = "init";
    active_blocks = 0;
    run_case("zero_rice_1block_no_bp", 1, 1'b0, 0, 1'b0);
    run_case("delta_rice_1block_output_bp", 1, 1'b1, 0, 1'b1);
    run_case("mixed_2block_input_gap_output_bp", 2, 1'b1, 1, 1'b0);

    if (failed_cases == 0) begin
      $display("R9C2P_PRE_AXIS32_WRAPPER_SIM_PASS cases=%0d", total_cases);
    end else begin
      $fatal(1, "R9C2P_PRE_AXIS32_WRAPPER_SIM_FAIL failed=%0d total=%0d", failed_cases, total_cases);
    end
    $finish;
  end

  initial begin
    repeat (3000000) @(posedge clk);
    $fatal(1, "R9C2P_PRE_AXIS32_WRAPPER_SIM_FAIL reason=global_timeout case=%s decoded=%0d expected=%0d dec_err=%0d core_err=0x%08x",
           active_case, decoded_block_idx, active_blocks, dec_error, stat_core_error_flags);
  end
endmodule

module r9c2p_pre_axis32_to_axis128_repacker (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [31:0]  s_axis_tdata,
  input  logic [3:0]   s_axis_tkeep,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic         s_axis_tlast,
  input  logic [7:0]   s_axis_tuser,
  input  logic         i_ready_gate,
  output logic [127:0] m_axis_tdata,
  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic         m_axis_tlast,
  output logic [7:0]   m_axis_tuser,
  output logic [31:0]  o_error_count
);
  logic [127:0] buf_reg;
  logic [4:0] buf_count_reg;
  logic [127:0] out_data_reg;
  logic out_valid_reg;
  logic out_last_reg;
  logic [7:0] out_user_reg;
  logic s_fire;
  logic m_fire;

  assign s_axis_tready = !out_valid_reg && i_ready_gate;
  assign s_fire = s_axis_tvalid && s_axis_tready;
  assign m_fire = m_axis_tvalid && m_axis_tready;
  assign m_axis_tdata = out_data_reg;
  assign m_axis_tvalid = out_valid_reg;
  assign m_axis_tlast = out_last_reg;
  assign m_axis_tuser = out_user_reg;

  function automatic int keep_count(input logic [3:0] keep);
    begin
      keep_count = keep[0] + keep[1] + keep[2] + keep[3];
    end
  endfunction

  function automatic bit keep_contiguous(input logic [3:0] keep);
    begin
      keep_contiguous = (keep == 4'h0) || (keep == 4'h1) || (keep == 4'h3) ||
                        (keep == 4'h7) || (keep == 4'hF);
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    int next_count;
    int byte_idx;
    logic [127:0] next_buf;
    if (!rst_n) begin
      buf_reg <= '0;
      buf_count_reg <= '0;
      out_data_reg <= '0;
      out_valid_reg <= 1'b0;
      out_last_reg <= 1'b0;
      out_user_reg <= 8'd0;
      o_error_count <= 32'd0;
    end else begin
      if (m_fire) begin
        out_valid_reg <= 1'b0;
        out_data_reg <= '0;
        out_last_reg <= 1'b0;
        out_user_reg <= 8'd0;
      end

      if (s_fire) begin
        next_buf = buf_reg;
        next_count = int'(buf_count_reg);
        if (!keep_contiguous(s_axis_tkeep) || (s_axis_tkeep == 4'd0)) begin
          o_error_count <= o_error_count + 32'd1;
        end
        if (!s_axis_tlast && (s_axis_tkeep != 4'hF)) begin
          o_error_count <= o_error_count + 32'd1;
        end
        for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1) begin
          if (s_axis_tkeep[byte_idx]) begin
            if (next_count < 16) begin
              next_buf[(next_count * 8) +: 8] = s_axis_tdata[(byte_idx * 8) +: 8];
            end else begin
              o_error_count <= o_error_count + 32'd1;
            end
            next_count = next_count + 1;
          end
        end
        if ((next_count == 16) || s_axis_tlast) begin
          out_data_reg <= next_buf;
          out_valid_reg <= 1'b1;
          out_last_reg <= s_axis_tlast;
          out_user_reg <= s_axis_tuser;
          out_user_reg[3:0] <= (next_count == 0) ? 4'd0 : (4'(next_count) - 4'd1);
          buf_reg <= '0;
          buf_count_reg <= '0;
          if (next_count > 16) begin
            o_error_count <= o_error_count + 32'd1;
          end
        end else begin
          buf_reg <= next_buf;
          buf_count_reg <= 5'(next_count);
        end
      end
    end
  end
endmodule
