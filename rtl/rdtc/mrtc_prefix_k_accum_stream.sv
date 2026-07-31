module mrtc_prefix_k_accum_stream #(
  parameter int I_W = mrtc_pkg::MRTC_I_W,
  parameter int Q_W = mrtc_pkg::MRTC_Q_W,
  parameter int COMPLEX_SAMPLE_W = I_W + Q_W,
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int LANES = PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int PREFIX_COMPLEX_SAMPLES = mrtc_pkg::MRTC_PREFIX_COMPLEX_SAMPLES,
  parameter int PREFIX_SAMPLES = PREFIX_COMPLEX_SAMPLES,
  parameter int BLOCK_COMPLEX_SAMPLES = PREFIX_COMPLEX_SAMPLES,
  parameter bit TRACK_FULL_BLOCK = 1'b0,
  parameter bit PIPELINE_FINAL_ACCUM = 1'b0
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_abort,
  input  logic                   i_start,
  input  logic [7:0]             i_codec_mode,
  input  logic                   i_word_valid,
  input  logic [AXIS_DATA_W-1:0] i_word_data,
  output logic                   o_ready,
  output logic                   o_busy,
  output logic                   o_done,
  output logic [7:0]             o_selected_k,
  output logic [31:0]            o_prefix_bits,
  output logic                   o_unsupported_codec,
  output logic                   o_full_done,
  output logic [31:0]            o_full_payload_bits,
  output logic                   o_guard_valid,
  output logic [$clog2(BLOCK_COMPLEX_SAMPLES/PHASES_PER_BEAT)-1:0]
                                 o_guard_word_index,
  output logic [15:0]            o_guard_le_128_by_k
);
  import mrtc_pkg::*;

  localparam int K_COUNT = 16;
  localparam int COMPONENTS_PER_WORD = LANES * 2;
  localparam int SAMPLE_W = COMPLEX_SAMPLE_W;
  localparam int TRACKED_COMPLEX_SAMPLES =
    TRACK_FULL_BLOCK ? BLOCK_COMPLEX_SAMPLES : PREFIX_COMPLEX_SAMPLES;
  localparam int SAMPLE_COUNT_W = $clog2(TRACKED_COMPLEX_SAMPLES + 1);
  localparam int MAPPED_W = 18;
  localparam int LANE_COST_W = 19;
  localparam int WORD_COST_W = 21;
  localparam int ACCUM_COST_W = 32;
  localparam int GUARD_WORD_INDEX_W =
    $clog2(BLOCK_COMPLEX_SAMPLES / PHASES_PER_BEAT);
  localparam int I_W_CHECK = 1 / ((I_W == 16) ? 1 : 0);
  localparam int Q_W_CHECK = 1 / ((Q_W == 16) ? 1 : 0);
  localparam int COMPLEX_SAMPLE_W_CHECK = 1 / ((COMPLEX_SAMPLE_W == 32) ? 1 : 0);
  localparam int PHASE_CHECK =
    1 / (((PHASES_PER_BEAT == 2) ||
          (PHASES_PER_BEAT == 4) ||
          (PHASES_PER_BEAT == 8)) ? 1 : 0);
  localparam int LANE_COMPAT_CHECK = 1 / ((LANES == PHASES_PER_BEAT) ? 1 : 0);
  localparam int AXIS_CHECK = 1 / ((AXIS_DATA_W == (PHASES_PER_BEAT * SAMPLE_W)) ? 1 : 0);
  localparam int PREFIX_COMPAT_CHECK = 1 / ((PREFIX_SAMPLES == PREFIX_COMPLEX_SAMPLES) ? 1 : 0);
  localparam int PREFIX_ALIGN_CHECK =
    1 / (((PREFIX_COMPLEX_SAMPLES % PHASES_PER_BEAT) == 0) ? 1 : 0);
  localparam int BLOCK_ALIGN_CHECK =
    1 / (((TRACKED_COMPLEX_SAMPLES % PHASES_PER_BEAT) == 0) ? 1 : 0);
  localparam int BLOCK_RANGE_CHECK =
    1 / (((!TRACK_FULL_BLOCK) ||
          (BLOCK_COMPLEX_SAMPLES >= PREFIX_COMPLEX_SAMPLES)) ? 1 : 0);
  localparam int ACCUM_RANGE_CHECK =
    1 / ((TRACKED_COMPLEX_SAMPLES <= 16384) ? 1 : 0);

  logic input_active_reg;
  logic [7:0] codec_mode_reg;
  logic [SAMPLE_COUNT_W-1:0] sample_count_reg;
  logic signed [15:0] prev_i_reg;
  logic signed [15:0] prev_q_reg;
  logic [ACCUM_COST_W-1:0] cand_bits_reg [0:K_COUNT-1];
  logic [ACCUM_COST_W-1:0] final_bits_reg [0:K_COUNT-1];
  logic [ACCUM_COST_W-1:0] red0_bits_reg [0:7];
  logic [3:0] red0_k_reg [0:7];
  logic [ACCUM_COST_W-1:0] red1_bits_reg [0:3];
  logic [3:0] red1_k_reg [0:3];
  logic [ACCUM_COST_W-1:0] red2_bits_reg [0:1];
  logic [3:0] red2_k_reg [0:1];
  logic red0_valid_reg;
  logic red1_valid_reg;
  logic red2_valid_reg;
  logic final_valid_reg;
  logic prefix_result_ready_reg;
  logic full_finalize_pending_reg;
  logic [7:0] selected_k_reg;
  logic [31:0] prefix_bits_reg;
  logic unsupported_codec_reg;
  logic prefix_done_reg;
  logic full_done_reg;
  logic [31:0] full_payload_bits_reg;

  logic                         p0_valid_reg;
  logic [AXIS_DATA_W-1:0]       p0_word_data_reg;
  logic [7:0]                   p0_codec_mode_reg;
  logic [SAMPLE_COUNT_W-1:0]    p0_sample_count_reg;
  logic signed [15:0]           p0_prev_i_reg;
  logic signed [15:0]           p0_prev_q_reg;
  logic                         p0_first_reg;
  logic                         p0_prefix_final_reg;
  logic                         p0_block_final_reg;
  logic [GUARD_WORD_INDEX_W-1:0] p0_guard_word_index_reg;

  logic                         p1_valid_reg;
  logic [MAPPED_W-1:0]          p1_mapped_reg [0:COMPONENTS_PER_WORD-1];
  logic                         p1_first_reg;
  logic                         p1_prefix_final_reg;
  logic                         p1_block_final_reg;
  logic [GUARD_WORD_INDEX_W-1:0] p1_guard_word_index_reg;
  logic                         p2_valid_reg;
  logic [LANE_COST_W-1:0]       p2_lane_bits_reg [0:K_COUNT-1][0:LANES-1];
  logic                         p2_first_reg;
  logic                         p2_prefix_final_reg;
  logic                         p2_block_final_reg;
  logic [GUARD_WORD_INDEX_W-1:0] p2_guard_word_index_reg;
  logic                         p3_valid_reg;
  logic [WORD_COST_W-1:0]       p3_word_bits_reg [0:K_COUNT-1];
  logic                         p3_first_reg;
  logic                         p3_prefix_final_reg;
  logic                         p3_block_final_reg;
  logic [GUARD_WORD_INDEX_W-1:0] p3_guard_word_index_reg;

  logic                         guard_valid_reg;
  logic [GUARD_WORD_INDEX_W-1:0] guard_word_index_reg;
  logic [K_COUNT-1:0]           guard_le_128_by_k_reg;

  logic [MAPPED_W-1:0] p0_mapped [0:COMPONENTS_PER_WORD-1];
  logic [WORD_COST_W-1:0] p2_word_sum [0:K_COUNT-1];
  logic signed [15:0] input_word_last_i_s16;
  logic signed [15:0] input_word_last_q_s16;
  logic input_word_accept;
  logic input_word_first;
  logic input_word_prefix_final;
  logic input_word_block_final;
  logic input_codec_supported;
  logic [7:0] input_codec_mode;
  logic [SAMPLE_COUNT_W-1:0] input_sample_count;
  logic signed [15:0] input_prev_i_s16;
  logic signed [15:0] input_prev_q_s16;

  integer idx;
  integer comb_idx;
  integer lane_idx_reset;

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    begin
      if (residual >= 0) begin
        residual_to_mapped = $unsigned(residual <<< 1);
      end else begin
        residual_to_mapped = $unsigned((-residual <<< 1) - 1);
      end
    end
  endfunction

  function automatic logic [31:0] rice_bits_for_mapped(
    input logic [31:0] mapped,
    input logic [3:0] k_value
  );
    logic [31:0] quotient_u32;
    begin
      quotient_u32 = mapped >> k_value;
      rice_bits_for_mapped = quotient_u32 + 32'd1 + {28'd0, k_value};
    end
  endfunction

  function automatic logic [31:0] sample_word_at_lane(
    input logic [AXIS_DATA_W-1:0] word_data,
    input int lane_idx
  );
    sample_word_at_lane = word_data[(lane_idx * SAMPLE_W) +: SAMPLE_W];
  endfunction

  function automatic logic choose_right(
    input logic [ACCUM_COST_W-1:0] left_bits,
    input logic [3:0] left_k,
    input logic [ACCUM_COST_W-1:0] right_bits,
    input logic [3:0] right_k
  );
    choose_right = (right_bits < left_bits) ||
                   ((right_bits == left_bits) && (right_k < left_k));
  endfunction

  function automatic logic [ACCUM_COST_W-1:0] accumulated_with_word(
    input logic [ACCUM_COST_W-1:0] accumulated,
    input logic [WORD_COST_W-1:0] word_bits,
    input logic first_word
  );
    if (first_word) begin
      accumulated_with_word = ACCUM_COST_W'(word_bits);
    end else begin
      accumulated_with_word = accumulated + ACCUM_COST_W'(word_bits);
    end
  endfunction

  always_comb begin
    logic signed [15:0] curr_i_s16 [0:LANES-1];
    logic signed [15:0] curr_q_s16 [0:LANES-1];
    logic signed [15:0] pred_i_s16;
    logic signed [15:0] pred_q_s16;
    logic signed [17:0] residual_i_s18;
    logic signed [17:0] residual_q_s18;
    logic [31:0] mapped_i_u32;
    logic [31:0] mapped_q_u32;
    logic [31:0] sample_word_u32;

    for (comb_idx = 0; comb_idx < COMPONENTS_PER_WORD; comb_idx = comb_idx + 1) begin
      p0_mapped[comb_idx] = '0;
    end

    for (int lane_idx = 0; lane_idx < LANES; lane_idx = lane_idx + 1) begin
      sample_word_u32 = sample_word_at_lane(p0_word_data_reg, lane_idx);
      curr_i_s16[lane_idx] = $signed(sample_word_u32[15:0]);
      curr_q_s16[lane_idx] = $signed(sample_word_u32[31:16]);

      if ((p0_codec_mode_reg == MRTC_CODEC_DELTA_RICE) &&
          ((p0_sample_count_reg != '0) || (lane_idx != 0))) begin
        pred_i_s16 = (lane_idx == 0) ? p0_prev_i_reg : curr_i_s16[lane_idx - 1];
        pred_q_s16 = (lane_idx == 0) ? p0_prev_q_reg : curr_q_s16[lane_idx - 1];
      end else begin
        pred_i_s16 = 16'sd0;
        pred_q_s16 = 16'sd0;
      end

      residual_i_s18 = curr_i_s16[lane_idx] - pred_i_s16;
      residual_q_s18 = curr_q_s16[lane_idx] - pred_q_s16;
      mapped_i_u32 = residual_to_mapped(residual_i_s18);
      mapped_q_u32 = residual_to_mapped(residual_q_s18);
      p0_mapped[(lane_idx * 2) + 0] = MAPPED_W'(mapped_i_u32);
      p0_mapped[(lane_idx * 2) + 1] = MAPPED_W'(mapped_q_u32);
    end
  end

  generate
    for (genvar sum_k = 0; sum_k < K_COUNT; sum_k = sum_k + 1) begin : g_word_sum
      if (LANES == 2) begin : g_lanes2
        assign p2_word_sum[sum_k] =
          WORD_COST_W'(p2_lane_bits_reg[sum_k][0]) +
          WORD_COST_W'(p2_lane_bits_reg[sum_k][1]);
      end else if (LANES == 4) begin : g_lanes4
        assign p2_word_sum[sum_k] =
          (WORD_COST_W'(p2_lane_bits_reg[sum_k][0]) +
           WORD_COST_W'(p2_lane_bits_reg[sum_k][1])) +
          (WORD_COST_W'(p2_lane_bits_reg[sum_k][2]) +
           WORD_COST_W'(p2_lane_bits_reg[sum_k][3]));
      end else begin : g_lanes8
        assign p2_word_sum[sum_k] =
          ((WORD_COST_W'(p2_lane_bits_reg[sum_k][0]) + WORD_COST_W'(p2_lane_bits_reg[sum_k][1])) +
           (WORD_COST_W'(p2_lane_bits_reg[sum_k][2]) + WORD_COST_W'(p2_lane_bits_reg[sum_k][3]))) +
          ((WORD_COST_W'(p2_lane_bits_reg[sum_k][4]) + WORD_COST_W'(p2_lane_bits_reg[sum_k][5])) +
           (WORD_COST_W'(p2_lane_bits_reg[sum_k][6]) + WORD_COST_W'(p2_lane_bits_reg[sum_k][7])));
      end
    end
  endgenerate

  always_comb begin
    logic [31:0] last_sample_word_u32;

    last_sample_word_u32 = sample_word_at_lane(i_word_data, LANES - 1);
    input_word_last_i_s16 = $signed(last_sample_word_u32[15:0]);
    input_word_last_q_s16 = $signed(last_sample_word_u32[31:16]);
  end

  assign input_codec_mode = (!input_active_reg && i_start) ? i_codec_mode : codec_mode_reg;
  assign input_codec_supported =
    (input_codec_mode == MRTC_CODEC_ZERO_RICE) ||
    (input_codec_mode == MRTC_CODEC_DELTA_RICE);
  assign input_word_accept = i_word_valid &&
    ((input_active_reg && input_codec_supported) ||
     (!o_busy && i_start && input_codec_supported));
  assign input_sample_count = (!input_active_reg && i_start) ? '0 : sample_count_reg;
  assign input_prev_i_s16 = (!input_active_reg && i_start) ? 16'sd0 : prev_i_reg;
  assign input_prev_q_s16 = (!input_active_reg && i_start) ? 16'sd0 : prev_q_reg;
  assign input_word_first = (input_sample_count == '0);
  assign input_word_prefix_final =
    (input_sample_count < SAMPLE_COUNT_W'(PREFIX_COMPLEX_SAMPLES)) &&
    ((input_sample_count + SAMPLE_COUNT_W'(PHASES_PER_BEAT)) >=
     SAMPLE_COUNT_W'(PREFIX_COMPLEX_SAMPLES));
  assign input_word_block_final =
    (input_sample_count + SAMPLE_COUNT_W'(PHASES_PER_BEAT)) >=
    SAMPLE_COUNT_W'(TRACKED_COMPLEX_SAMPLES);

  assign o_busy = input_active_reg || p0_valid_reg || p1_valid_reg || p2_valid_reg ||
                  p3_valid_reg || final_valid_reg || red0_valid_reg ||
                  red1_valid_reg || red2_valid_reg ||
                  full_finalize_pending_reg || prefix_done_reg || full_done_reg;
  assign o_ready = !o_busy || input_active_reg;
  assign o_done = prefix_done_reg;
  assign o_selected_k = selected_k_reg;
  assign o_prefix_bits = prefix_bits_reg;
  assign o_unsupported_codec = unsupported_codec_reg;
  assign o_full_done = full_done_reg;
  assign o_full_payload_bits = full_payload_bits_reg;
  assign o_guard_valid = guard_valid_reg;
  assign o_guard_word_index = guard_word_index_reg;
  assign o_guard_le_128_by_k = guard_le_128_by_k_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      input_active_reg <= 1'b0;
      codec_mode_reg <= MRTC_CODEC_ZERO_RICE;
      sample_count_reg <= '0;
      prev_i_reg <= '0;
      prev_q_reg <= '0;
      selected_k_reg <= 8'd0;
      prefix_bits_reg <= 32'd0;
      unsupported_codec_reg <= 1'b0;
      prefix_done_reg <= 1'b0;
      full_done_reg <= 1'b0;
      full_payload_bits_reg <= 32'd0;
      prefix_result_ready_reg <= 1'b0;
      full_finalize_pending_reg <= 1'b0;
      final_valid_reg <= 1'b0;
      red0_valid_reg <= 1'b0;
      red1_valid_reg <= 1'b0;
      red2_valid_reg <= 1'b0;
      p0_valid_reg <= 1'b0;
      p1_valid_reg <= 1'b0;
      p2_valid_reg <= 1'b0;
      p3_valid_reg <= 1'b0;
      p0_first_reg <= 1'b0;
      p0_prefix_final_reg <= 1'b0;
      p0_block_final_reg <= 1'b0;
      p0_guard_word_index_reg <= '0;
      p1_first_reg <= 1'b0;
      p1_prefix_final_reg <= 1'b0;
      p1_block_final_reg <= 1'b0;
      p1_guard_word_index_reg <= '0;
      p2_first_reg <= 1'b0;
      p2_prefix_final_reg <= 1'b0;
      p2_block_final_reg <= 1'b0;
      p2_guard_word_index_reg <= '0;
      p3_first_reg <= 1'b0;
      p3_prefix_final_reg <= 1'b0;
      p3_block_final_reg <= 1'b0;
      p3_guard_word_index_reg <= '0;
      guard_valid_reg <= 1'b0;
      guard_word_index_reg <= '0;
      guard_le_128_by_k_reg <= '0;
    end else if (i_abort) begin
      input_active_reg <= 1'b0;
      codec_mode_reg <= MRTC_CODEC_ZERO_RICE;
      sample_count_reg <= '0;
      prev_i_reg <= '0;
      prev_q_reg <= '0;
      selected_k_reg <= 8'd0;
      prefix_bits_reg <= 32'd0;
      unsupported_codec_reg <= 1'b0;
      prefix_done_reg <= 1'b0;
      full_done_reg <= 1'b0;
      full_payload_bits_reg <= 32'd0;
      prefix_result_ready_reg <= 1'b0;
      full_finalize_pending_reg <= 1'b0;
      final_valid_reg <= 1'b0;
      red0_valid_reg <= 1'b0;
      red1_valid_reg <= 1'b0;
      red2_valid_reg <= 1'b0;
      p0_valid_reg <= 1'b0;
      p1_valid_reg <= 1'b0;
      p2_valid_reg <= 1'b0;
      p3_valid_reg <= 1'b0;
      guard_valid_reg <= 1'b0;
      guard_word_index_reg <= '0;
      guard_le_128_by_k_reg <= '0;
    end else begin
      prefix_done_reg <= 1'b0;
      full_done_reg <= 1'b0;
      final_valid_reg <= 1'b0;
      red0_valid_reg <= 1'b0;
      red1_valid_reg <= 1'b0;
      red2_valid_reg <= 1'b0;
      guard_valid_reg <= 1'b0;

      p1_valid_reg <= p0_valid_reg;
      p1_first_reg <= p0_first_reg;
      p1_prefix_final_reg <= p0_prefix_final_reg;
      p1_block_final_reg <= p0_block_final_reg;
      p1_guard_word_index_reg <= p0_guard_word_index_reg;
      for (idx = 0; idx < COMPONENTS_PER_WORD; idx = idx + 1) begin
        p1_mapped_reg[idx] <= p0_mapped[idx];
      end

      p2_valid_reg <= p1_valid_reg;
      p2_first_reg <= p1_first_reg;
      p2_prefix_final_reg <= p1_prefix_final_reg;
      p2_block_final_reg <= p1_block_final_reg;
      p2_guard_word_index_reg <= p1_guard_word_index_reg;
      for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
        for (lane_idx_reset = 0; lane_idx_reset < LANES; lane_idx_reset = lane_idx_reset + 1) begin
          p2_lane_bits_reg[idx][lane_idx_reset] <=
            rice_bits_for_mapped(p1_mapped_reg[(lane_idx_reset * 2) + 0], 4'(idx)) +
            rice_bits_for_mapped(p1_mapped_reg[(lane_idx_reset * 2) + 1], 4'(idx));
        end
      end

      p3_valid_reg <= p2_valid_reg;
      p3_first_reg <= p2_first_reg;
      p3_prefix_final_reg <= p2_prefix_final_reg;
      p3_block_final_reg <= p2_block_final_reg;
      p3_guard_word_index_reg <= p2_guard_word_index_reg;
      for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
        p3_word_bits_reg[idx] <= p2_word_sum[idx];
      end

      p0_valid_reg <= 1'b0;

      if (p3_valid_reg) begin
        guard_valid_reg <= 1'b1;
        guard_word_index_reg <= p3_guard_word_index_reg;
        for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
          guard_le_128_by_k_reg[idx] <=
            (p3_word_bits_reg[idx] <= WORD_COST_W'(128));
          cand_bits_reg[idx] <= accumulated_with_word(
            cand_bits_reg[idx], p3_word_bits_reg[idx], p3_first_reg);
        end

        if (p3_prefix_final_reg) begin
          if (PIPELINE_FINAL_ACCUM) begin
            for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
              final_bits_reg[idx] <= accumulated_with_word(
                cand_bits_reg[idx], p3_word_bits_reg[idx], p3_first_reg);
            end
            final_valid_reg <= 1'b1;
          end else begin
            for (idx = 0; idx < 8; idx = idx + 1) begin
              if (choose_right(
                    accumulated_with_word(cand_bits_reg[idx * 2],
                                          p3_word_bits_reg[idx * 2], p3_first_reg),
                    4'(idx * 2),
                    accumulated_with_word(cand_bits_reg[(idx * 2) + 1],
                                          p3_word_bits_reg[(idx * 2) + 1], p3_first_reg),
                    4'((idx * 2) + 1))) begin
                red0_bits_reg[idx] <= accumulated_with_word(
                  cand_bits_reg[(idx * 2) + 1],
                  p3_word_bits_reg[(idx * 2) + 1], p3_first_reg);
                red0_k_reg[idx] <= 4'((idx * 2) + 1);
              end else begin
                red0_bits_reg[idx] <= accumulated_with_word(
                  cand_bits_reg[idx * 2], p3_word_bits_reg[idx * 2], p3_first_reg);
                red0_k_reg[idx] <= 4'(idx * 2);
              end
            end
            red0_valid_reg <= 1'b1;
          end
        end

        if (TRACK_FULL_BLOCK && p3_block_final_reg) begin
          full_finalize_pending_reg <= 1'b1;
        end
      end

      if (PIPELINE_FINAL_ACCUM && final_valid_reg) begin
        for (idx = 0; idx < 8; idx = idx + 1) begin
          if (choose_right(final_bits_reg[idx * 2], 4'(idx * 2),
                           final_bits_reg[(idx * 2) + 1], 4'((idx * 2) + 1))) begin
            red0_bits_reg[idx] <= final_bits_reg[(idx * 2) + 1];
            red0_k_reg[idx] <= 4'((idx * 2) + 1);
          end else begin
            red0_bits_reg[idx] <= final_bits_reg[idx * 2];
            red0_k_reg[idx] <= 4'(idx * 2);
          end
        end
        red0_valid_reg <= 1'b1;
      end

      if (red0_valid_reg) begin
        for (idx = 0; idx < 4; idx = idx + 1) begin
          if (choose_right(red0_bits_reg[idx * 2], red0_k_reg[idx * 2],
                           red0_bits_reg[(idx * 2) + 1], red0_k_reg[(idx * 2) + 1])) begin
            red1_bits_reg[idx] <= red0_bits_reg[(idx * 2) + 1];
            red1_k_reg[idx] <= red0_k_reg[(idx * 2) + 1];
          end else begin
            red1_bits_reg[idx] <= red0_bits_reg[idx * 2];
            red1_k_reg[idx] <= red0_k_reg[idx * 2];
          end
        end
        red1_valid_reg <= 1'b1;
      end

      if (red1_valid_reg) begin
        for (idx = 0; idx < 2; idx = idx + 1) begin
          if (choose_right(red1_bits_reg[idx * 2], red1_k_reg[idx * 2],
                           red1_bits_reg[(idx * 2) + 1], red1_k_reg[(idx * 2) + 1])) begin
            red2_bits_reg[idx] <= red1_bits_reg[(idx * 2) + 1];
            red2_k_reg[idx] <= red1_k_reg[(idx * 2) + 1];
          end else begin
            red2_bits_reg[idx] <= red1_bits_reg[idx * 2];
            red2_k_reg[idx] <= red1_k_reg[idx * 2];
          end
        end
        red2_valid_reg <= 1'b1;
      end

      if (red2_valid_reg) begin
        if (choose_right(red2_bits_reg[0], red2_k_reg[0],
                         red2_bits_reg[1], red2_k_reg[1])) begin
          selected_k_reg <= {4'd0, red2_k_reg[1]};
          prefix_bits_reg <= red2_bits_reg[1];
        end else begin
          selected_k_reg <= {4'd0, red2_k_reg[0]};
          prefix_bits_reg <= red2_bits_reg[0];
        end
        prefix_result_ready_reg <= 1'b1;
        prefix_done_reg <= 1'b1;
        if (!TRACK_FULL_BLOCK) begin
          full_payload_bits_reg <= choose_right(
            red2_bits_reg[0], red2_k_reg[0], red2_bits_reg[1], red2_k_reg[1]) ?
            red2_bits_reg[1] : red2_bits_reg[0];
          full_done_reg <= 1'b1;
        end
      end

      if (full_finalize_pending_reg && prefix_result_ready_reg) begin
        full_payload_bits_reg <= cand_bits_reg[selected_k_reg[3:0]];
        full_done_reg <= 1'b1;
        full_finalize_pending_reg <= 1'b0;
      end

      if (!o_busy && i_start) begin
        codec_mode_reg <= i_codec_mode;
        sample_count_reg <= '0;
        prev_i_reg <= '0;
        prev_q_reg <= '0;
        selected_k_reg <= 8'd0;
        prefix_bits_reg <= 32'd0;
        full_payload_bits_reg <= 32'd0;
        unsupported_codec_reg <= !input_codec_supported;
        prefix_result_ready_reg <= 1'b0;
        full_finalize_pending_reg <= 1'b0;
        final_valid_reg <= 1'b0;
        red0_valid_reg <= 1'b0;
        red1_valid_reg <= 1'b0;
        red2_valid_reg <= 1'b0;
        p0_valid_reg <= 1'b0;
        p1_valid_reg <= 1'b0;
        p2_valid_reg <= 1'b0;
        p3_valid_reg <= 1'b0;
        for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
          cand_bits_reg[idx] <= '0;
        end

        if (!input_codec_supported) begin
          input_active_reg <= 1'b0;
          prefix_done_reg <= 1'b1;
          full_done_reg <= 1'b1;
        end else begin
          input_active_reg <= !input_word_accept || !input_word_block_final;
          if (input_word_accept) begin
            p0_valid_reg <= 1'b1;
            p0_word_data_reg <= i_word_data;
            p0_codec_mode_reg <= input_codec_mode;
            p0_sample_count_reg <= input_sample_count;
            p0_prev_i_reg <= input_prev_i_s16;
            p0_prev_q_reg <= input_prev_q_s16;
            p0_first_reg <= input_word_first;
            p0_prefix_final_reg <= input_word_prefix_final;
            p0_block_final_reg <= input_word_block_final;
            p0_guard_word_index_reg <= GUARD_WORD_INDEX_W'(
              input_sample_count / PHASES_PER_BEAT);
            sample_count_reg <= SAMPLE_COUNT_W'(PHASES_PER_BEAT);
            prev_i_reg <= input_word_last_i_s16;
            prev_q_reg <= input_word_last_q_s16;
          end
        end
      end else if (input_active_reg && input_word_accept) begin
        p0_valid_reg <= 1'b1;
        p0_word_data_reg <= i_word_data;
        p0_codec_mode_reg <= input_codec_mode;
        p0_sample_count_reg <= input_sample_count;
        p0_prev_i_reg <= input_prev_i_s16;
        p0_prev_q_reg <= input_prev_q_s16;
        p0_first_reg <= input_word_first;
        p0_prefix_final_reg <= input_word_prefix_final;
        p0_block_final_reg <= input_word_block_final;
        p0_guard_word_index_reg <= GUARD_WORD_INDEX_W'(
          input_sample_count / PHASES_PER_BEAT);
        sample_count_reg <= sample_count_reg + SAMPLE_COUNT_W'(PHASES_PER_BEAT);
        prev_i_reg <= input_word_last_i_s16;
        prev_q_reg <= input_word_last_q_s16;
        if (input_word_block_final) begin
          input_active_reg <= 1'b0;
        end
      end
    end
  end
endmodule
