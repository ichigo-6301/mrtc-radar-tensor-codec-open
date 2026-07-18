module mrtc_rice_bitpacker_lane_axis #(
  parameter int I_W              = mrtc_pkg::MRTC_I_W,
  parameter int Q_W              = mrtc_pkg::MRTC_Q_W,
  parameter int COMPLEX_SAMPLE_W = I_W + Q_W,
  parameter int PHASES_PER_BEAT  = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int LANES            = PHASES_PER_BEAT,
  parameter int AXIS_DATA_W      = COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int BLOCK_SAMPLES    = mrtc_pkg::MRTC_COMPLEX_SAMPLES_PER_BLOCK,
  parameter int BLOCK_BEATS      = BLOCK_SAMPLES / PHASES_PER_BEAT,
  parameter int ADDR_W           = $clog2(BLOCK_BEATS),
  parameter int PACKER_LANE_MODE = 1,
  parameter int TOKEN_W          = 256,
  parameter int WORD_FIFO_DEPTH  = 4
) (
  input  logic                                   clk,
  input  logic                                   rst_n,
  input  logic                                   i_start,
  input  logic [7:0]                             i_codec_mode,
  input  logic [7:0]                             i_selected_k,
  output logic                                   o_word_rd_req,
  output logic [$clog2(BLOCK_BEATS)-1:0]         o_word_rd_addr_base,
  input  logic                                   i_word_rd_valid,
  input  logic [AXIS_DATA_W-1:0]                 i_word_rd_data,
  output logic [AXIS_DATA_W-1:0]                 m_axis_tdata,
  output logic                                   m_axis_tvalid,
  input  logic                                   m_axis_tready,
  output logic                                   m_axis_tlast,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0]   m_axis_tvalid_bytes_minus1,
  output logic                                   o_busy,
  output logic                                   o_done,
  output logic [31:0]                            o_payload_bits_counted,
  output logic [31:0]                            o_payload_bytes_counted,
  output logic                                   o_overflow,
  output logic                                   o_long_unary_used,
  output logic                                   o_group_fallback_used
);
  import mrtc_pkg::*;

  localparam int WORD_ADDR_W = $clog2(BLOCK_BEATS);
  localparam int BLOCK_WORDS = BLOCK_BEATS;
  localparam int WORD_COUNT_W = $clog2(BLOCK_WORDS + 1);
  localparam int TOKEN_LEN_W = $clog2(TOKEN_W + 1);
  localparam int SAMPLE_IDX_W = (LANES <= 1) ? 1 : $clog2(LANES);
  localparam int SAMPLE_COUNT_W = (LANES <= 1) ? 1 : $clog2(LANES + 1);
  localparam int MAX_COMPONENTS = LANES * 2;
  localparam int MAPPED_W = I_W + 2;
  localparam int QUOTIENT_W = 18;
  localparam int REMAINDER_W = 16;
  localparam int COMPONENT_LEN_W = 18;
  localparam int GROUP_LEN_W = 21;
  localparam int COMPONENT_COUNT_W = $clog2(MAX_COMPONENTS + 1);
  localparam int TOKEN_OR_LEAVES = 16;
  localparam int COMPONENT_PAIR_COUNT = (MAX_COMPONENTS + 1) / 2;
  localparam int COMPONENT_PAIR_TREE_LEAVES = 8;
  localparam int FIFO_PTR_W = (WORD_FIFO_DEPTH <= 1) ? 1 : $clog2(WORD_FIFO_DEPTH);
  localparam int FIFO_COUNT_W = $clog2(WORD_FIFO_DEPTH + 1);
  localparam int I_W_CHECK = 1 / ((I_W == 16) ? 1 : 0);
  localparam int Q_W_CHECK = 1 / ((Q_W == 16) ? 1 : 0);
  localparam int COMPLEX_SAMPLE_W_CHECK = 1 / ((COMPLEX_SAMPLE_W == 32) ? 1 : 0);
  localparam int PHASE_CHECK =
    1 / (((PHASES_PER_BEAT == 2) ||
          (PHASES_PER_BEAT == 4) ||
          (PHASES_PER_BEAT == 8)) ? 1 : 0);
  localparam int LANE_COMPAT_CHECK = 1 / ((LANES == PHASES_PER_BEAT) ? 1 : 0);
  localparam int PACKER_LANE_MODE_CHECK =
    1 / (((PACKER_LANE_MODE == 1) || (PACKER_LANE_MODE == LANES)) ? 1 : 0);
  localparam int AXIS_DATA_W_CHECK =
    1 / ((AXIS_DATA_W == (LANES * COMPLEX_SAMPLE_W)) ? 1 : 0);
  localparam int BLOCK_SAMPLES_CHECK =
    1 / (((BLOCK_SAMPLES % LANES) == 0) ? 1 : 0);
  localparam int BLOCK_BEATS_CHECK =
    1 / ((BLOCK_BEATS == (BLOCK_SAMPLES / PHASES_PER_BEAT)) ? 1 : 0);
  localparam int ADDR_W_CHECK =
    1 / ((ADDR_W == WORD_ADDR_W) ? 1 : 0);
  localparam int TOKEN_W_CHECK = 1 / ((TOKEN_W >= AXIS_DATA_W) ? 1 : 0);
  localparam int WORD_FIFO_DEPTH_CHECK = 1 / ((WORD_FIFO_DEPTH >= 2) ? 1 : 0);

  typedef enum logic [3:0] {
    ST_IDLE           = 4'd0,
    ST_SETUP          = 4'd1,
    ST_FETCH_WORD     = 4'd2,
    ST_BUILD_GROUP    = 4'd3,
    ST_WAIT_TOKEN     = 4'd4,
    ST_FALLBACK_UNARY = 4'd5,
    ST_FALLBACK_ZREM  = 4'd6,
    ST_WAIT_ACC_DONE  = 4'd7,
    ST_DONE           = 4'd8
  } state_t;

  state_t state_reg;

  logic [7:0]             codec_mode_reg;
  logic [3:0]             selected_k_reg;
  logic [WORD_COUNT_W-1:0] issue_word_idx_reg;
  logic [WORD_COUNT_W-1:0] return_word_idx_reg;
  logic [FIFO_COUNT_W-1:0] pending_reads_reg;

  logic [AXIS_DATA_W-1:0] word_fifo_data [0:WORD_FIFO_DEPTH-1];
  logic [WORD_ADDR_W-1:0] word_fifo_idx [0:WORD_FIFO_DEPTH-1];
  logic [FIFO_PTR_W-1:0]  word_fifo_wr_ptr_reg;
  logic [FIFO_PTR_W-1:0]  word_fifo_rd_ptr_reg;
  logic [FIFO_COUNT_W-1:0] word_fifo_count_reg;

  logic                   current_word_valid_reg;
  logic [AXIS_DATA_W-1:0] current_word_data_reg;
  logic [WORD_ADDR_W-1:0] current_word_idx_reg;
  logic [SAMPLE_IDX_W-1:0] sample_idx_in_word_reg;
  logic                   sample_stream_mode_reg;

  logic signed [15:0]     prev_i_global_reg;
  logic signed [15:0]     prev_q_global_reg;

  logic                   token_valid_reg;
  logic [TOKEN_W-1:0]     token_bits_reg;
  logic [TOKEN_LEN_W-1:0] token_len_reg;
  logic                   token_last_reg;
  logic                   token_ready;
  logic                   token_accepted;

  // Stage 21A token-builder pipeline.  The stages intentionally keep the
  // accumulator-facing token register unchanged while breaking the old
  // current_word_idx/sample-select -> token_bits cone into registered cuts.
  logic                              p0_valid_reg;
  logic [AXIS_DATA_W-1:0]            p0_word_data_reg;
  logic [WORD_ADDR_W-1:0]            p0_word_idx_reg;
  logic [SAMPLE_IDX_W-1:0]           p0_sample_idx_reg;
  logic [SAMPLE_COUNT_W-1:0]         p0_sample_count_reg;
  logic [COMPONENT_COUNT_W-1:0]      p0_component_count_reg;
  logic [7:0]                        p0_codec_mode_reg;
  logic [3:0]                        p0_selected_k_reg;
  logic signed [15:0]                p0_prev_i_reg;
  logic signed [15:0]                p0_prev_q_reg;
  logic                              p0_token_last_reg;
  logic                              p0_whole_group_reg;

  // P1R: isolate predictor selection and signed residual subtraction from
  // the following zigzag mapping stage.
  logic                              p1r_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p1r_component_count_reg;
  logic [3:0]                        p1r_selected_k_reg;
  logic                              p1r_token_last_reg;
  logic                              p1r_whole_group_reg;
  logic signed [17:0]                p1r_residual_reg [0:MAX_COMPONENTS-1];

  logic                              p1_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p1_component_count_reg;
  logic [3:0]                        p1_selected_k_reg;
  logic                              p1_token_last_reg;
  logic                              p1_whole_group_reg;
  logic [MAPPED_W-1:0]               p1_mapped_reg [0:MAX_COMPONENTS-1];

  logic                              p2_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p2_component_count_reg;
  logic [3:0]                        p2_selected_k_reg;
  logic                              p2_token_last_reg;
  logic                              p2_whole_group_reg;
  logic [MAPPED_W-1:0]               p2_mapped_reg [0:MAX_COMPONENTS-1];
  logic [QUOTIENT_W-1:0]             p2_quotient_reg [0:MAX_COMPONENTS-1];
  logic [REMAINDER_W-1:0]            p2_remainder_reg [0:MAX_COMPONENTS-1];
  logic [COMPONENT_LEN_W-1:0]        p2_component_len_reg [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p2_pair_len_reg [0:COMPONENT_PAIR_TREE_LEAVES-1];
  logic [COMPONENT_LEN_W-1:0]        p1_component_len_comb [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p1_pair_len_comb [0:COMPONENT_PAIR_TREE_LEAVES-1];

  // P2S uses a parallel suffix-sum tree to derive the total token length and
  // every component placement offset without the old serial cursor chain.
  logic                              p2s_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p2s_component_count_reg;
  logic [3:0]                        p2s_selected_k_reg;
  logic                              p2s_token_last_reg;
  logic                              p2s_whole_group_reg;
  logic [MAPPED_W-1:0]               p2s_mapped_reg [0:MAX_COMPONENTS-1];
  logic [QUOTIENT_W-1:0]             p2s_quotient_reg [0:MAX_COMPONENTS-1];
  logic [REMAINDER_W-1:0]            p2s_remainder_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_LEN_W-1:0]            p2s_component_shift_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_LEN_W-1:0]            p2s_token_len_reg;
  logic                              p2s_success_reg;

  logic [GROUP_LEN_W-1:0]            p2_suffix_l0 [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p2_suffix_l1 [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p2_suffix_l2 [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p2_suffix_l3 [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p2_suffix_l4 [0:MAX_COMPONENTS-1];
  logic [GROUP_LEN_W-1:0]            p2_pair_sum_l1 [0:(COMPONENT_PAIR_TREE_LEAVES/2)-1];
  logic [GROUP_LEN_W-1:0]            p2_pair_sum_l2 [0:(COMPONENT_PAIR_TREE_LEAVES/4)-1];
  logic [GROUP_LEN_W-1:0]            p2_pair_sum_l3 [0:(COMPONENT_PAIR_TREE_LEAVES/8)-1];
  logic [GROUP_LEN_W-1:0]            p2_total_bits_comb;
  logic [GROUP_LEN_W-1:0]            p2_component_shift_comb [0:MAX_COMPONENTS-1];

  // P3A: cursor/control and per-component code-bit prep.  This stage breaks
  // the Stage 21B p2_total_bits -> wide p3_token_bits assembly path.
  logic                              p3a_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p3a_component_count_reg;
  logic [3:0]                        p3a_selected_k_reg;
  logic                              p3a_token_last_reg;
  logic                              p3a_whole_group_reg;
  logic [MAPPED_W-1:0]               p3a_mapped_reg [0:MAX_COMPONENTS-1];
  logic [QUOTIENT_W-1:0]             p3a_quotient_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_W-1:0]                p3a_component_bits_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_LEN_W-1:0]            p3a_component_shift_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_LEN_W-1:0]            p3a_token_len_reg;
  logic                              p3a_success_reg;
  logic [TOKEN_W-1:0]                p3a_positioned_bits [0:TOKEN_OR_LEAVES-1];
  logic [TOKEN_W-1:0]                p3a_or_l1 [0:(TOKEN_OR_LEAVES/2)-1];

  // P3P registers pair-local positioned component partials.  This cuts the
  // dynamic shift and first OR away from the final group register.
  logic                              p3p_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p3p_component_count_reg;
  logic                              p3p_token_last_reg;
  logic [MAPPED_W-1:0]               p3p_mapped_reg [0:MAX_COMPONENTS-1];
  logic [QUOTIENT_W-1:0]             p3p_quotient_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_W-1:0]                p3p_pair_bits_reg [0:(TOKEN_OR_LEAVES/2)-1];
  logic [TOKEN_LEN_W-1:0]            p3p_token_len_reg;
  logic                              p3p_success_reg;

  // P3B registers four groups of four positioned components.  This cuts the
  // dynamic-shift routing cone before the final two-level OR reduction.
  logic                              p3b_valid_reg;
  logic [COMPONENT_COUNT_W-1:0]      p3b_component_count_reg;
  logic                              p3b_token_last_reg;
  // A signed I_W residual maps to at most I_W+1 zigzag bits.  Keeping the
  // fallback copy at 32 bits wastes registers without preserving information.
  logic [MAPPED_W-1:0]               p3b_mapped_reg [0:MAX_COMPONENTS-1];
  logic [QUOTIENT_W-1:0]             p3b_quotient_reg [0:MAX_COMPONENTS-1];
  logic [TOKEN_W-1:0]                p3b_group_bits_reg [0:3];
  logic [TOKEN_LEN_W-1:0]            p3b_token_len_reg;
  logic                              p3b_success_reg;
  logic [TOKEN_W-1:0]                p3b_assembled_bits;

  logic                              p0_ready;
  logic                              p1_ready;
  logic                              p2_ready;
  logic                              p2s_ready;
  logic                              p3a_ready;
  logic                              p3p_ready;
  logic                              p3b_ready;
  logic                              p1r_ready;
  logic                              final_token_slot_ready;
  logic                              fallback_active;
  logic                              p3_fallback_pending;

  logic [31:0]            payload_bits_counted_reg;
  logic [31:0]            payload_bytes_counted_reg;
  logic                   overflow_reg;
  logic                   long_unary_used_reg;
  logic                   group_fallback_used_reg;

  logic                   fallback_component_is_q_reg;
  logic [31:0]            fallback_unary_remaining_reg;
  logic [31:0]            fallback_mapped_reg;
  logic                   fallback_token_last_reg;
  logic                   fallback_packet_last_reg;
  logic [3:0]             fallback_selected_k_reg;
  logic [COMPONENT_COUNT_W-1:0] fallback_component_idx_reg;
  logic [COMPONENT_COUNT_W-1:0] fallback_component_count_reg;
  logic [MAPPED_W-1:0]    fallback_component_mapped_reg [0:MAX_COMPONENTS-1];
  logic [QUOTIENT_W-1:0]  fallback_component_quotient_reg [0:MAX_COMPONENTS-1];
  state_t                 fallback_resume_state_reg;

  logic                   acc_done;
  logic                   acc_overflow;
  logic                   codec_supported;

  integer                 fifo_init_idx;
  integer                 component_init_idx;
  integer                 pair_init_idx;

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    if (residual >= 0) begin
      residual_to_mapped = $unsigned(residual <<< 1);
    end else begin
      residual_to_mapped = $unsigned((-residual <<< 1) - 1);
    end
  endfunction

  function automatic logic [31:0] low_mask_u32(input logic [3:0] bit_count);
    logic [32:0] one_ext;
    logic [32:0] mask_ext;
    begin
      one_ext = '0;
      one_ext[0] = 1'b1;
      mask_ext = (one_ext << bit_count) - one_ext;
      low_mask_u32 = mask_ext[31:0];
    end
  endfunction

  function automatic logic [TOKEN_W-1:0] low_mask_token(
    input logic [TOKEN_LEN_W-1:0] bit_count
  );
    logic [TOKEN_W-1:0] mask_bits;
    int mask_idx;
    begin
      mask_bits = '0;
      for (mask_idx = 0; mask_idx < TOKEN_W; mask_idx = mask_idx + 1) begin
        mask_bits[mask_idx] = (TOKEN_LEN_W'(mask_idx) < bit_count);
      end
      low_mask_token = mask_bits;
    end
  endfunction

  function automatic logic [TOKEN_W-1:0] build_component_code_bits(
    input logic [31:0] quotient_u32,
    input logic [31:0] remainder_u32,
    input logic [3:0]  selected_k
  );
    logic [TOKEN_W-1:0] component_bits;
    logic [TOKEN_W-1:0] unary_bits;
    logic [31:0]        remainder_masked;
    int                 quotient_int;
    int                 remainder_bits_int;
    begin
      quotient_int = int'(quotient_u32);
      remainder_bits_int = int'(selected_k);
      unary_bits = low_mask_token(TOKEN_LEN_W'(quotient_int));
      remainder_masked = remainder_u32 & low_mask_u32(selected_k);
      component_bits = '0;
      component_bits = component_bits |
        (unary_bits << (remainder_bits_int + 1));
      component_bits = component_bits |
        TOKEN_W'(remainder_masked);
      build_component_code_bits = component_bits;
    end
  endfunction

  function automatic logic signed [15:0] word_lane_i(
    input logic [AXIS_DATA_W-1:0] word_data,
    input int lane_idx
  );
    word_lane_i = $signed(word_data[(lane_idx * 32) +: 16]);
  endfunction

  function automatic logic signed [15:0] word_lane_q(
    input logic [AXIS_DATA_W-1:0] word_data,
    input int lane_idx
  );
    word_lane_q = $signed(word_data[(lane_idx * 32) + 16 +: 16]);
  endfunction

  task automatic get_component_fields(
    input  logic [AXIS_DATA_W-1:0]  word_data,
    input  logic [WORD_ADDR_W-1:0]  word_idx,
    input  logic [SAMPLE_IDX_W-1:0] sample_idx,
    input  logic                    is_q,
    input  logic [7:0]              codec_mode,
    input  logic [3:0]              selected_k,
    input  logic signed [15:0]      prev_i_global,
    input  logic signed [15:0]      prev_q_global,
    output logic signed [17:0]      residual_s18,
    output logic [31:0]             mapped_u32,
    output logic [31:0]             quotient_u32,
    output logic [31:0]             remainder_u32
  );
    logic signed [15:0] curr_i_s16;
    logic signed [15:0] curr_q_s16;
    logic signed [15:0] pred_i_s16;
    logic signed [15:0] pred_q_s16;
    begin
      curr_i_s16 = word_lane_i(word_data, sample_idx);
      curr_q_s16 = word_lane_q(word_data, sample_idx);

      if (codec_mode == MRTC_CODEC_DELTA_RICE) begin
        if ((word_idx == WORD_ADDR_W'(0)) && (sample_idx == SAMPLE_IDX_W'(0))) begin
          pred_i_s16 = 16'sd0;
          pred_q_s16 = 16'sd0;
        end else if (sample_idx == SAMPLE_IDX_W'(0)) begin
          pred_i_s16 = prev_i_global;
          pred_q_s16 = prev_q_global;
        end else begin
          pred_i_s16 = word_lane_i(word_data, sample_idx - SAMPLE_IDX_W'(1));
          pred_q_s16 = word_lane_q(word_data, sample_idx - SAMPLE_IDX_W'(1));
        end
      end else begin
        pred_i_s16 = 16'sd0;
        pred_q_s16 = 16'sd0;
      end

      if (is_q) begin
        residual_s18 = curr_q_s16 - pred_q_s16;
      end else begin
        residual_s18 = curr_i_s16 - pred_i_s16;
      end

      mapped_u32   = residual_to_mapped(residual_s18);
      quotient_u32 = mapped_u32 >> selected_k;
      if (selected_k == 4'd0) begin
        remainder_u32 = 32'd0;
      end else begin
        remainder_u32 = mapped_u32 & ((32'd1 << selected_k) - 32'd1);
      end
    end
  endtask

  task automatic get_component_mapped(
    input  logic [AXIS_DATA_W-1:0]  word_data,
    input  logic [WORD_ADDR_W-1:0]  word_idx,
    input  logic [SAMPLE_IDX_W-1:0] sample_idx,
    input  logic                    is_q,
    input  logic [7:0]              codec_mode,
    input  logic signed [15:0]      prev_i_global,
    input  logic signed [15:0]      prev_q_global,
    output logic signed [17:0]      residual_s18,
    output logic [31:0]             mapped_u32
  );
    logic signed [15:0] curr_i_s16;
    logic signed [15:0] curr_q_s16;
    logic signed [15:0] pred_i_s16;
    logic signed [15:0] pred_q_s16;
    begin
      curr_i_s16 = word_lane_i(word_data, sample_idx);
      curr_q_s16 = word_lane_q(word_data, sample_idx);

      if (codec_mode == MRTC_CODEC_DELTA_RICE) begin
        if ((word_idx == WORD_ADDR_W'(0)) && (sample_idx == SAMPLE_IDX_W'(0))) begin
          pred_i_s16 = 16'sd0;
          pred_q_s16 = 16'sd0;
        end else if (sample_idx == SAMPLE_IDX_W'(0)) begin
          pred_i_s16 = prev_i_global;
          pred_q_s16 = prev_q_global;
        end else begin
          pred_i_s16 = word_lane_i(word_data, sample_idx - SAMPLE_IDX_W'(1));
          pred_q_s16 = word_lane_q(word_data, sample_idx - SAMPLE_IDX_W'(1));
        end
      end else begin
        pred_i_s16 = 16'sd0;
        pred_q_s16 = 16'sd0;
      end

      if (is_q) begin
        residual_s18 = curr_q_s16 - pred_q_s16;
      end else begin
        residual_s18 = curr_i_s16 - pred_i_s16;
      end
      mapped_u32 = residual_to_mapped(residual_s18);
    end
  endtask

  task automatic get_component_residual(
    input  logic [AXIS_DATA_W-1:0]  word_data,
    input  logic [WORD_ADDR_W-1:0]  word_idx,
    input  logic [SAMPLE_IDX_W-1:0] sample_idx,
    input  logic                    is_q,
    input  logic [7:0]              codec_mode,
    input  logic signed [15:0]      prev_i_global,
    input  logic signed [15:0]      prev_q_global,
    output logic signed [17:0]      residual_s18
  );
    logic signed [15:0] curr_i_s16;
    logic signed [15:0] curr_q_s16;
    logic signed [15:0] pred_i_s16;
    logic signed [15:0] pred_q_s16;
    begin
      curr_i_s16 = word_lane_i(word_data, sample_idx);
      curr_q_s16 = word_lane_q(word_data, sample_idx);

      if (codec_mode == MRTC_CODEC_DELTA_RICE) begin
        if ((word_idx == WORD_ADDR_W'(0)) && (sample_idx == SAMPLE_IDX_W'(0))) begin
          pred_i_s16 = 16'sd0;
          pred_q_s16 = 16'sd0;
        end else if (sample_idx == SAMPLE_IDX_W'(0)) begin
          pred_i_s16 = prev_i_global;
          pred_q_s16 = prev_q_global;
        end else begin
          pred_i_s16 = word_lane_i(word_data, sample_idx - SAMPLE_IDX_W'(1));
          pred_q_s16 = word_lane_q(word_data, sample_idx - SAMPLE_IDX_W'(1));
        end
      end else begin
        pred_i_s16 = 16'sd0;
        pred_q_s16 = 16'sd0;
      end

      residual_s18 = is_q ? (curr_q_s16 - pred_q_s16) :
                            (curr_i_s16 - pred_i_s16);
    end
  endtask

  task automatic build_group_token(
    input  logic [AXIS_DATA_W-1:0]  word_data,
    input  logic [WORD_ADDR_W-1:0]  word_idx,
    input  logic [SAMPLE_IDX_W-1:0] sample_idx_base,
    input  int                      sample_count,
    input  logic [7:0]              codec_mode,
    input  logic [3:0]              selected_k,
    input  logic signed [15:0]      prev_i_global,
    input  logic signed [15:0]      prev_q_global,
    output logic                    success,
    output logic [TOKEN_W-1:0]      token_bits,
    output logic [TOKEN_LEN_W-1:0]  token_len
  );
    logic signed [17:0] residual_s18;
    logic [31:0]        mapped_u32;
    logic [31:0]        quotient_u32;
    logic [31:0]        remainder_u32;
    logic [31:0]        component_quotient [0:(LANES*2)-1];
    logic [31:0]        component_remainder [0:(LANES*2)-1];
    int                 component_code_len [0:(LANES*2)-1];
    int component_count;
    int sample_offset;
    int comp_idx;
    int total_bits;
    int cursor;
    int component_len_int;
    int component_shift_int;
    logic [TOKEN_W-1:0] component_bits;
    begin
      success = 1'b1;
      token_bits = '0;
      token_len = '0;
      total_bits = 0;
      component_count = sample_count * 2;

      for (comp_idx = 0; comp_idx < (LANES * 2); comp_idx = comp_idx + 1) begin
        component_quotient[comp_idx] = 32'd0;
        component_remainder[comp_idx] = 32'd0;
        component_code_len[comp_idx] = 0;
      end

      for (sample_offset = 0; sample_offset < sample_count; sample_offset = sample_offset + 1) begin
        get_component_fields(
          word_data,
          word_idx,
          sample_idx_base + SAMPLE_IDX_W'(sample_offset),
          1'b0,
          codec_mode,
          selected_k,
          prev_i_global,
          prev_q_global,
          residual_s18,
          mapped_u32,
          quotient_u32,
          remainder_u32
        );
        component_quotient[(sample_offset * 2) + 0] = quotient_u32;
        component_remainder[(sample_offset * 2) + 0] = remainder_u32;
        component_code_len[(sample_offset * 2) + 0] = quotient_u32 + 1 + selected_k;
        total_bits = total_bits + component_code_len[(sample_offset * 2) + 0];

        get_component_fields(
          word_data,
          word_idx,
          sample_idx_base + SAMPLE_IDX_W'(sample_offset),
          1'b1,
          codec_mode,
          selected_k,
          prev_i_global,
          prev_q_global,
          residual_s18,
          mapped_u32,
          quotient_u32,
          remainder_u32
        );
        component_quotient[(sample_offset * 2) + 1] = quotient_u32;
        component_remainder[(sample_offset * 2) + 1] = remainder_u32;
        component_code_len[(sample_offset * 2) + 1] = quotient_u32 + 1 + selected_k;
        total_bits = total_bits + component_code_len[(sample_offset * 2) + 1];
      end

      if (total_bits > TOKEN_W) begin
        success = 1'b0;
      end else begin
        token_len = TOKEN_LEN_W'(total_bits);
        cursor = total_bits - 1;
        for (comp_idx = 0; comp_idx < (LANES * 2); comp_idx = comp_idx + 1) begin
          if (comp_idx < component_count) begin
            component_len_int = component_code_len[comp_idx];
            component_shift_int = cursor - component_len_int + 1;
            component_bits = build_component_code_bits(
              component_quotient[comp_idx],
              component_remainder[comp_idx],
              selected_k
            );
            token_bits = token_bits | (component_bits << component_shift_int);
            cursor = cursor - component_len_int;
          end
        end
      end
    end
  endtask

  task automatic build_zero_rem_token(
    input  logic [3:0]             selected_k,
    input  logic [31:0]            mapped_u32,
    output logic [TOKEN_W-1:0]     token_bits,
    output logic [TOKEN_LEN_W-1:0] token_len
  );
    logic [31:0] remainder_u32;
    integer emit_bits_int;
    begin
      token_bits = '0;
      if (selected_k == 4'd0) begin
        remainder_u32 = 32'd0;
      end else begin
        remainder_u32 = mapped_u32 & ((32'd1 << selected_k) - 32'd1);
      end
      emit_bits_int = 1 + selected_k;
      token_bits = TOKEN_W'(remainder_u32 & low_mask_u32(selected_k));
      token_len = TOKEN_LEN_W'(emit_bits_int);
    end
  endtask

  assign codec_supported =
    (codec_mode_reg == MRTC_CODEC_ZERO_RICE) ||
    (codec_mode_reg == MRTC_CODEC_DELTA_RICE);
  assign o_busy                  = (state_reg != ST_IDLE);
  assign o_done                  = (state_reg == ST_DONE);
  assign o_payload_bits_counted  = payload_bits_counted_reg;
  assign o_payload_bytes_counted = payload_bytes_counted_reg;
  assign o_overflow              = overflow_reg | acc_overflow;
  assign o_long_unary_used       = long_unary_used_reg;
  assign o_group_fallback_used   = group_fallback_used_reg;
  generate
    for (genvar component_idx = 0; component_idx < MAX_COMPONENTS; component_idx = component_idx + 1) begin : g_p1_component_len
      assign p1_component_len_comb[component_idx] =
        (p1_valid_reg && (component_idx < p1_component_count_reg)) ?
        ((p1_mapped_reg[component_idx] >> p1_selected_k_reg) +
         COMPONENT_LEN_W'(1) + COMPONENT_LEN_W'(p1_selected_k_reg)) : '0;
    end
    for (genvar pair_idx = 0; pair_idx < COMPONENT_PAIR_TREE_LEAVES; pair_idx = pair_idx + 1) begin : g_p1_pair_len
      if (pair_idx < COMPONENT_PAIR_COUNT) begin : g_active_pair
        if (((pair_idx * 2) + 1) < MAX_COMPONENTS) begin : g_full_pair
          assign p1_pair_len_comb[pair_idx] =
            p1_component_len_comb[pair_idx * 2] +
            p1_component_len_comb[(pair_idx * 2) + 1];
        end else begin : g_single_pair
          assign p1_pair_len_comb[pair_idx] = p1_component_len_comb[pair_idx * 2];
        end
      end else begin : g_padding_pair
        assign p1_pair_len_comb[pair_idx] = '0;
      end
    end

    for (genvar suffix_idx = 0; suffix_idx < MAX_COMPONENTS; suffix_idx = suffix_idx + 1) begin : g_suffix_sum
      assign p2_suffix_l0[suffix_idx] = p2_component_len_reg[suffix_idx];
      if ((suffix_idx + 1) < MAX_COMPONENTS) begin : g_l1_add
        assign p2_suffix_l1[suffix_idx] = p2_suffix_l0[suffix_idx] + p2_suffix_l0[suffix_idx + 1];
      end else begin : g_l1_pass
        assign p2_suffix_l1[suffix_idx] = p2_suffix_l0[suffix_idx];
      end
      if ((suffix_idx + 2) < MAX_COMPONENTS) begin : g_l2_add
        assign p2_suffix_l2[suffix_idx] = p2_suffix_l1[suffix_idx] + p2_suffix_l1[suffix_idx + 2];
      end else begin : g_l2_pass
        assign p2_suffix_l2[suffix_idx] = p2_suffix_l1[suffix_idx];
      end
      if ((suffix_idx + 4) < MAX_COMPONENTS) begin : g_l3_add
        assign p2_suffix_l3[suffix_idx] = p2_suffix_l2[suffix_idx] + p2_suffix_l2[suffix_idx + 4];
      end else begin : g_l3_pass
        assign p2_suffix_l3[suffix_idx] = p2_suffix_l2[suffix_idx];
      end
      if ((suffix_idx + 8) < MAX_COMPONENTS) begin : g_l4_add
        assign p2_suffix_l4[suffix_idx] = p2_suffix_l3[suffix_idx] + p2_suffix_l3[suffix_idx + 8];
      end else begin : g_l4_pass
        assign p2_suffix_l4[suffix_idx] = p2_suffix_l3[suffix_idx];
      end
      if ((suffix_idx + 1) < MAX_COMPONENTS) begin : g_shift_next
        assign p2_component_shift_comb[suffix_idx] = p2_suffix_l4[suffix_idx + 1];
      end else begin : g_shift_zero
        assign p2_component_shift_comb[suffix_idx] = '0;
      end
    end
    for (genvar pair_idx = 0; pair_idx < (COMPONENT_PAIR_TREE_LEAVES/2); pair_idx = pair_idx + 1) begin : g_pair_sum_l1
      assign p2_pair_sum_l1[pair_idx] =
        p2_pair_len_reg[pair_idx * 2] + p2_pair_len_reg[(pair_idx * 2) + 1];
    end
    for (genvar pair_idx = 0; pair_idx < (COMPONENT_PAIR_TREE_LEAVES/4); pair_idx = pair_idx + 1) begin : g_pair_sum_l2
      assign p2_pair_sum_l2[pair_idx] =
        p2_pair_sum_l1[pair_idx * 2] + p2_pair_sum_l1[(pair_idx * 2) + 1];
    end
    for (genvar pair_idx = 0; pair_idx < (COMPONENT_PAIR_TREE_LEAVES/8); pair_idx = pair_idx + 1) begin : g_pair_sum_l3
      assign p2_pair_sum_l3[pair_idx] =
        p2_pair_sum_l2[pair_idx * 2] + p2_pair_sum_l2[(pair_idx * 2) + 1];
    end
  endgenerate

  // Make the wide component assembly topology explicit.  The previous
  // procedural accumulation could become a long OR chain after each dynamic
  // shift; this fixed balanced tree keeps the same disjoint bit placement
  // while reducing logic depth and local routing pressure.
  generate
    for (genvar token_idx = 0; token_idx < TOKEN_OR_LEAVES; token_idx = token_idx + 1) begin : g_token_position
      if (token_idx < MAX_COMPONENTS) begin : g_component
        assign p3a_positioned_bits[token_idx] =
          (p3a_success_reg && (token_idx < p3a_component_count_reg)) ?
          (p3a_component_bits_reg[token_idx] << p3a_component_shift_reg[token_idx]) :
          '0;
      end else begin : g_padding
        assign p3a_positioned_bits[token_idx] = '0;
      end
    end
    for (genvar or_idx = 0; or_idx < (TOKEN_OR_LEAVES/2); or_idx = or_idx + 1) begin : g_token_or_l1
      assign p3a_or_l1[or_idx] =
        p3a_positioned_bits[or_idx * 2] | p3a_positioned_bits[(or_idx * 2) + 1];
    end
  endgenerate
  assign p3b_assembled_bits =
    (p3b_group_bits_reg[0] | p3b_group_bits_reg[1]) |
    (p3b_group_bits_reg[2] | p3b_group_bits_reg[3]);

  assign p2_total_bits_comb = p2_pair_sum_l3[0];
  assign token_accepted          = token_valid_reg && token_ready;
  assign final_token_slot_ready  = !token_valid_reg || token_accepted;
  assign fallback_active         =
    (state_reg == ST_FALLBACK_UNARY) || (state_reg == ST_FALLBACK_ZREM);
  assign p3b_ready               = !p3b_valid_reg ||
                                   (!fallback_active && final_token_slot_ready);
  assign p3p_ready               = !p3p_valid_reg || p3b_ready;
  assign p3a_ready               = !p3a_valid_reg || p3p_ready;
  assign p2s_ready               = !p2s_valid_reg || p3a_ready;
  assign p2_ready                = !p2_valid_reg || p2s_ready;
  assign p1_ready                = !p1_valid_reg || p2_ready;
  assign p1r_ready               = !p1r_valid_reg || p1_ready;
  assign p0_ready                = !p0_valid_reg || p1r_ready;
  assign p3_fallback_pending     = p3b_valid_reg && p3b_ready && !p3b_success_reg;

  assign o_word_rd_req =
    codec_supported &&
    (state_reg != ST_IDLE) &&
    (state_reg != ST_DONE) &&
    (state_reg != ST_WAIT_ACC_DONE) &&
    (issue_word_idx_reg < WORD_COUNT_W'(BLOCK_WORDS)) &&
    ((word_fifo_count_reg + pending_reads_reg) < FIFO_COUNT_W'(WORD_FIFO_DEPTH));
  assign o_word_rd_addr_base = issue_word_idx_reg[WORD_ADDR_W-1:0];

  mrtc_bit_accumulator_axis #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TOKEN_W    (TOKEN_W)
  ) u_bit_accumulator_axis (
    .clk(clk),
    .rst_n(rst_n),
    .s_token_valid(token_valid_reg),
    .s_token_ready(token_ready),
    .s_token_bits(token_bits_reg),
    .s_token_len(token_len_reg),
    .s_token_last(token_last_reg),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid_bytes_minus1(m_axis_tvalid_bytes_minus1),
    .o_busy(),
    .o_done(acc_done),
    .o_overflow(acc_overflow)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    logic [TOKEN_W-1:0]     next_token_bits;
    logic [TOKEN_LEN_W-1:0] next_token_len;
    logic                   issue_read_now;
    logic                   push_word_now;
    logic                   pop_word_now;
    logic                   issue_pipeline_now;
    logic [AXIS_DATA_W-1:0] issue_word_data;
    logic [WORD_ADDR_W-1:0] issue_word_idx;
    logic [SAMPLE_IDX_W-1:0] issue_sample_idx;
    logic [SAMPLE_COUNT_W-1:0] issue_sample_count;
    logic [COMPONENT_COUNT_W-1:0] issue_component_count;
    logic                         issue_token_last;
    logic                         issue_whole_group;
    logic signed [17:0]     residual_s18;
    logic [31:0]            next_payload_bits_u32;
    logic                   current_word_last;
    logic                   current_sample_last;
    logic                   packet_last_sample;
    integer                 comp_idx;
    integer                 sample_offset;
    integer                 component_len_int;
    integer                 emit_bits_int;
    integer                 unary_idx;
    if (!rst_n) begin
      state_reg                 <= ST_IDLE;
      codec_mode_reg            <= 8'd0;
      selected_k_reg            <= 4'd0;
      issue_word_idx_reg        <= '0;
      return_word_idx_reg       <= '0;
      pending_reads_reg         <= '0;
      word_fifo_wr_ptr_reg      <= '0;
      word_fifo_rd_ptr_reg      <= '0;
      word_fifo_count_reg       <= '0;
      current_word_valid_reg    <= 1'b0;
      current_word_idx_reg      <= '0;
      sample_idx_in_word_reg    <= '0;
      sample_stream_mode_reg    <= 1'b0;
      prev_i_global_reg         <= '0;
      prev_q_global_reg         <= '0;
      token_valid_reg           <= 1'b0;
      token_len_reg             <= '0;
      token_last_reg            <= 1'b0;
      p0_valid_reg              <= 1'b0;
      p0_word_idx_reg           <= '0;
      p0_sample_idx_reg         <= '0;
      p0_sample_count_reg       <= '0;
      p0_component_count_reg    <= '0;
      p0_codec_mode_reg         <= 8'd0;
      p0_selected_k_reg         <= 4'd0;
      p0_prev_i_reg             <= 16'sd0;
      p0_prev_q_reg             <= 16'sd0;
      p0_token_last_reg         <= 1'b0;
      p0_whole_group_reg        <= 1'b0;
      p1r_valid_reg             <= 1'b0;
      p1r_component_count_reg   <= '0;
      p1r_selected_k_reg        <= 4'd0;
      p1r_token_last_reg        <= 1'b0;
      p1r_whole_group_reg       <= 1'b0;
      p1_valid_reg              <= 1'b0;
      p1_component_count_reg    <= '0;
      p1_selected_k_reg         <= 4'd0;
      p1_token_last_reg         <= 1'b0;
      p1_whole_group_reg        <= 1'b0;
      p2_valid_reg              <= 1'b0;
      p2_component_count_reg    <= '0;
      p2_selected_k_reg         <= 4'd0;
      p2_token_last_reg         <= 1'b0;
      p2_whole_group_reg        <= 1'b0;
      p2s_valid_reg             <= 1'b0;
      p2s_component_count_reg   <= '0;
      p2s_selected_k_reg        <= 4'd0;
      p2s_token_last_reg        <= 1'b0;
      p2s_whole_group_reg       <= 1'b0;
      p2s_token_len_reg         <= '0;
      p2s_success_reg           <= 1'b0;
      p3a_valid_reg             <= 1'b0;
      p3a_component_count_reg   <= '0;
      p3a_selected_k_reg        <= 4'd0;
      p3a_token_last_reg        <= 1'b0;
      p3a_whole_group_reg       <= 1'b0;
      p3a_token_len_reg         <= '0;
      p3a_success_reg           <= 1'b0;
      p3p_valid_reg             <= 1'b0;
      p3p_component_count_reg   <= '0;
      p3p_token_last_reg        <= 1'b0;
      p3p_token_len_reg         <= '0;
      p3p_success_reg           <= 1'b0;
      p3b_valid_reg             <= 1'b0;
      p3b_component_count_reg   <= '0;
      p3b_token_last_reg        <= 1'b0;
      p3b_token_len_reg         <= '0;
      p3b_success_reg           <= 1'b0;
      payload_bits_counted_reg  <= 32'd0;
      payload_bytes_counted_reg <= 32'd0;
      overflow_reg              <= 1'b0;
      long_unary_used_reg       <= 1'b0;
      group_fallback_used_reg   <= 1'b0;
      fallback_component_is_q_reg  <= 1'b0;
      fallback_unary_remaining_reg <= 32'd0;
      fallback_mapped_reg          <= 32'd0;
      fallback_token_last_reg      <= 1'b0;
      fallback_packet_last_reg     <= 1'b0;
      fallback_selected_k_reg      <= 4'd0;
      fallback_component_idx_reg   <= '0;
      fallback_component_count_reg <= '0;
      fallback_resume_state_reg    <= ST_IDLE;
    end else begin
      issue_read_now = o_word_rd_req;
      push_word_now  = i_word_rd_valid;
      pop_word_now   = 1'b0;
      issue_pipeline_now = 1'b0;
      issue_word_data = current_word_data_reg;
      issue_word_idx = current_word_idx_reg;
      issue_sample_idx = sample_idx_in_word_reg;
      issue_sample_count = SAMPLE_COUNT_W'(1);
      issue_component_count = COMPONENT_COUNT_W'(2);
      issue_token_last = 1'b0;
      issue_whole_group = 1'b0;

      if (acc_overflow) begin
        overflow_reg <= 1'b1;
      end

      if (token_accepted) begin
        token_valid_reg <= 1'b0;
        token_bits_reg  <= '0;
        token_len_reg   <= '0;
        token_last_reg  <= 1'b0;
        next_payload_bits_u32 = payload_bits_counted_reg + 32'(token_len_reg);
        payload_bits_counted_reg  <= next_payload_bits_u32;
        payload_bytes_counted_reg <= (next_payload_bits_u32 + 32'd7) >> 3;
      end

      current_word_last   = (current_word_idx_reg == WORD_ADDR_W'(BLOCK_WORDS - 1));
      current_sample_last = (sample_idx_in_word_reg == SAMPLE_IDX_W'(LANES - 1));
      packet_last_sample  = current_word_last && current_sample_last;

      case (state_reg)
        ST_IDLE: begin
          if (i_start) begin
            state_reg                 <= ST_SETUP;
            codec_mode_reg            <= i_codec_mode;
            selected_k_reg            <= i_selected_k[3:0];
            issue_word_idx_reg        <= '0;
            return_word_idx_reg       <= '0;
            pending_reads_reg         <= '0;
            word_fifo_wr_ptr_reg      <= '0;
            word_fifo_rd_ptr_reg      <= '0;
            word_fifo_count_reg       <= '0;
            current_word_valid_reg    <= 1'b0;
            current_word_data_reg     <= '0;
            current_word_idx_reg      <= '0;
            sample_idx_in_word_reg    <= '0;
            sample_stream_mode_reg    <= 1'b0;
            prev_i_global_reg         <= 16'sd0;
            prev_q_global_reg         <= 16'sd0;
            token_valid_reg           <= 1'b0;
            token_bits_reg            <= '0;
            token_len_reg             <= '0;
            token_last_reg            <= 1'b0;
            p0_valid_reg              <= 1'b0;
            p1r_valid_reg             <= 1'b0;
            p1_valid_reg              <= 1'b0;
            p2_valid_reg              <= 1'b0;
            p2s_valid_reg             <= 1'b0;
            p3a_valid_reg             <= 1'b0;
            p3p_valid_reg             <= 1'b0;
            p3b_valid_reg             <= 1'b0;
            p0_word_data_reg          <= '0;
            p0_sample_idx_reg         <= '0;
            p0_sample_count_reg       <= '0;
            p0_component_count_reg    <= '0;
            p1r_component_count_reg   <= '0;
            p1_component_count_reg    <= '0;
            p2_component_count_reg    <= '0;
            p3a_component_count_reg   <= '0;
            p3p_component_count_reg   <= '0;
            p3b_component_count_reg   <= '0;
            p3a_selected_k_reg        <= 4'd0;
            p3a_token_last_reg        <= 1'b0;
            p3a_whole_group_reg       <= 1'b0;
            p3p_token_last_reg        <= 1'b0;
            p2s_token_len_reg         <= '0;
            p2s_success_reg           <= 1'b0;
            p3a_token_len_reg         <= '0;
            p3a_success_reg           <= 1'b0;
            p3p_token_len_reg         <= '0;
            p3p_success_reg           <= 1'b0;
            p3b_token_len_reg         <= '0;
            p3b_success_reg           <= 1'b0;
            payload_bits_counted_reg  <= 32'd0;
            payload_bytes_counted_reg <= 32'd0;
            overflow_reg              <= 1'b0;
            long_unary_used_reg       <= 1'b0;
            group_fallback_used_reg   <= 1'b0;
            fallback_component_is_q_reg  <= 1'b0;
            fallback_unary_remaining_reg <= 32'd0;
            fallback_mapped_reg          <= 32'd0;
            fallback_token_last_reg      <= 1'b0;
            fallback_packet_last_reg     <= 1'b0;
            fallback_selected_k_reg      <= 4'd0;
            fallback_component_idx_reg   <= '0;
            fallback_component_count_reg <= '0;
            fallback_resume_state_reg    <= ST_IDLE;
          end
        end

        ST_SETUP: begin
          if (codec_supported) begin
            state_reg <= ST_FETCH_WORD;
          end else begin
            state_reg <= ST_DONE;
          end
        end

        ST_FETCH_WORD: begin
          if (!p3_fallback_pending && !current_word_valid_reg && (word_fifo_count_reg != 0)) begin
            pop_word_now           = 1'b1;
            current_word_valid_reg <= 1'b1;
            current_word_data_reg  <= word_fifo_data[word_fifo_rd_ptr_reg];
            current_word_idx_reg   <= word_fifo_idx[word_fifo_rd_ptr_reg];
            sample_idx_in_word_reg <= '0;
            sample_stream_mode_reg <= 1'b0;
            state_reg              <= ST_BUILD_GROUP;
          end
        end

        ST_BUILD_GROUP: begin
          if (current_word_valid_reg && p0_ready && !p3_fallback_pending) begin
            if ((PACKER_LANE_MODE == LANES) &&
                !sample_stream_mode_reg &&
                (sample_idx_in_word_reg == SAMPLE_IDX_W'(0))) begin
              issue_pipeline_now = 1'b1;
              issue_word_data = current_word_data_reg;
              issue_word_idx = current_word_idx_reg;
              issue_sample_idx = SAMPLE_IDX_W'(0);
              issue_sample_count = SAMPLE_COUNT_W'(LANES);
              issue_component_count = COMPONENT_COUNT_W'(LANES * 2);
              issue_token_last = current_word_last;
              issue_whole_group = 1'b1;

              prev_i_global_reg      <= word_lane_i(current_word_data_reg, LANES - 1);
              prev_q_global_reg      <= word_lane_q(current_word_data_reg, LANES - 1);
              current_word_valid_reg <= 1'b0;
              sample_idx_in_word_reg <= '0;
              sample_stream_mode_reg <= 1'b0;
              if (current_word_last) begin
                state_reg <= ST_WAIT_ACC_DONE;
              end else begin
                state_reg <= ST_FETCH_WORD;
              end
            end else begin
              issue_pipeline_now = 1'b1;
              issue_word_data = current_word_data_reg;
              issue_word_idx = current_word_idx_reg;
              issue_sample_idx = sample_idx_in_word_reg;
              issue_sample_count = SAMPLE_COUNT_W'(1);
              issue_component_count = COMPONENT_COUNT_W'(2);
              issue_token_last = packet_last_sample;
              issue_whole_group = 1'b0;

              if (current_sample_last) begin
                prev_i_global_reg      <= word_lane_i(current_word_data_reg, LANES - 1);
                prev_q_global_reg      <= word_lane_q(current_word_data_reg, LANES - 1);
                current_word_valid_reg <= 1'b0;
                sample_idx_in_word_reg <= '0;
                sample_stream_mode_reg <= 1'b0;
                if (current_word_last) begin
                  state_reg <= ST_WAIT_ACC_DONE;
                end else begin
                  state_reg <= ST_FETCH_WORD;
                end
              end else begin
                sample_idx_in_word_reg <= sample_idx_in_word_reg + SAMPLE_IDX_W'(1);
                state_reg              <= ST_BUILD_GROUP;
              end
            end
          end
        end

        ST_WAIT_TOKEN: begin
          state_reg <= ST_FETCH_WORD;
        end

        ST_FALLBACK_UNARY: begin
          if (final_token_slot_ready) begin
            emit_bits_int = (fallback_unary_remaining_reg > TOKEN_W) ? TOKEN_W : fallback_unary_remaining_reg;
            next_token_bits = '0;
            for (unary_idx = 0; unary_idx < TOKEN_W; unary_idx = unary_idx + 1) begin
              if (unary_idx < emit_bits_int) begin
                next_token_bits[unary_idx] = 1'b1;
              end
            end
            token_valid_reg <= 1'b1;
            token_bits_reg  <= next_token_bits;
            token_len_reg   <= TOKEN_LEN_W'(emit_bits_int);
            token_last_reg  <= 1'b0;
            if (fallback_unary_remaining_reg > TOKEN_W) begin
              fallback_unary_remaining_reg <= fallback_unary_remaining_reg - TOKEN_W;
              long_unary_used_reg <= 1'b1;
            end else begin
              fallback_unary_remaining_reg <= 32'd0;
              state_reg <= ST_FALLBACK_ZREM;
            end
          end
        end

        ST_FALLBACK_ZREM: begin
          if (final_token_slot_ready) begin
            build_zero_rem_token(
              fallback_selected_k_reg,
              fallback_mapped_reg,
              next_token_bits,
              next_token_len
            );
            token_valid_reg <= 1'b1;
            token_bits_reg  <= next_token_bits;
            token_len_reg   <= next_token_len;
            token_last_reg  <= fallback_token_last_reg;
            if ((fallback_component_idx_reg + COMPONENT_COUNT_W'(1)) < fallback_component_count_reg) begin
              fallback_component_idx_reg <= fallback_component_idx_reg + COMPONENT_COUNT_W'(1);
              fallback_unary_remaining_reg <=
                fallback_component_quotient_reg[fallback_component_idx_reg + COMPONENT_COUNT_W'(1)];
              fallback_mapped_reg <=
                fallback_component_mapped_reg[fallback_component_idx_reg + COMPONENT_COUNT_W'(1)];
              fallback_token_last_reg <=
                fallback_packet_last_reg &&
                ((fallback_component_idx_reg + COMPONENT_COUNT_W'(2)) == fallback_component_count_reg);
              if (fallback_component_quotient_reg[fallback_component_idx_reg + COMPONENT_COUNT_W'(1)] > TOKEN_W) begin
                long_unary_used_reg <= 1'b1;
              end
              if (fallback_component_quotient_reg[fallback_component_idx_reg + COMPONENT_COUNT_W'(1)] != 0) begin
                state_reg <= ST_FALLBACK_UNARY;
              end else begin
                state_reg <= ST_FALLBACK_ZREM;
              end
            end else begin
              fallback_component_idx_reg <= '0;
              fallback_component_count_reg <= '0;
              fallback_unary_remaining_reg <= 32'd0;
              fallback_mapped_reg <= 32'd0;
              fallback_token_last_reg <= 1'b0;
              fallback_packet_last_reg <= 1'b0;
              state_reg <= fallback_resume_state_reg;
            end
          end
        end

        ST_WAIT_ACC_DONE: begin
          if (acc_done) begin
            state_reg <= ST_DONE;
          end
        end

        ST_DONE: begin
          state_reg <= ST_IDLE;
        end

        default: begin
          state_reg <= ST_IDLE;
        end
      endcase

      // P3B is the final assembly register.  Its four balanced groups feed the
      // elastic token slot directly, avoiding a latency-only copy stage.
      if (p3b_valid_reg && p3b_ready && p3b_success_reg) begin
        token_valid_reg <= 1'b1;
        token_bits_reg  <= p3b_assembled_bits;
        token_len_reg   <= p3b_token_len_reg;
        token_last_reg  <= p3b_token_last_reg;
      end

      if (p3b_valid_reg && p3b_ready && !p3b_success_reg) begin
        if (p3b_component_count_reg > COMPONENT_COUNT_W'(2)) begin
          group_fallback_used_reg <= 1'b1;
        end
        fallback_resume_state_reg <= state_reg;
        fallback_selected_k_reg <= selected_k_reg;
        fallback_component_idx_reg <= '0;
        fallback_component_count_reg <= p3b_component_count_reg;
        fallback_unary_remaining_reg <= p3b_quotient_reg[0];
        fallback_mapped_reg <= p3b_mapped_reg[0];
        fallback_packet_last_reg <= p3b_token_last_reg;
        fallback_token_last_reg <=
          p3b_token_last_reg && (p3b_component_count_reg == COMPONENT_COUNT_W'(1));
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          fallback_component_mapped_reg[comp_idx] <= p3b_mapped_reg[comp_idx];
          fallback_component_quotient_reg[comp_idx] <= p3b_quotient_reg[comp_idx];
        end
        if (p3b_quotient_reg[0] > TOKEN_W) begin
          long_unary_used_reg <= 1'b1;
        end
        if (p3b_quotient_reg[0] != 0) begin
          state_reg <= ST_FALLBACK_UNARY;
        end else begin
          state_reg <= ST_FALLBACK_ZREM;
        end
      end

      // P3B: merge two registered pair partials into each final group.
      if (p3b_ready) begin
        p3b_valid_reg <= p3p_valid_reg;
        p3b_component_count_reg <= p3p_component_count_reg;
        p3b_token_last_reg <= p3p_token_last_reg;
        p3b_token_len_reg <= p3p_token_len_reg;
        p3b_success_reg <= p3p_success_reg;
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p3b_mapped_reg[comp_idx] <= p3p_mapped_reg[comp_idx];
          p3b_quotient_reg[comp_idx] <= p3p_quotient_reg[comp_idx];
        end
        for (comp_idx = 0; comp_idx < 4; comp_idx = comp_idx + 1) begin
          p3b_group_bits_reg[comp_idx] <=
            p3p_pair_bits_reg[comp_idx * 2] |
            p3p_pair_bits_reg[(comp_idx * 2) + 1];
        end
      end

      // P3P: register dynamic-shifted pair partials and fallback metadata.
      if (p3p_ready) begin
        p3p_valid_reg <= p3a_valid_reg;
        p3p_component_count_reg <= p3a_component_count_reg;
        p3p_token_last_reg <= p3a_token_last_reg;
        p3p_token_len_reg <= p3a_token_len_reg;
        p3p_success_reg <= p3a_success_reg;
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p3p_mapped_reg[comp_idx] <= p3a_mapped_reg[comp_idx];
          p3p_quotient_reg[comp_idx] <= p3a_quotient_reg[comp_idx];
        end
        for (comp_idx = 0; comp_idx < (TOKEN_OR_LEAVES/2); comp_idx = comp_idx + 1) begin
          p3p_pair_bits_reg[comp_idx] <= p3a_or_l1[comp_idx];
        end
      end

      // P3A: register component code bits from P2S placement descriptors.
      if (p3a_ready) begin
        p3a_valid_reg <= p2s_valid_reg;
        p3a_component_count_reg <= p2s_component_count_reg;
        p3a_selected_k_reg <= p2s_selected_k_reg;
        p3a_token_last_reg <= p2s_token_last_reg;
        p3a_whole_group_reg <= p2s_whole_group_reg;
        p3a_token_len_reg <= p2s_token_len_reg;
        p3a_success_reg <= p2s_success_reg;
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p3a_mapped_reg[comp_idx] <= p2s_mapped_reg[comp_idx];
          p3a_quotient_reg[comp_idx] <= p2s_quotient_reg[comp_idx];
          p3a_component_bits_reg[comp_idx] <= '0;
          p3a_component_shift_reg[comp_idx] <= p2s_component_shift_reg[comp_idx];
          if (p2s_valid_reg && (comp_idx < p2s_component_count_reg)) begin
            if (p2s_success_reg) begin
              p3a_component_bits_reg[comp_idx] <= build_component_code_bits(
                p2s_quotient_reg[comp_idx],
                p2s_remainder_reg[comp_idx],
                p2s_selected_k_reg
              );
            end
          end
        end
      end

      // P2S: register total length and all placement offsets from the
      // logarithmic-depth suffix tree.
      if (p2s_ready) begin
        p2s_valid_reg <= p2_valid_reg;
        p2s_component_count_reg <= p2_component_count_reg;
        p2s_selected_k_reg <= p2_selected_k_reg;
        p2s_token_last_reg <= p2_token_last_reg;
        p2s_whole_group_reg <= p2_whole_group_reg;
        p2s_token_len_reg <= TOKEN_LEN_W'(p2_total_bits_comb);
        p2s_success_reg <= (p2_total_bits_comb <= GROUP_LEN_W'(TOKEN_W));
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p2s_mapped_reg[comp_idx] <= p2_mapped_reg[comp_idx];
          p2s_quotient_reg[comp_idx] <= p2_quotient_reg[comp_idx];
          p2s_remainder_reg[comp_idx] <= p2_remainder_reg[comp_idx];
          p2s_component_shift_reg[comp_idx] <= TOKEN_LEN_W'(p2_component_shift_comb[comp_idx]);
        end
      end

      // P2: convert mapped values into quotient/remainder and token lengths.
      if (p2_ready) begin
        p2_valid_reg <= p1_valid_reg;
        p2_component_count_reg <= p1_component_count_reg;
        p2_selected_k_reg <= p1_selected_k_reg;
        p2_token_last_reg <= p1_token_last_reg;
        p2_whole_group_reg <= p1_whole_group_reg;
        for (pair_init_idx = 0; pair_init_idx < COMPONENT_PAIR_TREE_LEAVES; pair_init_idx = pair_init_idx + 1) begin
          p2_pair_len_reg[pair_init_idx] <= p1_pair_len_comb[pair_init_idx];
        end
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p2_mapped_reg[comp_idx] <= p1_mapped_reg[comp_idx];
          if (p1_valid_reg && (comp_idx < p1_component_count_reg)) begin
            p2_quotient_reg[comp_idx] <= QUOTIENT_W'(
              p1_mapped_reg[comp_idx] >> p1_selected_k_reg
            );
            p2_remainder_reg[comp_idx] <= REMAINDER_W'(
              (p1_selected_k_reg == 4'd0) ? 32'd0 :
              (p1_mapped_reg[comp_idx] & low_mask_u32(p1_selected_k_reg))
            );
            p2_component_len_reg[comp_idx] <= p1_component_len_comb[comp_idx];
          end else begin
            p2_quotient_reg[comp_idx] <= 32'd0;
            p2_remainder_reg[comp_idx] <= 32'd0;
            p2_component_len_reg[comp_idx] <= 32'd0;
          end
        end
      end

      // P1: map registered residuals to unsigned Rice symbols.
      if (p1_ready) begin
        p1_valid_reg <= p1r_valid_reg;
        p1_component_count_reg <= p1r_component_count_reg;
        p1_selected_k_reg <= p1r_selected_k_reg;
        p1_token_last_reg <= p1r_token_last_reg;
        p1_whole_group_reg <= p1r_whole_group_reg;
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p1_mapped_reg[comp_idx] <= 32'd0;
          if (p1r_valid_reg && (comp_idx < p1r_component_count_reg)) begin
            p1_mapped_reg[comp_idx] <= MAPPED_W'(residual_to_mapped(p1r_residual_reg[comp_idx]));
          end
        end
      end

      // P1R: select the delta predictor and register signed residuals.
      if (p1r_ready) begin
        p1r_valid_reg <= p0_valid_reg;
        p1r_component_count_reg <= p0_component_count_reg;
        p1r_selected_k_reg <= p0_selected_k_reg;
        p1r_token_last_reg <= p0_token_last_reg;
        p1r_whole_group_reg <= p0_whole_group_reg;
        for (comp_idx = 0; comp_idx < MAX_COMPONENTS; comp_idx = comp_idx + 1) begin
          p1r_residual_reg[comp_idx] <= 18'sd0;
        end
        if (p0_valid_reg) begin
          for (sample_offset = 0; sample_offset < LANES; sample_offset = sample_offset + 1) begin
            if (sample_offset < p0_sample_count_reg) begin
              get_component_residual(
                p0_word_data_reg,
                p0_word_idx_reg,
                p0_sample_idx_reg + SAMPLE_IDX_W'(sample_offset),
                1'b0,
                p0_codec_mode_reg,
                p0_prev_i_reg,
                p0_prev_q_reg,
                residual_s18
              );
              p1r_residual_reg[(sample_offset * 2) + 0] <= residual_s18;
              get_component_residual(
                p0_word_data_reg,
                p0_word_idx_reg,
                p0_sample_idx_reg + SAMPLE_IDX_W'(sample_offset),
                1'b1,
                p0_codec_mode_reg,
                p0_prev_i_reg,
                p0_prev_q_reg,
                residual_s18
              );
              p1r_residual_reg[(sample_offset * 2) + 1] <= residual_s18;
            end
          end
        end
      end

      // P0: accept one word/group or one sample from the scheduler.
      if (p0_ready) begin
        p0_valid_reg <= issue_pipeline_now;
        if (issue_pipeline_now) begin
          p0_word_data_reg <= issue_word_data;
          p0_word_idx_reg <= issue_word_idx;
          p0_sample_idx_reg <= issue_sample_idx;
          p0_sample_count_reg <= issue_sample_count;
          p0_component_count_reg <= issue_component_count;
          p0_codec_mode_reg <= codec_mode_reg;
          p0_selected_k_reg <= selected_k_reg;
          p0_prev_i_reg <= prev_i_global_reg;
          p0_prev_q_reg <= prev_q_global_reg;
          p0_token_last_reg <= issue_token_last;
          p0_whole_group_reg <= issue_whole_group;
        end
      end

      if (issue_read_now) begin
        issue_word_idx_reg <= issue_word_idx_reg + WORD_COUNT_W'(1);
      end

      case ({issue_read_now, push_word_now})
        2'b10: pending_reads_reg <= pending_reads_reg + FIFO_COUNT_W'(1);
        2'b01: pending_reads_reg <= pending_reads_reg - FIFO_COUNT_W'(1);
        default: begin
        end
      endcase

      if (push_word_now) begin
        word_fifo_data[word_fifo_wr_ptr_reg] <= i_word_rd_data;
        word_fifo_idx[word_fifo_wr_ptr_reg]  <= return_word_idx_reg[WORD_ADDR_W-1:0];
        word_fifo_wr_ptr_reg <= word_fifo_wr_ptr_reg + FIFO_PTR_W'(1);
        return_word_idx_reg  <= return_word_idx_reg + WORD_COUNT_W'(1);
      end

      if (pop_word_now) begin
        word_fifo_rd_ptr_reg <= word_fifo_rd_ptr_reg + FIFO_PTR_W'(1);
      end

      case ({push_word_now, pop_word_now})
        2'b10: word_fifo_count_reg <= word_fifo_count_reg + FIFO_COUNT_W'(1);
        2'b01: word_fifo_count_reg <= word_fifo_count_reg - FIFO_COUNT_W'(1);
        default: begin
        end
      endcase
    end
  end
endmodule
