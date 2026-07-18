module mrtc_rdtc_decoder_top #(
  parameter int I_W = mrtc_pkg::MRTC_I_W,
  parameter int Q_W = mrtc_pkg::MRTC_Q_W,
  parameter int COMPLEX_SAMPLE_W = I_W + Q_W,
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int COMP_BLOCK_BYTES = mrtc_pkg::MRTC_COMP_BLOCK_BYTES,
  parameter int COMPLEX_SAMPLES_PER_BLOCK =
    COMP_BLOCK_BYTES / (COMPLEX_SAMPLE_W / 8)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,
  input  logic [AXIS_DATA_W-1:0] s_axis_comp_tdata,
  input  logic                   s_axis_comp_tvalid,
  output logic                   s_axis_comp_tready,
  input  logic                   s_axis_comp_tlast,
  input  logic [7:0]             s_axis_comp_tuser,
  output logic [AXIS_DATA_W-1:0] m_axis_raw_tdata,
  output logic                   m_axis_raw_tvalid,
  input  logic                   m_axis_raw_tready,
  output logic                   m_axis_raw_tlast,
  output logic [7:0]             m_axis_raw_tuser,
  output logic                   stat_busy,
  output logic                   stat_done,
  output logic [31:0]            stat_comp_bytes,
  output logic [31:0]            stat_raw_bytes,
  output logic [31:0]            stat_num_blocks,
  output logic [31:0]            stat_error,
  output logic [31:0]            stat_error_blocks,
  output logic [31:0]            stat_stall_input_cycles,
  output logic [31:0]            stat_stall_output_cycles
);
  import mrtc_pkg::*;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int BLOCK_BEATS = COMP_BLOCK_BYTES / AXIS_BYTES;
  localparam int STREAM_VALID_BYTE_W = $clog2(AXIS_BYTES + 1);
  localparam int STREAM_WORD_IDX_W = (BLOCK_BEATS <= 1) ? 1 : $clog2(BLOCK_BEATS);
  localparam int STREAM_WORD_COUNT_W = $clog2(BLOCK_BEATS + 1);
  localparam int I_W_CHECK = 1 / ((I_W == 16) ? 1 : 0);
  localparam int Q_W_CHECK = 1 / ((Q_W == 16) ? 1 : 0);
  localparam int COMPLEX_SAMPLE_W_CHECK = 1 / ((COMPLEX_SAMPLE_W == 32) ? 1 : 0);
  localparam int PHASE_CHECK =
    1 / (((PHASES_PER_BEAT == 2) ||
          (PHASES_PER_BEAT == 4) ||
          (PHASES_PER_BEAT == 8)) ? 1 : 0);
  localparam int AXIS_CHECK = 1 / ((AXIS_DATA_W == (COMPLEX_SAMPLE_W * PHASES_PER_BEAT)) ? 1 : 0);
  localparam int COMP_BLOCK_BYTES_CHECK = 1 / ((COMP_BLOCK_BYTES == 4096) ? 1 : 0);
  localparam int COMPLEX_SAMPLES_PER_BLOCK_CHECK =
    1 / ((COMPLEX_SAMPLES_PER_BLOCK == 1024) ? 1 : 0);
  localparam int BLOCK_ALIGN_CHECK = 1 / (((COMP_BLOCK_BYTES % AXIS_BYTES) == 0) ? 1 : 0);
  localparam int RAW_TUSER_WIDTH_CHECK = 1 / ((AXIS_BYTES <= 16) ? 1 : 0);

  typedef enum logic [2:0] {
    ST_CAPTURE     = 3'd0,
    ST_PARSE       = 3'd1,
    ST_DECODE_RAW  = 3'd2,
    ST_DECODE_RICE = 3'd3,
    ST_STREAM      = 3'd4,
    ST_ADVANCE     = 3'd5
  } state_t;

  state_t state_reg;

  logic [7:0] beat_bytes [0:AXIS_BYTES-1];

  logic [7:0] comp_mem [0:MRTC_MAX_OUTPUT_BYTES-1];
  logic [31:0] sample_mem [0:COMPLEX_SAMPLES_PER_BLOCK-1];
  logic [(MRTC_HEADER_BYTES*8)-1:0]      header_bytes_flat;
  logic [(MRTC_MAX_PAYLOAD_BYTES*8)-1:0] payload_mem_flat;
  logic [(COMPLEX_SAMPLES_PER_BLOCK*32)-1:0] sample_mem_flat;

  logic [31:0] comp_byte_count_reg;
  logic [31:0] cap_valid_bytes;
  logic [31:0] cap_next_count;
  logic        comp_beat_accept;

  logic [15:0] hdr_frame_id;
  logic [15:0] hdr_block_id;
  logic [15:0] hdr_tensor_spatial_size;
  logic [15:0] hdr_tensor_doppler_size;
  logic [15:0] hdr_tensor_range_size;
  logic [15:0] hdr_block_spatial_start;
  logic [15:0] hdr_block_doppler_start;
  logic [15:0] hdr_block_range_start;
  logic [7:0]  hdr_block_spatial_len;
  logic [7:0]  hdr_block_doppler_len;
  logic [15:0] hdr_block_range_len;
  logic [7:0]  hdr_sample_format;
  logic [7:0]  hdr_codec_mode;
  logic [7:0]  hdr_predictor_mode;
  logic [7:0]  hdr_rice_k;
  logic [15:0] hdr_flags;
  logic [31:0] hdr_raw_bytes;
  logic [31:0] hdr_payload_bytes;
  logic [31:0] hdr_payload_bits;
  logic [31:0] hdr_crc32;
  logic        hdr_is_raw_mode;
  logic [31:0] hdr_error;

  logic [10:0] num_samples_reg;
  logic [STREAM_WORD_IDX_W-1:0] stream_word_idx_reg;
  logic [10:0] decode_sample_idx_reg;
  logic        decode_channel_reg;
  logic        active_sample_major_iq_reg;
  logic signed [15:0] decode_prev_sample_reg;
  logic signed [15:0] decode_prev_i_reg;
  logic signed [15:0] decode_prev_q_reg;
  logic signed [15:0] decode_curr_i_reg;
  logic [31:0] bit_pos_reg;
  logic [31:0] active_payload_bits_limit_reg;
  logic [7:0]  active_codec_mode_reg;
  logic [7:0]  active_rice_k_reg;
  logic        active_last_block_reg;
  logic        active_stream_length_reg;

  logic [31:0] rice_mapped;
  logic [31:0] rice_next_bit_pos;
  logic        rice_payload_exhausted;
  logic        rice_structural_error;
  logic signed [15:0] rice_decoded_sample;
  logic        rice_decode_error;

  logic [AXIS_DATA_W-1:0] stream_tdata;
  logic [STREAM_VALID_BYTE_W-1:0] stream_valid_bytes;
  logic [STREAM_WORD_COUNT_W-1:0] total_words;
  logic         stream_handshake;

  integer byte_idx;

  assign comp_beat_accept  = s_axis_comp_tvalid && s_axis_comp_tready;
  assign s_axis_comp_tready = (state_reg == ST_CAPTURE);
  assign cap_valid_bytes   = s_axis_comp_tlast ? ({28'd0, s_axis_comp_tuser[3:0]} + 32'd1) : AXIS_BYTES;
  assign cap_next_count    = comp_byte_count_reg + cap_valid_bytes;
  assign total_words       = STREAM_WORD_COUNT_W'((num_samples_reg + PHASES_PER_BEAT - 1) /
                                                  PHASES_PER_BEAT);
  assign stream_handshake  = m_axis_raw_tvalid && m_axis_raw_tready;
  assign stat_busy         = (state_reg != ST_CAPTURE) || (comp_byte_count_reg != 0);

  generate
    genvar beat_idx;
    for (beat_idx = 0; beat_idx < AXIS_BYTES; beat_idx = beat_idx + 1) begin : g_beat_bytes
      assign beat_bytes[beat_idx] = s_axis_comp_tdata[(beat_idx * 8) +: 8];
    end

    genvar header_idx;
    for (header_idx = 0; header_idx < MRTC_HEADER_BYTES; header_idx = header_idx + 1) begin : g_header_flat
      assign header_bytes_flat[(header_idx*8) +: 8] = comp_mem[header_idx];
    end

    genvar payload_idx;
    for (payload_idx = 0; payload_idx < MRTC_MAX_PAYLOAD_BYTES; payload_idx = payload_idx + 1) begin : g_payload_flat
      assign payload_mem_flat[(payload_idx*8) +: 8] = comp_mem[MRTC_HEADER_BYTES + payload_idx];
    end

    genvar sample_idx;
    for (sample_idx = 0; sample_idx < COMPLEX_SAMPLES_PER_BLOCK; sample_idx = sample_idx + 1) begin : g_sample_flat
      assign sample_mem_flat[(sample_idx*32) +: 32] = sample_mem[sample_idx];
    end
  endgenerate

  mrtc_header_parser #(
    .HEADER_BYTES(MRTC_HEADER_BYTES),
    .MAX_PAYLOAD_BYTES(MRTC_MAX_PAYLOAD_BYTES)
  ) u_header_parser (
    .i_header_bytes_flat  (header_bytes_flat),
    .i_captured_bytes     (comp_byte_count_reg),
    .o_frame_id           (hdr_frame_id),
    .o_block_id           (hdr_block_id),
    .o_tensor_spatial_size(hdr_tensor_spatial_size),
    .o_tensor_doppler_size(hdr_tensor_doppler_size),
    .o_tensor_range_size  (hdr_tensor_range_size),
    .o_block_spatial_start(hdr_block_spatial_start),
    .o_block_doppler_start(hdr_block_doppler_start),
    .o_block_range_start  (hdr_block_range_start),
    .o_block_spatial_len  (hdr_block_spatial_len),
    .o_block_doppler_len  (hdr_block_doppler_len),
    .o_block_range_len    (hdr_block_range_len),
    .o_sample_format      (hdr_sample_format),
    .o_codec_mode         (hdr_codec_mode),
    .o_predictor_mode     (hdr_predictor_mode),
    .o_rice_k             (hdr_rice_k),
    .o_flags              (hdr_flags),
    .o_raw_bytes          (hdr_raw_bytes),
    .o_payload_bytes      (hdr_payload_bytes),
    .o_payload_bits       (hdr_payload_bits),
    .o_crc32              (hdr_crc32),
    .o_is_raw_mode        (hdr_is_raw_mode),
    .o_error              (hdr_error)
  );

  mrtc_rice_bitreader #(
    .MAX_PAYLOAD_BYTES(MRTC_MAX_PAYLOAD_BYTES)
  ) u_rice_bitreader (
    .i_payload_flat (payload_mem_flat),
    .i_payload_bits (active_payload_bits_limit_reg),
    .i_start_bit_pos(bit_pos_reg),
    .i_rice_k       (active_rice_k_reg),
    .o_mapped            (rice_mapped),
    .o_next_bit_pos      (rice_next_bit_pos),
    .o_payload_exhausted (rice_payload_exhausted),
    .o_structural_error  (rice_structural_error)
  );

  mrtc_rice_decoder u_rice_decoder (
    .i_codec_mode     (active_codec_mode_reg),
    .i_prev_sample    (active_sample_major_iq_reg
                        ? (decode_channel_reg ? decode_prev_q_reg : decode_prev_i_reg)
                        : decode_prev_sample_reg),
    .i_mapped         (rice_mapped),
    .i_is_first_sample(decode_sample_idx_reg == 0),
    .o_sample         (rice_decoded_sample),
    .o_error          (rice_decode_error)
  );

  mrtc_raw_output_packer #(
    .PHASES_PER_BEAT(PHASES_PER_BEAT),
    .AXIS_DATA_W     (AXIS_DATA_W),
    .BLOCK_SAMPLES   (COMPLEX_SAMPLES_PER_BLOCK)
  ) u_raw_output_packer (
    .i_sample_mem_flat(sample_mem_flat),
    .i_word_idx   (stream_word_idx_reg),
    .i_num_samples(num_samples_reg),
    .o_tdata      (stream_tdata),
    .o_valid_bytes(stream_valid_bytes)
  );

  assign m_axis_raw_tdata  = stream_tdata;
  assign m_axis_raw_tvalid = (state_reg == ST_STREAM);
  assign m_axis_raw_tlast  = (state_reg == ST_STREAM) &&
                             (stream_word_idx_reg ==
                              STREAM_WORD_IDX_W'(total_words - STREAM_WORD_COUNT_W'(1)));

  always_comb begin
    m_axis_raw_tuser = 8'd0;
    if (state_reg == ST_STREAM) begin
      if (m_axis_raw_tlast) begin
        if (stream_valid_bytes == 0) begin
          m_axis_raw_tuser[3:0] = 4'd0;
        end else begin
          m_axis_raw_tuser[3:0] = stream_valid_bytes[3:0] - 4'd1;
        end
      end
      if (stream_word_idx_reg == 0) begin
        m_axis_raw_tuser[4] = 1'b1;
      end
      if (active_last_block_reg) begin
        m_axis_raw_tuser[5] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_reg               <= ST_CAPTURE;
      comp_byte_count_reg     <= 32'd0;
      stream_word_idx_reg     <= '0;
      decode_sample_idx_reg   <= 11'd0;
      decode_channel_reg      <= 1'b0;
      active_sample_major_iq_reg <= 1'b0;
      decode_prev_sample_reg  <= 16'sd0;
      decode_prev_i_reg       <= 16'sd0;
      decode_prev_q_reg       <= 16'sd0;
      decode_curr_i_reg       <= 16'sd0;
      bit_pos_reg             <= 32'd0;
      active_payload_bits_limit_reg <= 32'd0;
      num_samples_reg         <= 11'd0;
      active_codec_mode_reg   <= MRTC_CODEC_RAW;
      active_rice_k_reg       <= 8'd0;
      active_last_block_reg   <= 1'b0;
      active_stream_length_reg<= 1'b0;
      stat_done               <= 1'b0;
      stat_comp_bytes         <= 32'd0;
      stat_raw_bytes          <= 32'd0;
      stat_num_blocks         <= 32'd0;
      stat_error_blocks       <= 32'd0;
      stat_stall_input_cycles <= 32'd0;
      stat_stall_output_cycles<= 32'd0;
      stat_error              <= MRTC_ERR_NONE;
    end else begin
      stat_done <= 1'b0;
      if (i_clear_status) begin
        stat_error <= MRTC_ERR_NONE;
        stat_comp_bytes <= 32'd0;
        stat_raw_bytes <= 32'd0;
        stat_num_blocks <= 32'd0;
        stat_error_blocks <= 32'd0;
        stat_stall_input_cycles <= 32'd0;
        stat_stall_output_cycles <= 32'd0;
      end

      if (s_axis_comp_tvalid && !s_axis_comp_tready) begin
        stat_stall_input_cycles <= stat_stall_input_cycles + 32'd1;
      end
      if (m_axis_raw_tvalid && !m_axis_raw_tready) begin
        stat_stall_output_cycles <= stat_stall_output_cycles + 32'd1;
      end

      case (state_reg)
        ST_CAPTURE: begin
          stream_word_idx_reg <= '0;
          if (comp_beat_accept) begin
            for (byte_idx = 0; byte_idx < AXIS_BYTES; byte_idx = byte_idx + 1) begin
              if (byte_idx < cap_valid_bytes) begin
                comp_mem[comp_byte_count_reg + 32'(byte_idx)] <= beat_bytes[byte_idx];
              end
            end
            comp_byte_count_reg <= cap_next_count;
            if (s_axis_comp_tlast) begin
              state_reg <= ST_PARSE;
            end
          end
        end

        ST_PARSE: begin
          if (hdr_error != MRTC_ERR_NONE) begin
            stat_error <= hdr_error;
            stat_comp_bytes <= comp_byte_count_reg;
            stat_raw_bytes <= 32'd0;
            stat_error_blocks <= stat_error_blocks + 32'd1;
            state_reg <= ST_ADVANCE;
          end else begin
            num_samples_reg       <= hdr_raw_bytes[12:2];
            decode_sample_idx_reg <= 11'd0;
            decode_channel_reg    <= 1'b0;
            active_sample_major_iq_reg <= ((hdr_flags & MRTC_FLAG_SAMPLE_MAJOR_IQ) != 0);
            decode_prev_sample_reg<= 16'sd0;
            decode_prev_i_reg     <= 16'sd0;
            decode_prev_q_reg     <= 16'sd0;
            decode_curr_i_reg     <= 16'sd0;
            bit_pos_reg           <= 32'd0;
            if ((hdr_flags & MRTC_FLAG_STREAM_LENGTH_BY_TLAST) != 0) begin
              active_payload_bits_limit_reg <= (comp_byte_count_reg - MRTC_HEADER_BYTES) << 3;
            end else begin
              active_payload_bits_limit_reg <= hdr_payload_bits;
            end
            active_codec_mode_reg <= hdr_codec_mode;
            active_rice_k_reg     <= hdr_rice_k;
            active_last_block_reg <= ((hdr_flags & MRTC_FLAG_LAST_BLOCK) != 0);
            active_stream_length_reg <= ((hdr_flags & MRTC_FLAG_STREAM_LENGTH_BY_TLAST) != 0);
            if (hdr_is_raw_mode) begin
              state_reg <= ST_DECODE_RAW;
            end else begin
              state_reg <= ST_DECODE_RICE;
            end
          end
        end

        ST_DECODE_RAW: begin
          sample_mem[decode_sample_idx_reg] <= {
            comp_mem[MRTC_HEADER_BYTES + (decode_sample_idx_reg * 4) + 3],
            comp_mem[MRTC_HEADER_BYTES + (decode_sample_idx_reg * 4) + 2],
            comp_mem[MRTC_HEADER_BYTES + (decode_sample_idx_reg * 4) + 1],
            comp_mem[MRTC_HEADER_BYTES + (decode_sample_idx_reg * 4)]
          };
          if (decode_sample_idx_reg + 11'd1 >= num_samples_reg) begin
            stream_word_idx_reg <= '0;
            state_reg <= ST_STREAM;
          end else begin
            decode_sample_idx_reg <= decode_sample_idx_reg + 11'd1;
          end
        end

        ST_DECODE_RICE: begin
          if (rice_payload_exhausted) begin
            stat_error <= MRTC_ERR_PAYLOAD_BITS_SHORT;
            stat_comp_bytes <= comp_byte_count_reg;
            stat_raw_bytes <= hdr_raw_bytes;
            stat_error_blocks <= stat_error_blocks + 32'd1;
            state_reg <= ST_ADVANCE;
          end else if (rice_structural_error) begin
            stat_error <= MRTC_ERR_RICE_TRUNCATED;
            stat_comp_bytes <= comp_byte_count_reg;
            stat_raw_bytes <= hdr_raw_bytes;
            stat_error_blocks <= stat_error_blocks + 32'd1;
            state_reg <= ST_ADVANCE;
          end else if (rice_decode_error) begin
            stat_error <= MRTC_ERR_SAMPLE_RANGE;
            stat_comp_bytes <= comp_byte_count_reg;
            stat_raw_bytes <= hdr_raw_bytes;
            stat_error_blocks <= stat_error_blocks + 32'd1;
            state_reg <= ST_ADVANCE;
          end else begin
            bit_pos_reg <= rice_next_bit_pos;
            if (active_sample_major_iq_reg) begin
              if (!decode_channel_reg) begin
                sample_mem[decode_sample_idx_reg][15:0] <= $unsigned(rice_decoded_sample);
                decode_curr_i_reg <= rice_decoded_sample;
                decode_channel_reg <= 1'b1;
              end else begin
                sample_mem[decode_sample_idx_reg][31:16] <= $unsigned(rice_decoded_sample);
                decode_prev_i_reg <= decode_curr_i_reg;
                decode_prev_q_reg <= rice_decoded_sample;
                decode_channel_reg <= 1'b0;
                if (decode_sample_idx_reg + 11'd1 >= num_samples_reg) begin
                  stream_word_idx_reg <= '0;
                  state_reg <= ST_STREAM;
                end else begin
                  decode_sample_idx_reg <= decode_sample_idx_reg + 11'd1;
                end
              end
            end else begin
              if (!decode_channel_reg) begin
                sample_mem[decode_sample_idx_reg][15:0] <= $unsigned(rice_decoded_sample);
              end else begin
                sample_mem[decode_sample_idx_reg][31:16] <= $unsigned(rice_decoded_sample);
              end
              if (decode_sample_idx_reg + 11'd1 >= num_samples_reg) begin
                if (!decode_channel_reg) begin
                  decode_channel_reg <= 1'b1;
                  decode_sample_idx_reg <= 11'd0;
                  decode_prev_sample_reg <= 16'sd0;
                end else begin
                  stream_word_idx_reg <= '0;
                  state_reg <= ST_STREAM;
                end
              end else begin
                decode_sample_idx_reg <= decode_sample_idx_reg + 11'd1;
                decode_prev_sample_reg <= rice_decoded_sample;
              end
            end
          end
        end

        ST_STREAM: begin
          if (stream_handshake) begin
            if (m_axis_raw_tlast) begin
              stat_done <= 1'b1;
              stat_comp_bytes <= comp_byte_count_reg;
              stat_raw_bytes <= hdr_raw_bytes;
              stat_num_blocks <= stat_num_blocks + 32'd1;
              state_reg <= ST_ADVANCE;
            end else begin
              stream_word_idx_reg <= stream_word_idx_reg + STREAM_WORD_IDX_W'(1);
            end
          end
        end

        ST_ADVANCE: begin
          comp_byte_count_reg   <= 32'd0;
          stream_word_idx_reg   <= '0;
          decode_sample_idx_reg <= 11'd0;
          decode_channel_reg    <= 1'b0;
          active_sample_major_iq_reg <= 1'b0;
          decode_prev_sample_reg<= 16'sd0;
          decode_prev_i_reg     <= 16'sd0;
          decode_prev_q_reg     <= 16'sd0;
          decode_curr_i_reg     <= 16'sd0;
          bit_pos_reg           <= 32'd0;
          active_payload_bits_limit_reg <= 32'd0;
          num_samples_reg       <= 11'd0;
          active_codec_mode_reg <= MRTC_CODEC_RAW;
          active_rice_k_reg     <= 8'd0;
          active_last_block_reg <= 1'b0;
          active_stream_length_reg <= 1'b0;
          state_reg             <= ST_CAPTURE;
        end

        default: begin
          stat_error <= MRTC_ERR_INTERNAL_STATE;
          stat_error_blocks <= stat_error_blocks + 32'd1;
          state_reg <= ST_CAPTURE;
        end
      endcase
    end
  end
endmodule
