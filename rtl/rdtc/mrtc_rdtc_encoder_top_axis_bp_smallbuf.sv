module mrtc_rdtc_encoder_top_axis_bp_smallbuf #(
  parameter int I_W = mrtc_pkg::MRTC_I_W,
  parameter int Q_W = mrtc_pkg::MRTC_Q_W,
  parameter int COMPLEX_SAMPLE_W = I_W + Q_W,
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int COMP_BLOCK_BYTES = mrtc_pkg::MRTC_COMP_BLOCK_BYTES,
  parameter int PREFIX_COMPLEX_SAMPLES = mrtc_pkg::MRTC_PREFIX_COMPLEX_SAMPLES,
  parameter int PREFIX_SAMPLES = PREFIX_COMPLEX_SAMPLES,
  parameter bit ENABLE_INTERNAL_RAW_BYPASS = 1'b0
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,
  input  logic [AXIS_DATA_W-1:0] s_axis_raw_tdata,
  input  logic                   s_axis_raw_tvalid,
  output logic                   s_axis_raw_tready,
  input  logic                   s_axis_raw_tlast,
  input  logic [7:0]             s_axis_raw_tuser,
  output logic [AXIS_DATA_W-1:0] m_axis_comp_tdata,
  output logic                   m_axis_comp_tvalid,
  input  logic                   m_axis_comp_tready,
  output logic                   m_axis_comp_tlast,
  output logic [7:0]             m_axis_comp_tuser,
  input  logic [7:0]             cfg_codec_mode,
  input  logic [7:0]             cfg_rice_mode,
  input  logic [3:0]             cfg_fixed_k,
  input  logic [15:0]            cfg_frame_id,
  input  logic [15:0]            cfg_block_id_base,
  input  logic [15:0]            cfg_tensor_spatial_size,
  input  logic [15:0]            cfg_tensor_doppler_size,
  input  logic [15:0]            cfg_tensor_range_size,
  output logic                   stat_busy,
  output logic                   stat_done,
  output logic [31:0]            stat_raw_bytes,
  output logic [31:0]            stat_comp_bytes,
  output logic [31:0]            stat_num_blocks,
  output logic [31:0]            stat_error,
  output logic [31:0]            stat_raw_bypass_blocks,
  output logic [31:0]            stat_stall_input_cycles,
  output logic [31:0]            stat_stall_output_cycles
);
  import mrtc_pkg::*;

  localparam int LANES = PHASES_PER_BEAT;
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int COMPLEX_SAMPLES_PER_BLOCK = COMP_BLOCK_BYTES / (COMPLEX_SAMPLE_W / 8);
  localparam int BLOCK_BEATS = COMP_BLOCK_BYTES / AXIS_BYTES;
  localparam int PREFIX_BEATS = PREFIX_COMPLEX_SAMPLES / LANES;
  localparam int BLOCK_WORDS = BLOCK_BEATS;
  localparam int PREFIX_WORDS = PREFIX_BEATS;
  localparam int WORD_ADDR_W = $clog2(BLOCK_WORDS);
  localparam int PREFIX_ADDR_W = $clog2(PREFIX_WORDS);
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);
  localparam int SUFFIX_PENDING_W = 4;
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
  localparam int PREFIX_COMPAT_CHECK = 1 / ((PREFIX_SAMPLES == PREFIX_COMPLEX_SAMPLES) ? 1 : 0);
  localparam int PREFIX_ALIGN_CHECK = 1 / (((PREFIX_COMPLEX_SAMPLES % PHASES_PER_BEAT) == 0) ? 1 : 0);
  localparam int OUTPUT_TUSER_WIDTH_CHECK = 1 / ((AXIS_BYTES <= 16) ? 1 : 0);
  localparam int RAW_BYPASS_CHECK = 1 / ((ENABLE_INTERNAL_RAW_BYPASS == 1'b0) ? 1 : 0);

  typedef enum logic [3:0] {
    ST_IDLE           = 4'd0,
    ST_CAPTURE_PREFIX = 4'd1,
    ST_K_WAIT         = 4'd2,
    ST_HEADER         = 4'd3,
    ST_BPACK_START    = 4'd4,
    ST_PAYLOAD        = 4'd5,
    ST_DONE           = 4'd6,
    ST_ERROR          = 4'd7
  } state_t;

  state_t state_reg;

  logic [WORD_ADDR_W:0] input_word_count_reg;
  logic [SUFFIX_PENDING_W-1:0] suffix_pending_count_reg;
  logic [7:0] block_codec_mode_reg;
  logic block_last_reg;
  logic [15:0] block_id_reg;
  logic [15:0] frame_id_reg;
  logic [15:0] tensor_spatial_size_reg;
  logic [15:0] tensor_doppler_size_reg;
  logic [15:0] tensor_range_size_reg;

  logic [7:0] selected_k_reg;
  logic [31:0] prefix_bits_reg;
  logic [31:0] bpack_payload_bits_counted;
  logic [31:0] bpack_payload_bytes_counted;
  logic bpack_overflow;
  logic lane_bpack_long_unary_used;
  logic lane_bpack_group_fallback_used;

  logic raw_beat_accept;
  logic prefix_capture_active;
  logic suffix_accept;
  logic suffix_request_issue;
  logic prefix_request_issue;
  logic output_beat_accept;

  logic accum_start;
  logic accum_word_valid;
  logic accum_ready;
  logic accum_busy;
  logic accum_done;
  logic [7:0] accum_selected_k;
  logic [31:0] accum_prefix_bits;
  logic accum_unsupported_codec;

  logic prefix_wr_en;
  logic [PREFIX_ADDR_W-1:0] prefix_wr_addr;
  logic [AXIS_DATA_W-1:0] prefix_wr_data;
  logic prefix_rd_en;
  logic [PREFIX_ADDR_W-1:0] prefix_rd_addr;
  logic prefix_rd_valid;
  logic [AXIS_DATA_W-1:0] prefix_rd_data;

  logic [(MRTC_HEADER_BYTES*8)-1:0] header_bytes_flat;
  logic [15:0] header_flags;
  logic header_start_reg;
  logic header_busy;
  logic header_done;
  logic [AXIS_DATA_W-1:0] header_axis_tdata;
  logic header_axis_tvalid;
  logic header_axis_tready;
  logic header_axis_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] header_axis_tvalid_bytes_minus1;

  logic bpack_start_reg;
  logic bpack_word_rd_req;
  logic [WORD_ADDR_W-1:0] bpack_word_rd_addr;
  logic bpack_word_rd_valid;
  logic [AXIS_DATA_W-1:0] bpack_word_rd_data;
  logic [AXIS_DATA_W-1:0] bpack_axis_tdata;
  logic bpack_axis_tvalid;
  logic bpack_axis_tready;
  logic bpack_axis_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] bpack_axis_tvalid_bytes_minus1;
  logic bpack_busy;
  logic bpack_done;

  logic [31:0] output_valid_bytes_u32;

  assign prefix_capture_active =
    (state_reg == ST_IDLE) || (state_reg == ST_CAPTURE_PREFIX);
  assign raw_beat_accept = s_axis_raw_tvalid && s_axis_raw_tready;
  assign suffix_accept = (state_reg == ST_PAYLOAD) &&
                         (suffix_pending_count_reg != '0) &&
                         !prefix_rd_valid &&
                         s_axis_raw_tvalid &&
                         s_axis_raw_tready;

  always_comb begin
    s_axis_raw_tready = 1'b0;
    if (state_reg == ST_IDLE) begin
      s_axis_raw_tready = 1'b1;
    end else if (state_reg == ST_CAPTURE_PREFIX) begin
      s_axis_raw_tready = accum_ready && (input_word_count_reg < WORD_ADDR_W'(PREFIX_WORDS));
    end else if (state_reg == ST_PAYLOAD) begin
      s_axis_raw_tready = (suffix_pending_count_reg != '0) && !prefix_rd_valid;
    end
  end

  assign accum_start = raw_beat_accept && (state_reg == ST_IDLE);
  assign accum_word_valid = raw_beat_accept && prefix_capture_active &&
                            (input_word_count_reg < WORD_ADDR_W'(PREFIX_WORDS));

  assign prefix_wr_en = accum_word_valid;
  assign prefix_wr_addr = input_word_count_reg[PREFIX_ADDR_W-1:0];
  assign prefix_wr_data = s_axis_raw_tdata;

  assign prefix_request_issue =
    (state_reg == ST_PAYLOAD) &&
    bpack_word_rd_req &&
    (bpack_word_rd_addr < WORD_ADDR_W'(PREFIX_WORDS));

  assign suffix_request_issue =
    (state_reg == ST_PAYLOAD) &&
    bpack_word_rd_req &&
    (bpack_word_rd_addr >= WORD_ADDR_W'(PREFIX_WORDS));

  assign prefix_rd_en = prefix_request_issue;
  assign prefix_rd_addr = bpack_word_rd_addr[PREFIX_ADDR_W-1:0];

  assign bpack_word_rd_valid = prefix_rd_valid || suffix_accept;
  assign bpack_word_rd_data = prefix_rd_valid ? prefix_rd_data : s_axis_raw_tdata;

  always_comb begin
    header_flags = MRTC_FLAG_SAMPLE_MAJOR_IQ |
                   MRTC_FLAG_PREFIX_K_FAST |
                   MRTC_FLAG_STREAM_LENGTH_BY_TLAST;
    if (block_last_reg) begin
      header_flags = header_flags | MRTC_FLAG_LAST_BLOCK;
    end
  end

  mrtc_prefix_sample_buffer #(
    .AXIS_DATA_W (AXIS_DATA_W),
    .PREFIX_WORDS(PREFIX_WORDS)
  ) u_prefix_sample_buffer (
    .clk       (clk),
    .rst_n     (rst_n),
    .i_wr_en   (prefix_wr_en),
    .i_wr_addr (prefix_wr_addr),
    .i_wr_data (prefix_wr_data),
    .i_rd_en   (prefix_rd_en),
    .i_rd_addr (prefix_rd_addr),
    .o_rd_valid(prefix_rd_valid),
    .o_rd_data (prefix_rd_data)
  );

  mrtc_prefix_k_accum_stream #(
    .PHASES_PER_BEAT        (PHASES_PER_BEAT),
    .AXIS_DATA_W            (AXIS_DATA_W),
    .PREFIX_COMPLEX_SAMPLES (PREFIX_COMPLEX_SAMPLES)
  ) u_prefix_k_accum_stream (
    .clk                (clk),
    .rst_n              (rst_n),
    .i_start            (accum_start),
    .i_codec_mode       ({6'd0, s_axis_raw_tuser[2:1]}),
    .i_word_valid       (accum_word_valid),
    .i_word_data        (s_axis_raw_tdata),
    .o_ready            (accum_ready),
    .o_busy             (accum_busy),
    .o_done             (accum_done),
    .o_selected_k       (accum_selected_k),
    .o_prefix_bits      (accum_prefix_bits),
    .o_unsupported_codec(accum_unsupported_codec)
  );

  mrtc_header_gen u_header_gen (
    .i_frame_id            (frame_id_reg),
    .i_block_id            (block_id_reg),
    .i_tensor_spatial_size (tensor_spatial_size_reg),
    .i_tensor_doppler_size (tensor_doppler_size_reg),
    .i_tensor_range_size   (tensor_range_size_reg),
    .i_block_spatial_start (16'd0),
    .i_block_doppler_start (16'd0),
    .i_block_range_start   (16'd0),
    .i_block_spatial_len   (8'(MRTC_BLOCK_SPATIAL_LEN)),
    .i_block_doppler_len   (8'(MRTC_BLOCK_DOPPLER_LEN)),
    .i_block_range_len     (16'(MRTC_BLOCK_RANGE_LEN)),
    .i_sample_format       (8'(MRTC_SAMPLE_I16Q16)),
    .i_codec_mode          (block_codec_mode_reg),
    .i_predictor_mode      (block_codec_mode_reg),
    .i_rice_k              (selected_k_reg),
    .i_flags               (header_flags),
    .i_raw_bytes           (32'(COMP_BLOCK_BYTES)),
    .i_payload_bytes       (32'd0),
    .i_payload_bits        (32'd0),
    .i_crc32               (32'd0),
    .o_header_bytes_flat   (header_bytes_flat)
  );

  mrtc_header_axis_streamer #(
    .AXIS_DATA_W (AXIS_DATA_W),
    .HEADER_BYTES(MRTC_HEADER_BYTES)
  ) u_header_axis_streamer (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .i_start                 (header_start_reg),
    .i_header_flat           (header_bytes_flat),
    .i_header_is_packet_last (1'b0),
    .m_axis_tdata            (header_axis_tdata),
    .m_axis_tvalid           (header_axis_tvalid),
    .m_axis_tready           (header_axis_tready),
    .m_axis_tlast            (header_axis_tlast),
    .m_axis_tvalid_bytes_minus1(header_axis_tvalid_bytes_minus1),
    .o_busy                  (header_busy),
    .o_done                  (header_done)
  );

  mrtc_rice_bitpacker_lane_axis #(
    .PHASES_PER_BEAT (PHASES_PER_BEAT),
    .AXIS_DATA_W     (AXIS_DATA_W),
    .BLOCK_SAMPLES   (COMPLEX_SAMPLES_PER_BLOCK),
    .BLOCK_BEATS     (BLOCK_BEATS),
    .ADDR_W          (WORD_ADDR_W),
    .PACKER_LANE_MODE(PHASES_PER_BEAT),
    .TOKEN_W         (256),
    .WORD_FIFO_DEPTH (4)
  ) u_rice_bitpacker_lane_axis (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .i_start                   (bpack_start_reg),
    .i_codec_mode              (block_codec_mode_reg),
    .i_selected_k              (selected_k_reg),
    .o_word_rd_req             (bpack_word_rd_req),
    .o_word_rd_addr_base       (bpack_word_rd_addr),
    .i_word_rd_valid           (bpack_word_rd_valid),
    .i_word_rd_data            (bpack_word_rd_data),
    .m_axis_tdata              (bpack_axis_tdata),
    .m_axis_tvalid             (bpack_axis_tvalid),
    .m_axis_tready             (bpack_axis_tready),
    .m_axis_tlast              (bpack_axis_tlast),
    .m_axis_tvalid_bytes_minus1(bpack_axis_tvalid_bytes_minus1),
    .o_busy                    (bpack_busy),
    .o_done                    (bpack_done),
    .o_payload_bits_counted    (bpack_payload_bits_counted),
    .o_payload_bytes_counted   (bpack_payload_bytes_counted),
    .o_overflow                (bpack_overflow),
    .o_long_unary_used         (lane_bpack_long_unary_used),
    .o_group_fallback_used     (lane_bpack_group_fallback_used)
  );

  always_comb begin
    m_axis_comp_tdata  = '0;
    m_axis_comp_tvalid = 1'b0;
    m_axis_comp_tlast  = 1'b0;
    m_axis_comp_tuser  = '0;
    header_axis_tready = 1'b0;
    bpack_axis_tready  = 1'b0;

    if (state_reg == ST_HEADER) begin
      m_axis_comp_tdata      = header_axis_tdata;
      m_axis_comp_tvalid     = header_axis_tvalid;
      m_axis_comp_tlast      = header_axis_tlast;
      m_axis_comp_tuser[3:0] = header_axis_tvalid_bytes_minus1[3:0];
      header_axis_tready     = m_axis_comp_tready;
    end else if (state_reg == ST_PAYLOAD) begin
      m_axis_comp_tdata      = bpack_axis_tdata;
      m_axis_comp_tvalid     = bpack_axis_tvalid;
      m_axis_comp_tlast      = bpack_axis_tlast;
      m_axis_comp_tuser[3:0] = bpack_axis_tvalid_bytes_minus1[3:0];
      bpack_axis_tready      = m_axis_comp_tready;
    end
  end

  assign output_beat_accept = m_axis_comp_tvalid && m_axis_comp_tready;
  assign output_valid_bytes_u32 = {28'd0, m_axis_comp_tuser[3:0]} + 32'd1;
  assign stat_busy = (state_reg != ST_IDLE);
  assign stat_raw_bypass_blocks = 32'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_reg <= ST_IDLE;
      input_word_count_reg <= '0;
      suffix_pending_count_reg <= '0;
      block_codec_mode_reg <= MRTC_CODEC_ZERO_RICE;
      block_last_reg <= 1'b0;
      block_id_reg <= 16'd0;
      frame_id_reg <= 16'd0;
      tensor_spatial_size_reg <= 16'd0;
      tensor_doppler_size_reg <= 16'd0;
      tensor_range_size_reg <= 16'd0;
      selected_k_reg <= 8'd0;
      prefix_bits_reg <= 32'd0;
      header_start_reg <= 1'b0;
      bpack_start_reg <= 1'b0;
      stat_done <= 1'b0;
      stat_raw_bytes <= 32'd0;
      stat_comp_bytes <= 32'd0;
      stat_num_blocks <= 32'd0;
      stat_error <= MRTC_ERR_NONE;
      stat_stall_input_cycles <= 32'd0;
      stat_stall_output_cycles <= 32'd0;
    end else begin
      header_start_reg <= 1'b0;
      bpack_start_reg <= 1'b0;
      stat_done <= 1'b0;

      if (i_clear_status) begin
        stat_done <= 1'b0;
        stat_raw_bytes <= 32'd0;
        stat_comp_bytes <= 32'd0;
        stat_num_blocks <= 32'd0;
        stat_error <= MRTC_ERR_NONE;
        stat_stall_input_cycles <= 32'd0;
        stat_stall_output_cycles <= 32'd0;
      end else begin
        if (s_axis_raw_tvalid && !s_axis_raw_tready) begin
          stat_stall_input_cycles <= stat_stall_input_cycles + 32'd1;
        end
        if (m_axis_comp_tvalid && !m_axis_comp_tready) begin
          stat_stall_output_cycles <= stat_stall_output_cycles + 32'd1;
        end
        if (raw_beat_accept) begin
          stat_raw_bytes <= stat_raw_bytes + 32'(AXIS_BYTES);
        end
        if (output_beat_accept) begin
          stat_comp_bytes <= stat_comp_bytes + output_valid_bytes_u32;
        end
      end

      case (state_reg)
        ST_IDLE: begin
          input_word_count_reg <= '0;
          suffix_pending_count_reg <= '0;
          if (raw_beat_accept) begin
            block_codec_mode_reg <= {6'd0, s_axis_raw_tuser[2:1]};
            block_last_reg <= s_axis_raw_tuser[3];
            block_id_reg <= cfg_block_id_base;
            frame_id_reg <= cfg_frame_id;
            tensor_spatial_size_reg <= cfg_tensor_spatial_size;
            tensor_doppler_size_reg <= cfg_tensor_doppler_size;
            tensor_range_size_reg <= cfg_tensor_range_size;
            input_word_count_reg <= WORD_ADDR_W'(1);
            if (({6'd0, s_axis_raw_tuser[2:1]} != MRTC_CODEC_ZERO_RICE) &&
                ({6'd0, s_axis_raw_tuser[2:1]} != MRTC_CODEC_DELTA_RICE)) begin
              stat_error <= MRTC_ERR_UNSUPPORTED_CODEC;
              state_reg <= ST_ERROR;
            end else if (s_axis_raw_tlast) begin
              stat_error <= MRTC_ERR_TLAST_EARLY;
              state_reg <= ST_ERROR;
            end else begin
              state_reg <= ST_CAPTURE_PREFIX;
            end
          end
        end

        ST_CAPTURE_PREFIX: begin
          if (raw_beat_accept) begin
            input_word_count_reg <= input_word_count_reg + WORD_ADDR_W'(1);
            if (s_axis_raw_tlast) begin
              stat_error <= MRTC_ERR_TLAST_EARLY;
              state_reg <= ST_ERROR;
            end else if (input_word_count_reg == WORD_ADDR_W'(PREFIX_WORDS - 1)) begin
              state_reg <= ST_K_WAIT;
            end
          end
        end

        ST_K_WAIT: begin
          if (accum_done) begin
            selected_k_reg <= accum_selected_k;
            prefix_bits_reg <= accum_prefix_bits;
            if (accum_unsupported_codec) begin
              stat_error <= MRTC_ERR_UNSUPPORTED_CODEC;
              state_reg <= ST_ERROR;
            end else begin
              header_start_reg <= 1'b1;
              state_reg <= ST_HEADER;
            end
          end
        end

        ST_HEADER: begin
          if (header_done) begin
            bpack_start_reg <= 1'b1;
            state_reg <= ST_BPACK_START;
          end
        end

        ST_BPACK_START: begin
          state_reg <= ST_PAYLOAD;
        end

        ST_PAYLOAD: begin
          case ({suffix_request_issue, suffix_accept})
            2'b10: suffix_pending_count_reg <= suffix_pending_count_reg + SUFFIX_PENDING_W'(1);
            2'b01: suffix_pending_count_reg <= suffix_pending_count_reg - SUFFIX_PENDING_W'(1);
            default: begin
            end
          endcase

          if (suffix_accept) begin
            if (s_axis_raw_tlast && (input_word_count_reg != WORD_ADDR_W'(BLOCK_WORDS - 1))) begin
              stat_error <= MRTC_ERR_TLAST_EARLY;
            end
            if (!s_axis_raw_tlast && (input_word_count_reg == WORD_ADDR_W'(BLOCK_WORDS - 1))) begin
              stat_error <= MRTC_ERR_INPUT_TOO_SHORT;
            end
            input_word_count_reg <= input_word_count_reg + WORD_ADDR_W'(1);
          end

          if (bpack_overflow) begin
            stat_error <= MRTC_ERR_PAYLOAD_TOO_LONG;
          end

          if (bpack_done) begin
            state_reg <= ST_DONE;
          end
        end

        ST_DONE: begin
          stat_done <= 1'b1;
          stat_num_blocks <= stat_num_blocks + 32'd1;
          state_reg <= ST_IDLE;
        end

        ST_ERROR: begin
          state_reg <= ST_IDLE;
        end

        default: begin
          state_reg <= ST_IDLE;
        end
      endcase
    end
  end

  // Keep configuration inputs referenced for lint-clean compatibility with the legacy port set.
  logic unused_cfg_inputs;
  assign unused_cfg_inputs = ^{cfg_codec_mode, cfg_rice_mode, cfg_fixed_k};
endmodule
