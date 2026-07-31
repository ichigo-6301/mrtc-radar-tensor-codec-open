`timescale 1ns/1ps

module tb_mrtc_prefix_k_accum_pipeline_equivalence;
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int PREFIX_SAMPLES = 128;
  localparam int PREFIX_WORDS = PREFIX_SAMPLES / MRTC_LANES;
  localparam int GUARD_INDEX_W = $clog2(MRTC_BLOCK_SAMPLES / MRTC_LANES);

  logic clk;
  logic rst_n;
  logic abort_run;
  logic start_run;
  logic word_valid;
  logic [AXIS_DATA_W-1:0] word_data;

  logic legacy_ready;
  logic legacy_busy;
  logic legacy_done;
  logic [7:0] legacy_k;
  logic [31:0] legacy_bits;
  logic legacy_guard_valid;
  logic [GUARD_INDEX_W-1:0] legacy_guard_index;
  logic [15:0] legacy_guard;

  logic pipe_ready;
  logic pipe_busy;
  logic pipe_done;
  logic [7:0] pipe_k;
  logic [31:0] pipe_bits;
  logic pipe_guard_valid;
  logic [GUARD_INDEX_W-1:0] pipe_guard_index;
  logic [15:0] pipe_guard;

  integer cycle_count;
  integer legacy_done_cycle;
  integer pipe_done_cycle;
  integer guard_count;

  initial clk = 1'b0;
  always #2.5 clk = ~clk;

  function automatic logic [AXIS_DATA_W-1:0] test_word(
    input int case_index,
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
        if (case_index == 0) begin
          i_value = 0;
          q_value = 0;
        end else begin
          i_value = ((sample_index * 5 + 3) % 15) - 7;
          q_value = ((sample_index * 7 + 1) % 13) - 6;
        end
        value[(lane * 32) +: 16] = 16'(i_value);
        value[(lane * 32) + 16 +: 16] = 16'(q_value);
      end
      test_word = value;
    end
  endfunction

  task automatic run_case(input int case_index, input string case_name);
    begin
      wait (legacy_ready && pipe_ready && !legacy_busy && !pipe_busy);
      legacy_done_cycle = -1;
      pipe_done_cycle = -1;
      guard_count = 0;

      for (int word_index = 0; word_index < PREFIX_WORDS; word_index = word_index + 1) begin
        @(negedge clk);
        start_run = (word_index == 0);
        word_valid = 1'b1;
        word_data = test_word(case_index, word_index);
        if (!legacy_ready || !pipe_ready) begin
          $fatal(1, "prefix input stalled case=%s word=%0d", case_name, word_index);
        end
      end
      @(negedge clk);
      start_run = 1'b0;
      word_valid = 1'b0;
      word_data = '0;

      wait ((legacy_done_cycle >= 0) && (pipe_done_cycle >= 0));
      #1;
      if (pipe_done_cycle != (legacy_done_cycle + 1)) begin
        $fatal(1,
               "prefix final pipeline latency mismatch case=%s legacy=%0d pipe=%0d",
               case_name, legacy_done_cycle, pipe_done_cycle);
      end
      if ((legacy_k !== pipe_k) || (legacy_bits !== pipe_bits)) begin
        $fatal(1,
               "prefix final pipeline result mismatch case=%s legacy=%0d/%0d pipe=%0d/%0d",
               case_name, legacy_k, legacy_bits, pipe_k, pipe_bits);
      end
      if (guard_count != PREFIX_WORDS) begin
        $fatal(1, "prefix guard count mismatch case=%s got=%0d expected=%0d",
               case_name, guard_count, PREFIX_WORDS);
      end
      $display("PASS prefix_pipeline case=%s k=%0d bits=%0d latency_delta=1 guards=%0d",
               case_name, pipe_k, pipe_bits, guard_count);
      repeat (3) @(posedge clk);
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      cycle_count = 0;
    end else begin
      cycle_count = cycle_count + 1;
      if (legacy_done) begin
        legacy_done_cycle = cycle_count;
      end
      if (pipe_done) begin
        pipe_done_cycle = cycle_count;
      end
      if (legacy_guard_valid !== pipe_guard_valid) begin
        $fatal(1, "prefix guard valid shifted at cycle=%0d", cycle_count);
      end
      if (legacy_guard_valid) begin
        if ((legacy_guard_index !== pipe_guard_index) ||
            (legacy_guard !== pipe_guard)) begin
          $fatal(1,
                 "prefix guard mismatch cycle=%0d legacy=%0d/%04x pipe=%0d/%04x",
                 cycle_count, legacy_guard_index, legacy_guard,
                 pipe_guard_index, pipe_guard);
        end
        guard_count = guard_count + 1;
      end
    end
  end

  initial begin
    rst_n = 1'b0;
    abort_run = 1'b0;
    start_run = 1'b0;
    word_valid = 1'b0;
    word_data = '0;
    legacy_done_cycle = -1;
    pipe_done_cycle = -1;
    guard_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    run_case(0, "all_zero");
    run_case(1, "small_random");

    $display("PASS tb_mrtc_prefix_k_accum_pipeline_equivalence");
    $finish;
  end

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_prefix_k_accum_pipeline_equivalence");
  end

  mrtc_prefix_k_accum_stream #(
    .AXIS_DATA_W            (AXIS_DATA_W),
    .PREFIX_COMPLEX_SAMPLES (PREFIX_SAMPLES),
    .PREFIX_SAMPLES         (PREFIX_SAMPLES),
    .BLOCK_COMPLEX_SAMPLES  (MRTC_BLOCK_SAMPLES),
    .TRACK_FULL_BLOCK       (1'b0),
    .PIPELINE_FINAL_ACCUM   (1'b0)
  ) u_legacy (
    .clk,
    .rst_n,
    .i_abort             (abort_run),
    .i_start             (start_run),
    .i_codec_mode        (MRTC_CODEC_ZERO_RICE),
    .i_word_valid        (word_valid),
    .i_word_data         (word_data),
    .o_ready             (legacy_ready),
    .o_busy              (legacy_busy),
    .o_done              (legacy_done),
    .o_selected_k        (legacy_k),
    .o_prefix_bits       (legacy_bits),
    .o_unsupported_codec (),
    .o_full_done         (),
    .o_full_payload_bits (),
    .o_guard_valid       (legacy_guard_valid),
    .o_guard_word_index  (legacy_guard_index),
    .o_guard_le_128_by_k (legacy_guard)
  );

  mrtc_prefix_k_accum_stream #(
    .AXIS_DATA_W            (AXIS_DATA_W),
    .PREFIX_COMPLEX_SAMPLES (PREFIX_SAMPLES),
    .PREFIX_SAMPLES         (PREFIX_SAMPLES),
    .BLOCK_COMPLEX_SAMPLES  (MRTC_BLOCK_SAMPLES),
    .TRACK_FULL_BLOCK       (1'b0),
    .PIPELINE_FINAL_ACCUM   (1'b1)
  ) u_pipeline (
    .clk,
    .rst_n,
    .i_abort             (abort_run),
    .i_start             (start_run),
    .i_codec_mode        (MRTC_CODEC_ZERO_RICE),
    .i_word_valid        (word_valid),
    .i_word_data         (word_data),
    .o_ready             (pipe_ready),
    .o_busy              (pipe_busy),
    .o_done              (pipe_done),
    .o_selected_k        (pipe_k),
    .o_prefix_bits       (pipe_bits),
    .o_unsupported_codec (),
    .o_full_done         (),
    .o_full_payload_bits (),
    .o_guard_valid       (pipe_guard_valid),
    .o_guard_word_index  (pipe_guard_index),
    .o_guard_le_128_by_k (pipe_guard)
  );
endmodule
