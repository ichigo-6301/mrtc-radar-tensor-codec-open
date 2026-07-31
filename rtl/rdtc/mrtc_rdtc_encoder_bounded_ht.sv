module mrtc_rdtc_encoder_bounded_ht #(
  parameter int AXIS_DATA_W = 128,
  parameter int WAY_COUNT = 4,
  parameter int WAY_DEPTH_WORDS = 32,
  parameter int PREFIX_SAMPLES = 128,
  parameter bit PREFIX_FINAL_ACCUM_PIPELINE = 1'b0
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
  output logic                   o_packet_commit,
  output logic                   o_packet_abort,
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

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;
  localparam int WORD_INDEX_W = $clog2(BLOCK_WORDS);
  localparam int WORD_COUNT_W = $clog2(BLOCK_WORDS + 1);
  localparam int GUARD_COUNT_W = $clog2(BLOCK_WORDS + 1);
  localparam int AXIS_VALID_BYTES_W = $clog2(AXIS_BYTES + 1);
  localparam int AXIS_WIDTH_CHECK = 1 / ((AXIS_DATA_W == 128) ? 1 : 0);
  localparam int LANE_CHECK = 1 / ((MRTC_LANES == 4) ? 1 : 0);
  localparam int BLOCK_WORD_CHECK = 1 / ((BLOCK_WORDS == 256) ? 1 : 0);
  localparam int PREFIX_CHECK = 1 / ((PREFIX_SAMPLES == 128) ? 1 : 0);
  localparam int WAY_COUNT_CHECK = 1 / (((WAY_COUNT == 3) || (WAY_COUNT == 4)) ? 1 : 0);
  localparam int WAY_DEPTH_CHECK = 1 / ((WAY_DEPTH_WORDS == 32) ? 1 : 0);

  typedef enum logic [2:0] {
    OUT_IDLE          = 3'd0,
    OUT_HEADER_START  = 3'd1,
    OUT_HEADER_STREAM = 3'd2,
    OUT_BPACK_START   = 3'd3,
    OUT_BPACK_STREAM  = 3'd4,
    OUT_COMMIT_GUARD  = 3'd5,
    OUT_COMPLETE      = 3'd6,
    OUT_HALT          = 3'd7
  } output_state_t;

  output_state_t output_state_reg;

  logic block_active_reg;
  logic capture_done_reg;
  logic [WORD_COUNT_W-1:0] capture_word_count_reg;
  logic [WORD_COUNT_W-1:0] ingress_word_count_reg;
  logic [15:0] frame_id_reg;
  logic [15:0] block_id_reg;
  logic [15:0] tensor_spatial_size_reg;
  logic [15:0] tensor_doppler_size_reg;
  logic [15:0] tensor_range_size_reg;
  logic last_block_reg;

  logic capture_fire;
  logic capture_commit;
  logic block_start;
  logic incoming_config_codec_ok;
  logic incoming_config_rice_ok;
  logic config_latched_reg;
  logic config_codec_ok_reg;
  logic config_rice_ok_reg;
  logic expected_last;
  logic tlast_error;

  logic [AXIS_DATA_W-1:0] ingress_axis_tdata;
  logic                   ingress_axis_tvalid;
  logic                   ingress_axis_tready;
  logic                   ingress_axis_tlast;
  logic [7:0]             ingress_axis_tuser;
  logic                   ingress_queue_s_tready;
  logic [1:0]             ingress_queue_occupancy;
  logic                   ingress_admit;
  logic                   ingress_fire;

  logic prefix_ready;
  logic prefix_busy;
  logic prefix_done;
  logic [7:0] prefix_selected_k;
  logic [31:0] prefix_bits;
  logic prefix_unsupported;
  logic prefix_full_done;
  logic [31:0] prefix_full_bits;
  logic guard_valid;
  logic [WORD_INDEX_W-1:0] guard_word_index;
  logic [15:0] guard_le_128_by_k;
  logic [15:0] guard_all_ok_by_k_reg;
  logic [GUARD_COUNT_W-1:0] guard_checked_count_reg;
  logic selected_k_valid_reg;
  logic [7:0] selected_k_reg;

  logic ring_wr_en;
  logic ring_rd_req;
  logic ring_rd_valid;
  logic [WORD_INDEX_W-1:0] ring_rd_word_index;
  logic [AXIS_DATA_W-1:0] ring_rd_data;
  logic ring_way_conflict;
  logic ring_error;

  logic bpack_start;
  logic bpack_word_rd_req;
  logic [WORD_INDEX_W-1:0] bpack_word_rd_addr;
  logic [AXIS_DATA_W-1:0] bpack_axis_tdata;
  logic bpack_axis_tvalid;
  logic bpack_axis_tready;
  logic bpack_axis_tlast;
  logic [AXIS_VALID_BYTES_W-1:0] bpack_axis_tvalid_bytes_minus1;
  logic bpack_busy;
  logic bpack_done;
  logic [31:0] bpack_payload_bits;
  logic [31:0] bpack_payload_bytes;
  logic bpack_overflow;
  logic bpack_long_unary;
  logic bpack_group_fallback;
  logic bpack_bounded_error;
  logic bpack_bounded_word_error;
  logic bpack_bounded_protocol_error;

  logic header_start;
  logic [(MRTC_HEADER_BYTES*8)-1:0] header_bytes_flat;
  logic [15:0] header_flags;
  logic [AXIS_DATA_W-1:0] header_axis_tdata;
  logic header_axis_tvalid;
  logic header_axis_tready;
  logic header_axis_tlast;
  logic [AXIS_VALID_BYTES_W-1:0] header_axis_tvalid_bytes_minus1;
  logic header_busy;
  logic header_done;

  logic read_sequence_active_reg;
  logic [WORD_COUNT_W-1:0] read_request_count_reg;
  logic [WORD_COUNT_W-1:0] read_response_count_reg;
  logic read_cadence_error;
  logic read_address_error;
  logic read_guard_error;
  logic read_response_error;
  logic read_completion_error;
  logic ring_rd_expected_valid_d1_reg;
  logic ring_rd_expected_valid_d2_reg;
  logic [WORD_INDEX_W-1:0] ring_rd_expected_addr_d1_reg;
  logic [WORD_INDEX_W-1:0] ring_rd_expected_addr_d2_reg;
  logic payload_tlast_accept;
  logic payload_tlast_seen_reg;
  logic commit_guard_error;

  logic [31:0] error_code_reg;
  logic packet_abort_reg;
  logic error_event;
  logic [31:0] error_event_code;
  logic [31:0] cycle_count_reg;
  logic [31:0] dbg_k_valid_cycle;
  logic [31:0] dbg_first_read_cycle;
  logic [31:0] dbg_last_read_cycle;
  logic [31:0] dbg_max_word_cost_fail_index;

  assign incoming_config_codec_ok = (cfg_codec_mode == MRTC_CODEC_ZERO_RICE);
  assign incoming_config_rice_ok =
    (cfg_rice_mode == MRTC_RICE_BLOCK_ADAPTIVE_K);
  assign ingress_admit = rst_n && (error_code_reg == MRTC_ERR_NONE) &&
                         (ingress_word_count_reg < WORD_COUNT_W'(BLOCK_WORDS));
  assign s_axis_raw_tready = ingress_admit && ingress_queue_s_tready;
  assign ingress_fire = s_axis_raw_tvalid && s_axis_raw_tready;
  assign ingress_axis_tready = config_latched_reg &&
                               config_codec_ok_reg && config_rice_ok_reg &&
                               (error_code_reg == MRTC_ERR_NONE) &&
                               (!block_active_reg || !capture_done_reg) &&
                               (capture_word_count_reg < WORD_COUNT_W'(BLOCK_WORDS));
  assign capture_fire = ingress_axis_tvalid && ingress_axis_tready;
  assign capture_commit = capture_fire;
  assign block_start = capture_commit && !block_active_reg;
  assign expected_last = (capture_word_count_reg == WORD_COUNT_W'(BLOCK_WORDS - 1));
  assign tlast_error = capture_commit && (ingress_axis_tlast != expected_last);

  assign ring_wr_en = capture_commit && !tlast_error && (error_code_reg == MRTC_ERR_NONE);
  assign ring_rd_req = bpack_word_rd_req &&
                       (error_code_reg == MRTC_ERR_NONE);

  mrtc_axis_reg_queue2 #(
    .DATA_W  (AXIS_DATA_W),
    .TUSER_W (8)
  ) u_ingress_queue (
    .clk         (clk),
    .rst_n       (rst_n),
    .i_flush     (packet_abort_reg),
    .s_tdata     (s_axis_raw_tdata),
    .s_tuser     (s_axis_raw_tuser),
    .s_tvalid    (s_axis_raw_tvalid && ingress_admit),
    .s_tlast     (s_axis_raw_tlast),
    .s_tready    (ingress_queue_s_tready),
    .m_tdata     (ingress_axis_tdata),
    .m_tuser     (ingress_axis_tuser),
    .m_tvalid    (ingress_axis_tvalid),
    .m_tlast     (ingress_axis_tlast),
    .m_tready    (ingress_axis_tready),
    .o_occupancy (ingress_queue_occupancy)
  );

  mrtc_prefix_k_accum_stream #(
    .AXIS_DATA_W             (AXIS_DATA_W),
    .PREFIX_COMPLEX_SAMPLES  (PREFIX_SAMPLES),
    .PREFIX_SAMPLES          (PREFIX_SAMPLES),
    .BLOCK_COMPLEX_SAMPLES   (MRTC_BLOCK_SAMPLES),
    .TRACK_FULL_BLOCK        (1'b1),
    .PIPELINE_FINAL_ACCUM    (PREFIX_FINAL_ACCUM_PIPELINE)
  ) u_prefix_k (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .i_abort                 (packet_abort_reg),
    .i_start                 (block_start),
    .i_codec_mode            (MRTC_CODEC_ZERO_RICE),
    .i_word_valid            (capture_commit),
    .i_word_data             (ingress_axis_tdata),
    .o_ready                 (prefix_ready),
    .o_busy                  (prefix_busy),
    .o_done                  (prefix_done),
    .o_selected_k            (prefix_selected_k),
    .o_prefix_bits           (prefix_bits),
    .o_unsupported_codec     (prefix_unsupported),
    .o_full_done             (prefix_full_done),
    .o_full_payload_bits     (prefix_full_bits),
    .o_guard_valid           (guard_valid),
    .o_guard_word_index      (guard_word_index),
    .o_guard_le_128_by_k     (guard_le_128_by_k)
  );

  mrtc_shallow_way_ring_slice #(
    .AXIS_DATA_W       (AXIS_DATA_W),
    .BLOCK_WORDS       (BLOCK_WORDS),
    .WAY_COUNT         (WAY_COUNT),
    .WAY_DEPTH_WORDS   (WAY_DEPTH_WORDS)
  ) u_way_ring (
    .clk               (clk),
    .rst_n             (rst_n),
    .i_abort           (packet_abort_reg),
    .i_wr_en           (ring_wr_en),
    .i_wr_word_index   (WORD_INDEX_W'(capture_word_count_reg)),
    .i_wr_data         (ingress_axis_tdata),
    .i_rd_req          (ring_rd_req),
    .i_rd_word_index   (bpack_word_rd_addr),
    .o_rd_valid        (ring_rd_valid),
    .o_rd_word_index   (ring_rd_word_index),
    .o_rd_data         (ring_rd_data),
    .o_way_conflict    (ring_way_conflict),
    .o_ring_error      (ring_error)
  );

  mrtc_rice_bitpacker_lane_axis #(
    .AXIS_DATA_W        (AXIS_DATA_W),
    .BLOCK_SAMPLES      (MRTC_BLOCK_SAMPLES),
    .BLOCK_BEATS        (BLOCK_WORDS),
    .ADDR_W             (WORD_INDEX_W),
    .PACKER_LANE_MODE   (MRTC_LANES),
    .TOKEN_W            (128),
    .WORD_FIFO_DEPTH    (4),
    .ELASTIC_WORD_ISSUE (1),
    .BOUNDED_II1        (1)
  ) u_bpack (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .i_start                   (bpack_start),
    .i_codec_mode              (MRTC_CODEC_ZERO_RICE),
    .i_selected_k              (selected_k_reg),
    .o_word_rd_req             (bpack_word_rd_req),
    .o_word_rd_addr_base       (bpack_word_rd_addr),
    .i_word_rd_valid           (ring_rd_valid),
    .i_word_rd_data            (ring_rd_data),
    .m_axis_tdata              (bpack_axis_tdata),
    .m_axis_tvalid             (bpack_axis_tvalid),
    .m_axis_tready             (bpack_axis_tready),
    .m_axis_tlast              (bpack_axis_tlast),
    .m_axis_tvalid_bytes_minus1(bpack_axis_tvalid_bytes_minus1),
    .o_busy                    (bpack_busy),
    .o_done                    (bpack_done),
    .o_payload_bits_counted    (bpack_payload_bits),
    .o_payload_bytes_counted   (bpack_payload_bytes),
    .o_overflow                (bpack_overflow),
    .o_long_unary_used         (bpack_long_unary),
    .o_group_fallback_used     (bpack_group_fallback),
    .o_bounded_error           (bpack_bounded_error),
    .o_bounded_word_error      (bpack_bounded_word_error),
    .o_bounded_protocol_error  (bpack_bounded_protocol_error)
  );

  always_comb begin
    header_flags = MRTC_FLAG_SAMPLE_MAJOR_IQ |
                   MRTC_FLAG_BLOCK_ADAPTIVE_K |
                   MRTC_FLAG_PREFIX_K_FAST |
                   MRTC_FLAG_STREAM_LENGTH_BY_TLAST;
    if (last_block_reg) begin
      header_flags = header_flags | MRTC_FLAG_LAST_BLOCK;
    end
  end

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
    .i_sample_format       (MRTC_SAMPLE_I16Q16),
    .i_codec_mode          (MRTC_CODEC_ZERO_RICE),
    .i_predictor_mode      (MRTC_CODEC_ZERO_RICE),
    .i_rice_k              (selected_k_reg),
    .i_flags               (header_flags),
    .i_raw_bytes           (32'(MRTC_RAW_BYTES)),
    .i_payload_bytes       (32'd0),
    .i_payload_bits        (32'd0),
    .i_crc32               (32'd0),
    .o_header_bytes_flat   (header_bytes_flat)
  );

  mrtc_header_axis_streamer #(
    .AXIS_DATA_W (AXIS_DATA_W),
    .HEADER_BYTES(MRTC_HEADER_BYTES)
  ) u_header_streamer (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .i_start                   (header_start),
    .i_header_flat             (header_bytes_flat),
    .i_header_is_packet_last   (1'b0),
    .m_axis_tdata              (header_axis_tdata),
    .m_axis_tvalid             (header_axis_tvalid),
    .m_axis_tready             (header_axis_tready),
    .m_axis_tlast              (header_axis_tlast),
    .m_axis_tvalid_bytes_minus1(header_axis_tvalid_bytes_minus1),
    .o_busy                    (header_busy),
    .o_done                    (header_done)
  );

  assign header_start = (output_state_reg == OUT_HEADER_START) &&
                        (error_code_reg == MRTC_ERR_NONE);
  assign bpack_start = (output_state_reg == OUT_BPACK_START) &&
                       (error_code_reg == MRTC_ERR_NONE);

  always_comb begin
    m_axis_comp_tdata = '0;
    m_axis_comp_tvalid = 1'b0;
    m_axis_comp_tlast = 1'b0;
    m_axis_comp_tuser = 8'd0;
    header_axis_tready = 1'b0;
    bpack_axis_tready = 1'b0;

    case (output_state_reg)
      OUT_HEADER_STREAM: begin
        m_axis_comp_tdata = header_axis_tdata;
        m_axis_comp_tvalid = header_axis_tvalid;
        m_axis_comp_tlast = header_axis_tlast;
        m_axis_comp_tuser[3:0] = header_axis_tvalid_bytes_minus1[3:0];
        header_axis_tready = m_axis_comp_tready;
      end
      OUT_BPACK_STREAM: begin
        m_axis_comp_tdata = bpack_axis_tdata;
        m_axis_comp_tvalid = bpack_axis_tvalid;
        m_axis_comp_tlast = bpack_axis_tlast;
        m_axis_comp_tuser[3:0] = bpack_axis_tvalid_bytes_minus1[3:0];
        bpack_axis_tready = m_axis_comp_tready;
      end
      default: begin
      end
    endcase
  end

  assign read_cadence_error = read_sequence_active_reg &&
                              (read_request_count_reg < WORD_COUNT_W'(BLOCK_WORDS)) &&
                              !bpack_word_rd_req;
  assign read_address_error = bpack_word_rd_req &&
                              (bpack_word_rd_addr != WORD_INDEX_W'(read_request_count_reg));
  assign read_guard_error = bpack_word_rd_req &&
                            (guard_checked_count_reg <= GUARD_COUNT_W'(bpack_word_rd_addr));
  assign read_response_error =
    (ring_rd_valid != ring_rd_expected_valid_d2_reg) ||
    (ring_rd_valid && ring_rd_expected_valid_d2_reg &&
     (ring_rd_word_index != ring_rd_expected_addr_d2_reg));
  assign read_completion_error = bpack_done &&
    ((read_request_count_reg != WORD_COUNT_W'(BLOCK_WORDS)) ||
     (read_response_count_reg != WORD_COUNT_W'(BLOCK_WORDS)) ||
     ring_rd_expected_valid_d1_reg || ring_rd_expected_valid_d2_reg ||
     ring_rd_valid);
  assign payload_tlast_accept =
    (output_state_reg == OUT_BPACK_STREAM) &&
    bpack_axis_tvalid && bpack_axis_tready && bpack_axis_tlast;
  assign commit_guard_error = (output_state_reg == OUT_COMMIT_GUARD) &&
                              !payload_tlast_seen_reg;

  always_comb begin
    error_event = 1'b0;
    error_event_code = MRTC_ERR_NONE;
    if (ingress_fire && (ingress_word_count_reg == WORD_COUNT_W'(0)) &&
        !incoming_config_codec_ok) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_UNSUPPORTED_CODEC;
    end else if (ingress_fire &&
                 (ingress_word_count_reg == WORD_COUNT_W'(0)) &&
                 !incoming_config_rice_ok) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_UNSUPPORTED_RICE;
    end else if (tlast_error) begin
      error_event = 1'b1;
      error_event_code = expected_last ? MRTC_ERR_INPUT_TOO_SHORT : MRTC_ERR_TLAST_EARLY;
    end else if (guard_valid && selected_k_valid_reg &&
                 !guard_le_128_by_k[selected_k_reg[3:0]]) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_BOUNDED_RICE_WORD;
    end else if (prefix_done &&
                 !(guard_all_ok_by_k_reg[prefix_selected_k[3:0]] &&
                   (!guard_valid || guard_le_128_by_k[prefix_selected_k[3:0]]))) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_BOUNDED_RICE_WORD;
    end else if (ring_way_conflict) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_SRAM_WAY_CONFLICT;
    end else if (ring_error) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_RING_OVERFLOW;
    end else if (bpack_bounded_word_error ||
                 bpack_long_unary || bpack_group_fallback) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_BOUNDED_RICE_WORD;
    end else if (bpack_bounded_protocol_error || bpack_bounded_error ||
                 bpack_overflow || read_cadence_error || read_address_error ||
                 read_guard_error || read_response_error ||
                 read_completion_error || commit_guard_error) begin
      error_event = 1'b1;
      error_event_code = MRTC_ERR_BITPACK_II1;
    end
  end

  assign stat_busy = block_active_reg || (output_state_reg != OUT_IDLE) ||
                     (error_code_reg != MRTC_ERR_NONE);
  assign stat_error = error_code_reg;
  assign stat_raw_bypass_blocks = 32'd0;
  assign o_packet_commit = stat_done;
  assign o_packet_abort = packet_abort_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      output_state_reg <= OUT_IDLE;
      block_active_reg <= 1'b0;
      capture_done_reg <= 1'b0;
      capture_word_count_reg <= '0;
      ingress_word_count_reg <= '0;
      config_latched_reg <= 1'b0;
      config_codec_ok_reg <= 1'b0;
      config_rice_ok_reg <= 1'b0;
      frame_id_reg <= '0;
      block_id_reg <= '0;
      tensor_spatial_size_reg <= '0;
      tensor_doppler_size_reg <= '0;
      tensor_range_size_reg <= '0;
      last_block_reg <= 1'b0;
      guard_all_ok_by_k_reg <= 16'hffff;
      guard_checked_count_reg <= '0;
      selected_k_valid_reg <= 1'b0;
      selected_k_reg <= 8'd0;
      read_sequence_active_reg <= 1'b0;
      read_request_count_reg <= '0;
      read_response_count_reg <= '0;
      ring_rd_expected_valid_d1_reg <= 1'b0;
      ring_rd_expected_valid_d2_reg <= 1'b0;
      ring_rd_expected_addr_d1_reg <= '0;
      ring_rd_expected_addr_d2_reg <= '0;
      payload_tlast_seen_reg <= 1'b0;
      error_code_reg <= MRTC_ERR_NONE;
      packet_abort_reg <= 1'b0;
      stat_done <= 1'b0;
      stat_raw_bytes <= 32'd0;
      stat_comp_bytes <= 32'd0;
      stat_num_blocks <= 32'd0;
      stat_stall_input_cycles <= 32'd0;
      stat_stall_output_cycles <= 32'd0;
      cycle_count_reg <= 32'd0;
      dbg_k_valid_cycle <= 32'd0;
      dbg_first_read_cycle <= 32'd0;
      dbg_last_read_cycle <= 32'd0;
      dbg_max_word_cost_fail_index <= 32'd0;
    end else begin
      stat_done <= 1'b0;
      packet_abort_reg <= 1'b0;
      cycle_count_reg <= cycle_count_reg + 32'd1;

      if (i_clear_status) begin
        stat_done <= 1'b0;
        stat_raw_bytes <= 32'd0;
        stat_comp_bytes <= 32'd0;
        stat_num_blocks <= 32'd0;
        stat_stall_input_cycles <= 32'd0;
        stat_stall_output_cycles <= 32'd0;
      end

      if (s_axis_raw_tvalid && !s_axis_raw_tready) begin
        stat_stall_input_cycles <= stat_stall_input_cycles + 32'd1;
      end
      if (m_axis_comp_tvalid && !m_axis_comp_tready) begin
        stat_stall_output_cycles <= stat_stall_output_cycles + 32'd1;
      end

      if (error_event && (error_code_reg == MRTC_ERR_NONE)) begin
        error_code_reg <= error_event_code;
        packet_abort_reg <= 1'b1;
        output_state_reg <= OUT_HALT;
        if (guard_valid) begin
          dbg_max_word_cost_fail_index <= 32'(guard_word_index);
        end
      end else if (error_code_reg == MRTC_ERR_NONE) begin
        case (output_state_reg)
          OUT_IDLE: begin
            if (prefix_done && !prefix_unsupported) begin
              output_state_reg <= OUT_HEADER_START;
            end
          end
          OUT_HEADER_START: begin
            output_state_reg <= OUT_HEADER_STREAM;
          end
          OUT_HEADER_STREAM: begin
            if (header_done) begin
              output_state_reg <= OUT_BPACK_START;
            end
          end
          OUT_BPACK_START: begin
            output_state_reg <= OUT_BPACK_STREAM;
          end
          OUT_BPACK_STREAM: begin
            if (bpack_done) begin
              output_state_reg <= OUT_COMMIT_GUARD;
            end
          end
          OUT_COMMIT_GUARD: begin
            output_state_reg <= OUT_COMPLETE;
            stat_done <= 1'b1;
            stat_raw_bytes <= 32'(MRTC_RAW_BYTES);
            stat_comp_bytes <= 32'(MRTC_HEADER_BYTES) + bpack_payload_bytes;
            stat_num_blocks <= stat_num_blocks + 32'd1;
          end
          OUT_COMPLETE: begin
            output_state_reg <= OUT_IDLE;
            block_active_reg <= 1'b0;
            capture_done_reg <= 1'b0;
            capture_word_count_reg <= '0;
            ingress_word_count_reg <= '0;
            config_latched_reg <= 1'b0;
            config_codec_ok_reg <= 1'b0;
            config_rice_ok_reg <= 1'b0;
            selected_k_valid_reg <= 1'b0;
            selected_k_reg <= 8'd0;
            guard_all_ok_by_k_reg <= 16'hffff;
            guard_checked_count_reg <= '0;
            read_sequence_active_reg <= 1'b0;
            read_request_count_reg <= '0;
            read_response_count_reg <= '0;
            payload_tlast_seen_reg <= 1'b0;
          end
          default: begin
            output_state_reg <= OUT_HALT;
          end
        endcase
      end

      if (block_start) begin
        block_active_reg <= 1'b1;
        capture_done_reg <= 1'b0;
        capture_word_count_reg <= WORD_COUNT_W'(1);
        last_block_reg <= ingress_axis_tuser[0];
        guard_all_ok_by_k_reg <= 16'hffff;
        guard_checked_count_reg <= '0;
        selected_k_valid_reg <= 1'b0;
        selected_k_reg <= 8'd0;
        read_sequence_active_reg <= 1'b0;
        read_request_count_reg <= '0;
        read_response_count_reg <= '0;
        ring_rd_expected_valid_d1_reg <= 1'b0;
        ring_rd_expected_valid_d2_reg <= 1'b0;
        ring_rd_expected_addr_d1_reg <= '0;
        ring_rd_expected_addr_d2_reg <= '0;
        payload_tlast_seen_reg <= 1'b0;
        cycle_count_reg <= 32'd0;
        dbg_k_valid_cycle <= 32'd0;
        dbg_first_read_cycle <= 32'd0;
        dbg_last_read_cycle <= 32'd0;
      end else if (capture_commit && block_active_reg && !capture_done_reg) begin
        capture_word_count_reg <= capture_word_count_reg + WORD_COUNT_W'(1);
      end

      if (ingress_fire) begin
        ingress_word_count_reg <= ingress_word_count_reg + WORD_COUNT_W'(1);
        if (ingress_word_count_reg == WORD_COUNT_W'(0)) begin
          config_latched_reg <= 1'b1;
          config_codec_ok_reg <= incoming_config_codec_ok;
          config_rice_ok_reg <= incoming_config_rice_ok;
          frame_id_reg <= cfg_frame_id;
          block_id_reg <= cfg_block_id_base;
          tensor_spatial_size_reg <= cfg_tensor_spatial_size;
          tensor_doppler_size_reg <= cfg_tensor_doppler_size;
          tensor_range_size_reg <= cfg_tensor_range_size;
        end
      end

      if (capture_commit && expected_last && !tlast_error) begin
        capture_done_reg <= 1'b1;
      end

      if (guard_valid) begin
        if (guard_word_index == '0) begin
          guard_all_ok_by_k_reg <= guard_le_128_by_k;
        end else begin
          guard_all_ok_by_k_reg <= guard_all_ok_by_k_reg & guard_le_128_by_k;
        end
        guard_checked_count_reg <= GUARD_COUNT_W'(guard_word_index) + GUARD_COUNT_W'(1);
      end

      if (prefix_done) begin
        selected_k_valid_reg <= 1'b1;
        selected_k_reg <= prefix_selected_k;
        dbg_k_valid_cycle <= cycle_count_reg;
      end

      if (bpack_word_rd_req) begin
        if (!read_sequence_active_reg) begin
          read_sequence_active_reg <= 1'b1;
          dbg_first_read_cycle <= cycle_count_reg;
        end
        read_request_count_reg <= read_request_count_reg + WORD_COUNT_W'(1);
        if (read_request_count_reg == WORD_COUNT_W'(BLOCK_WORDS - 1)) begin
          read_sequence_active_reg <= 1'b0;
          dbg_last_read_cycle <= cycle_count_reg;
        end
      end

      if (ring_rd_valid) begin
        read_response_count_reg <= read_response_count_reg + WORD_COUNT_W'(1);
      end

      if (packet_abort_reg) begin
        ring_rd_expected_valid_d1_reg <= 1'b0;
        ring_rd_expected_valid_d2_reg <= 1'b0;
        ring_rd_expected_addr_d1_reg <= '0;
        ring_rd_expected_addr_d2_reg <= '0;
        payload_tlast_seen_reg <= 1'b0;
      end else if (!block_start) begin
        ring_rd_expected_valid_d1_reg <= ring_rd_req;
        ring_rd_expected_valid_d2_reg <= ring_rd_expected_valid_d1_reg;
        if (ring_rd_req) begin
          ring_rd_expected_addr_d1_reg <= bpack_word_rd_addr;
        end
        if (ring_rd_expected_valid_d1_reg) begin
          ring_rd_expected_addr_d2_reg <= ring_rd_expected_addr_d1_reg;
        end
      end

      if (payload_tlast_accept) begin
        payload_tlast_seen_reg <= 1'b1;
      end
    end
  end
endmodule
