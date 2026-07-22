module mrtc_rdtc_encoder_top #(
  parameter int AXIS_DATA_W = 128,
  parameter int MRTC_K_POLICY_ARCH = mrtc_pkg::MRTC_K_POLICY_FULL_ADAPTIVE,
  parameter int MRTC_BPACK_ARCH = mrtc_pkg::MRTC_BPACK_ARCH_LEGACY_SAMPLE,
  parameter int PACKER_LANE_MODE = 4,
  parameter bit PREFIX_DURING_CAPTURE = 1'b1,
  parameter bit PREFIX_STREAM_LENGTH_BY_TLAST = 1'b1,
  parameter int PREFIX_SAMPLES = 256
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

  typedef enum logic [3:0] {
    ST_CAPTURE       = 4'd0,
    ST_KSEL_START    = 4'd1,
    ST_KSEL_WAIT     = 4'd2,
    ST_HEADER_START  = 4'd3,
    ST_HEADER_STREAM = 4'd4,
    ST_RAW_START     = 4'd5,
    ST_RAW_STREAM    = 4'd6,
    ST_BPACK_START   = 4'd7,
    ST_BPACK_STREAM  = 4'd8,
    ST_DRAIN         = 4'd9,
    ST_ADVANCE       = 4'd10
  } state_t;

  typedef enum logic [1:0] {
    BANK_OWNER_NONE       = 2'd0,
    BANK_OWNER_SAMPLE     = 2'd1,
    BANK_OWNER_RAW        = 2'd2,
    BANK_OWNER_BPACK_WORD = 2'd3
  } bank_owner_t;

  typedef enum logic [1:0] {
    SAMPLE_CLIENT_NONE  = 2'd0,
    SAMPLE_CLIENT_KSEL  = 2'd1,
    SAMPLE_CLIENT_BPACK = 2'd2
  } sample_client_t;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int AXIS_VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;
  localparam int BLOCK_WORD_ADDR_W = $clog2(BLOCK_WORDS);
  localparam int PREFIX_WORDS = PREFIX_SAMPLES / MRTC_LANES;
  localparam int PREFIX_WORD_ADDR_W = $clog2(PREFIX_WORDS);

  state_t state_reg;
  bank_owner_t bank_owner_reg;
  sample_client_t sample_client_reg;

  logic        raw_beat_accept;
  logic        capture_can_accept;
  logic        fill_bank_valid;
  logic        fill_bank_sel;
  logic [BLOCK_WORD_ADDR_W-1:0] fill_word_addr;
  logic        proc_ready_valid;
  logic        proc_ready_bank_sel;
  logic        proc_active_valid;
  logic        proc_active_bank_sel;
  logic [1:0]  bank_state0;
  logic [1:0]  bank_state1;
  logic [7:0]  proc_codec_mode;
  logic [7:0]  proc_rice_mode;
  logic [3:0]  proc_fixed_k;
  logic        proc_last_block;
  logic [15:0] proc_frame_id;
  logic [15:0] proc_block_id;
  logic [15:0] proc_block_range_start;
  logic [15:0] proc_tensor_spatial_size;
  logic [15:0] proc_tensor_doppler_size;
  logic [15:0] proc_tensor_range_size;
  logic [31:0] bank_manager_error;
  logic [31:0] capture_accepted_blocks;
  logic [31:0] processing_started_blocks;
  logic [31:0] processing_done_blocks;
  logic [31:0] pingpong_overlap_blocks;
  logic        proc_take_ready;
  logic        proc_done_pulse;

  logic                   bank_wr_en;
  logic                   bank0_wr_en;
  logic                   bank1_wr_en;
  logic [BLOCK_WORD_ADDR_W-1:0] bank_wr_word_addr;
  logic [AXIS_DATA_W-1:0] bank_wr_word_data;
  logic                   bank_rd_req;
  logic [BLOCK_WORD_ADDR_W-1:0] bank_rd_word_addr;
  logic                   bank0_rd_valid;
  logic [AXIS_DATA_W-1:0] bank0_rd_word_data;
  logic                   bank1_rd_valid;
  logic [AXIS_DATA_W-1:0] bank1_rd_word_data;
  logic                   bank_rd_valid;
  logic [AXIS_DATA_W-1:0] bank_rd_word_data;

  logic                   sample_rd_req_mux;
  logic [9:0]             sample_rd_addr_mux;
  logic                   sample_bank_rd_req;
  logic [BLOCK_WORD_ADDR_W-1:0] sample_bank_rd_word_addr;
  logic                   sample_bank_rd_valid;
  logic [AXIS_DATA_W-1:0] sample_bank_rd_word_data;
  logic                   sample_rd_valid;
  logic [31:0]            sample_rd_data;
  logic                   raw_bank_rd_req;
  logic [BLOCK_WORD_ADDR_W-1:0] raw_bank_rd_word_addr;
  logic                   raw_bank_rd_valid;
  logic [AXIS_DATA_W-1:0] raw_bank_rd_word_data;
  logic                   internal_state_error_pulse;
  logic                   bank_owner_release_now;
  logic                   bank_owner_accept_same_owner_now;

  logic        ksel_start;
  logic        ksel_start_pulse;
  logic        ksel_busy;
  logic        ksel_done;
  logic        ksel_rd_req;
  logic [9:0]  ksel_rd_addr;
  logic        ksel_rd_valid;
  logic [31:0] ksel_rd_data;
  logic [7:0]  ksel_selected_k;
  logic [31:0] ksel_payload_bits;
  logic [31:0] ksel_payload_bytes;
  logic        ksel_use_raw;
  logic        ksel_unsupported_rice;
  logic        ksel_prefix_fast_active;
  logic [31:0] ksel_prefix_bits;
  logic [31:0] ksel_prefix_cycles;
  logic [31:0] ksel_size_count_cycles;
  logic [31:0] ksel_total_policy_cycles;

  logic        header_start;
  logic        header_busy;
  logic        header_done;
  logic [AXIS_DATA_W-1:0] header_axis_tdata;
  logic                   header_axis_tvalid;
  logic                   header_axis_tready;
  logic                   header_axis_tlast;
  logic [AXIS_VALID_BYTE_COUNT_W-1:0] header_axis_tvalid_bytes_minus1;

  logic        raw_start;
  logic        raw_busy;
  logic        raw_done;
  logic [AXIS_DATA_W-1:0] raw_axis_tdata;
  logic                   raw_axis_tvalid;
  logic                   raw_axis_tready;
  logic                   raw_axis_tlast;
  logic [AXIS_VALID_BYTE_COUNT_W-1:0] raw_axis_tvalid_bytes_minus1;

  logic        bpack_start;
  logic        bpack_busy;
  logic        bpack_done;
  logic        bpack_rd_req;
  logic [9:0]  bpack_rd_addr;
  logic [AXIS_DATA_W-1:0] bpack_axis_tdata;
  logic                   bpack_axis_tvalid;
  logic                   bpack_axis_tready;
  logic                   bpack_axis_tlast;
  logic [AXIS_VALID_BYTE_COUNT_W-1:0] bpack_axis_tvalid_bytes_minus1;
  logic [31:0] bpack_payload_bits_counted;
  logic [31:0] bpack_payload_bytes_counted;
  logic        bpack_count_mismatch;
  logic        bpack_overflow;
  logic        use_lane_word_bpack;

  logic        legacy_bpack_busy;
  logic        legacy_bpack_done;
  logic        legacy_bpack_rd_req;
  logic [9:0]  legacy_bpack_rd_addr;
  logic        legacy_bpack_rd_valid;
  logic [31:0] legacy_bpack_rd_data;
  logic [AXIS_DATA_W-1:0] legacy_bpack_axis_tdata;
  logic                   legacy_bpack_axis_tvalid;
  logic                   legacy_bpack_axis_tlast;
  logic [AXIS_VALID_BYTE_COUNT_W-1:0] legacy_bpack_axis_tvalid_bytes_minus1;
  logic [31:0] legacy_bpack_payload_bits_counted;
  logic [31:0] legacy_bpack_payload_bytes_counted;
  logic        legacy_bpack_count_mismatch;
  logic        legacy_bpack_overflow;

  logic        lane_bpack_busy;
  logic        lane_bpack_done;
  logic        lane_bpack_word_rd_req;
  logic [BLOCK_WORD_ADDR_W-1:0] lane_bpack_word_rd_addr;
  logic        lane_bpack_word_rd_valid;
  logic [AXIS_DATA_W-1:0] lane_bpack_word_rd_data;
  logic [AXIS_DATA_W-1:0] lane_bpack_axis_tdata;
  logic                   lane_bpack_axis_tvalid;
  logic                   lane_bpack_axis_tlast;
  logic [AXIS_VALID_BYTE_COUNT_W-1:0] lane_bpack_axis_tvalid_bytes_minus1;
  logic [31:0] lane_bpack_payload_bits_counted;
  logic [31:0] lane_bpack_payload_bytes_counted;
  logic        lane_bpack_overflow;
  logic        lane_bpack_long_unary_used;
  logic        lane_bpack_group_fallback_used;

  logic [7:0]  selected_k_reg;
  logic [31:0] payload_bits_pre_reg;
  logic [31:0] payload_bytes_pre_reg;
  logic        use_raw_pre_reg;
  logic        unsupported_rice_reg;
  logic        prefix_fast_active_reg;
  logic [31:0] prefix_bits_reg;
  logic [31:0] k_policy_cycles_reg;
  logic [31:0] k_policy_size_cycles_reg;
  logic [31:0] k_policy_total_cycles_reg;
  logic [31:0] payload_bits_post;
  logic [31:0] payload_bytes_post;
  logic        proc_prefix_precomputed_valid;
  logic [7:0]  proc_prefix_precomputed_k;
  logic [31:0] proc_prefix_precomputed_bits;
  logic [31:0] proc_prefix_precomputed_cycles;
  logic        proc_prefix_precomputed_unsupported;
  logic        prefix_buf0_wr_en;
  logic        prefix_buf1_wr_en;
  logic [PREFIX_WORD_ADDR_W-1:0] prefix_buf_wr_addr;
  logic        prefix_buf_bank0_ready_reg;
  logic        prefix_buf_bank1_ready_reg;
  logic [7:0]  prefix_codec_mode_reg_bank [0:1];
  logic        prefix_result_valid_reg [0:1];
  logic [7:0]  prefix_selected_k_reg_bank [0:1];
  logic [31:0] prefix_bits_reg_bank [0:1];
  logic [31:0] prefix_cycles_reg_bank [0:1];
  logic        prefix_unsupported_reg_bank [0:1];
  logic        prefix_pre_rd_req;
  logic [9:0]  prefix_pre_rd_addr;
  logic        prefix_pre_rd_valid;
  logic [31:0] prefix_pre_rd_data;
  logic        prefix_buf0_rd_valid;
  logic [31:0] prefix_buf0_rd_data;
  logic        prefix_buf1_rd_valid;
  logic [31:0] prefix_buf1_rd_data;
  logic        prefix_pre_busy;
  logic        prefix_pre_done;
  logic        prefix_pre_result_bank_sel;
  logic [7:0]  prefix_pre_selected_k;
  logic [31:0] prefix_pre_bits;
  logic [31:0] prefix_pre_cycles;
  logic        prefix_pre_unsupported;
  logic [31:0] block_ready_to_k_done_dbg;
  logic        ready_bank_prefix_result_valid;
  logic [7:0]  ready_bank_prefix_codec_mode;
  logic        ready_prefix_wait_needed;
  logic        proc_prefix_wait_needed;

  // Legacy debug aliases kept for existing file-vector TB hierarchy probes.
  logic        block_ready;
  logic        block_last;
  logic [15:0] block_id;
  logic [15:0] block_range_start;
  logic [31:0] block_ctrl_error;
  logic [10:0] sample_count;
  logic [7:0]  selected_k;
  logic [31:0] payload_bits_pre;
  logic [31:0] payload_bytes_pre;
  logic        use_raw_pre;
  logic        unsupported_rice;

  logic [(MRTC_HEADER_BYTES*8)-1:0] header_bytes_flat;
  logic [15:0] header_flags;
  logic [31:0] raw_bytes_u32;
  logic [31:0] payload_bytes_for_header;
  logic [31:0] payload_bits_for_header;
  logic [31:0] stat_error_reg;
  logic        prefix_stream_length_active;
  logic        bpack_expected_length_valid;

  assign raw_beat_accept   = s_axis_raw_tvalid && s_axis_raw_tready;
  assign s_axis_raw_tready = capture_can_accept;
  assign stat_busy         = fill_bank_valid || proc_ready_valid || proc_active_valid || (state_reg != ST_CAPTURE);
  assign stat_error        = stat_error_reg;
  assign ksel_start_pulse  = (state_reg == ST_KSEL_START);
  assign ksel_start        = ksel_start_pulse;
  assign header_start      = (state_reg == ST_HEADER_START);
  assign raw_start         = (state_reg == ST_RAW_START);
  assign bpack_start       = (state_reg == ST_BPACK_START);
  assign proc_take_ready   = (state_reg == ST_CAPTURE) && proc_ready_valid && !ready_prefix_wait_needed;
  assign proc_done_pulse   = (state_reg == ST_DRAIN);
  assign use_lane_word_bpack = (MRTC_BPACK_ARCH == MRTC_BPACK_ARCH_LANE_WORD);
  assign bank_owner_release_now =
    bank_rd_valid &&
    (((bank_owner_reg == BANK_OWNER_SAMPLE) &&
      sample_bank_rd_req && !raw_bank_rd_req && !lane_bpack_word_rd_req) ||
     ((bank_owner_reg == BANK_OWNER_RAW) &&
      raw_bank_rd_req && !sample_bank_rd_req && !lane_bpack_word_rd_req) ||
     ((bank_owner_reg == BANK_OWNER_BPACK_WORD) &&
      lane_bpack_word_rd_req && !sample_bank_rd_req && !raw_bank_rd_req));
  assign bank_owner_accept_same_owner_now = bank_owner_release_now;

  assign selected_k        = selected_k_reg;
  assign payload_bits_pre  = payload_bits_pre_reg;
  assign payload_bytes_pre = payload_bytes_pre_reg;
  assign use_raw_pre       = use_raw_pre_reg;
  assign unsupported_rice  = unsupported_rice_reg;

  assign block_ready       = proc_ready_valid;
  assign block_last        = proc_last_block;
  assign block_id          = proc_block_id;
  assign block_range_start = proc_block_range_start;
  assign block_ctrl_error  = bank_manager_error;
  assign sample_count      = fill_bank_valid ? {fill_word_addr, 2'b00} : 11'd0;

  assign bank_wr_en        = raw_beat_accept && fill_bank_valid;
  assign bank_wr_word_addr = fill_word_addr;
  assign bank_wr_word_data = s_axis_raw_tdata;
  assign bank0_wr_en       = bank_wr_en && !fill_bank_sel;
  assign bank1_wr_en       = bank_wr_en && fill_bank_sel;
  assign prefix_buf_wr_addr = PREFIX_WORD_ADDR_W'(fill_word_addr);
  assign prefix_buf0_wr_en  = bank0_wr_en && (fill_word_addr < PREFIX_WORDS);
  assign prefix_buf1_wr_en  = bank1_wr_en && (fill_word_addr < PREFIX_WORDS);
  assign proc_prefix_precomputed_valid =
    proc_active_valid && prefix_result_valid_reg[proc_active_bank_sel];
  assign proc_prefix_precomputed_k =
    proc_active_bank_sel ? prefix_selected_k_reg_bank[1] : prefix_selected_k_reg_bank[0];
  assign proc_prefix_precomputed_bits =
    proc_active_bank_sel ? prefix_bits_reg_bank[1] : prefix_bits_reg_bank[0];
  assign proc_prefix_precomputed_cycles =
    proc_active_bank_sel ? prefix_cycles_reg_bank[1] : prefix_cycles_reg_bank[0];
  assign proc_prefix_precomputed_unsupported =
    proc_active_bank_sel ? prefix_unsupported_reg_bank[1] : prefix_unsupported_reg_bank[0];
  assign ready_bank_prefix_result_valid =
    proc_ready_bank_sel ? prefix_result_valid_reg[1] : prefix_result_valid_reg[0];
  assign ready_bank_prefix_codec_mode =
    proc_ready_bank_sel ? prefix_codec_mode_reg_bank[1] : prefix_codec_mode_reg_bank[0];
  assign ready_prefix_wait_needed =
    (MRTC_K_POLICY_ARCH == MRTC_K_POLICY_PREFIX_FAST) &&
    PREFIX_DURING_CAPTURE &&
    proc_ready_valid &&
    ((ready_bank_prefix_codec_mode == MRTC_CODEC_ZERO_RICE) ||
     (ready_bank_prefix_codec_mode == MRTC_CODEC_DELTA_RICE)) &&
    !ready_bank_prefix_result_valid;
  assign proc_prefix_wait_needed =
    (MRTC_K_POLICY_ARCH == MRTC_K_POLICY_PREFIX_FAST) &&
    PREFIX_DURING_CAPTURE &&
    proc_active_valid &&
    ((proc_codec_mode == MRTC_CODEC_ZERO_RICE) ||
     (proc_codec_mode == MRTC_CODEC_DELTA_RICE)) &&
    !proc_prefix_precomputed_valid;
  assign prefix_pre_rd_valid =
    prefix_pre_result_bank_sel ? prefix_buf1_rd_valid : prefix_buf0_rd_valid;
  assign prefix_pre_rd_data =
    prefix_pre_result_bank_sel ? prefix_buf1_rd_data : prefix_buf0_rd_data;

  assign bank_rd_valid =
    proc_active_valid ? (proc_active_bank_sel ? bank1_rd_valid : bank0_rd_valid) : 1'b0;
  assign bank_rd_word_data =
    proc_active_valid ? (proc_active_bank_sel ? bank1_rd_word_data : bank0_rd_word_data) : '0;

  assign ksel_rd_valid        = sample_rd_valid && (sample_client_reg == SAMPLE_CLIENT_KSEL);
  assign ksel_rd_data         = sample_rd_data;
  assign legacy_bpack_rd_valid = sample_rd_valid && (sample_client_reg == SAMPLE_CLIENT_BPACK);
  assign legacy_bpack_rd_data  = sample_rd_data;
  assign lane_bpack_word_rd_data = bank_rd_word_data;

  assign bpack_busy = use_lane_word_bpack ? lane_bpack_busy : legacy_bpack_busy;
  assign bpack_done = use_lane_word_bpack ? lane_bpack_done : legacy_bpack_done;
  assign bpack_rd_req = use_lane_word_bpack ? 1'b0 : legacy_bpack_rd_req;
  assign bpack_rd_addr = use_lane_word_bpack ? 10'd0 : legacy_bpack_rd_addr;
  assign bpack_axis_tdata = use_lane_word_bpack ? lane_bpack_axis_tdata : legacy_bpack_axis_tdata;
  assign bpack_axis_tvalid = use_lane_word_bpack ? lane_bpack_axis_tvalid : legacy_bpack_axis_tvalid;
  assign bpack_axis_tlast = use_lane_word_bpack ? lane_bpack_axis_tlast : legacy_bpack_axis_tlast;
  assign bpack_axis_tvalid_bytes_minus1 =
    use_lane_word_bpack ? lane_bpack_axis_tvalid_bytes_minus1 :
                          legacy_bpack_axis_tvalid_bytes_minus1;
  assign bpack_payload_bits_counted =
    use_lane_word_bpack ? lane_bpack_payload_bits_counted :
                          legacy_bpack_payload_bits_counted;
  assign bpack_payload_bytes_counted =
    use_lane_word_bpack ? lane_bpack_payload_bytes_counted :
                          legacy_bpack_payload_bytes_counted;
  assign bpack_count_mismatch = use_lane_word_bpack ? 1'b0 : legacy_bpack_count_mismatch;
  assign bpack_overflow = use_lane_word_bpack ? lane_bpack_overflow : legacy_bpack_overflow;

  initial begin
    if (AXIS_DATA_W != 128) begin
      $fatal(1, "mrtc_rdtc_encoder_top Stage 16B-2B active integration only supports AXIS_DATA_W=128");
    end
    if ((MRTC_BPACK_ARCH != MRTC_BPACK_ARCH_LEGACY_SAMPLE) &&
        (MRTC_BPACK_ARCH != MRTC_BPACK_ARCH_LANE_WORD)) begin
      $fatal(1, "mrtc_rdtc_encoder_top unsupported MRTC_BPACK_ARCH=%0d", MRTC_BPACK_ARCH);
    end
    if ((MRTC_BPACK_ARCH == MRTC_BPACK_ARCH_LANE_WORD) &&
        (MRTC_K_POLICY_ARCH != MRTC_K_POLICY_PREFIX_FAST)) begin
      $fatal(1, "mrtc_rdtc_encoder_top Stage 16D-2 lane-word bitpacker only supports PREFIX_FAST");
    end
  end

  mrtc_pingpong_block_bank_manager #(
    .BLOCK_WORDS    (BLOCK_WORDS),
    .BLOCK_RANGE_LEN(MRTC_BLOCK_RANGE_LEN)
  ) u_pingpong_block_bank_manager (
    .clk                        (clk),
    .rst_n                      (rst_n),
    .i_block_id_base            (cfg_block_id_base),
    .i_capture_valid            (s_axis_raw_tvalid),
    .i_capture_accept           (raw_beat_accept),
    .i_capture_tlast            (s_axis_raw_tlast),
    .i_capture_codec_mode       ({6'd0, s_axis_raw_tuser[2:1]}),
    .i_capture_rice_mode        (cfg_rice_mode),
    .i_capture_fixed_k          (cfg_fixed_k),
    .i_capture_last_block       (s_axis_raw_tuser[3]),
    .i_capture_frame_id         (cfg_frame_id),
    .i_capture_tensor_spatial_size(cfg_tensor_spatial_size),
    .i_capture_tensor_doppler_size(cfg_tensor_doppler_size),
    .i_capture_tensor_range_size(cfg_tensor_range_size),
    .i_proc_take_ready          (proc_take_ready),
    .i_proc_done                (proc_done_pulse),
    .o_capture_can_accept       (capture_can_accept),
    .o_fill_bank_valid          (fill_bank_valid),
    .o_fill_bank_sel            (fill_bank_sel),
    .o_fill_word_addr           (fill_word_addr),
    .o_proc_ready_valid         (proc_ready_valid),
    .o_proc_ready_bank_sel      (proc_ready_bank_sel),
    .o_proc_active_valid        (proc_active_valid),
    .o_proc_active_bank_sel     (proc_active_bank_sel),
    .o_bank_state0              (bank_state0),
    .o_bank_state1              (bank_state1),
    .o_proc_codec_mode          (proc_codec_mode),
    .o_proc_rice_mode           (proc_rice_mode),
    .o_proc_fixed_k             (proc_fixed_k),
    .o_proc_last_block          (proc_last_block),
    .o_proc_frame_id            (proc_frame_id),
    .o_proc_block_id            (proc_block_id),
    .o_proc_block_range_start   (proc_block_range_start),
    .o_proc_tensor_spatial_size (proc_tensor_spatial_size),
    .o_proc_tensor_doppler_size (proc_tensor_doppler_size),
    .o_proc_tensor_range_size   (proc_tensor_range_size),
    .o_error                    (bank_manager_error),
    .o_capture_accepted_blocks  (capture_accepted_blocks),
    .o_processing_started_blocks(processing_started_blocks),
    .o_processing_done_blocks   (processing_done_blocks),
    .o_pingpong_overlap_blocks  (pingpong_overlap_blocks)
  );

  mrtc_block_word_bank #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (MRTC_LANES),
    .BLOCK_SAMPLES(MRTC_BLOCK_SAMPLES),
    .READ_LATENCY (1)
  ) u_block_word_bank0 (
    .clk           (clk),
    .rst_n         (rst_n),
    .i_clear       (1'b0),
    .i_wr_en       (bank0_wr_en),
    .i_wr_word_addr(bank_wr_word_addr),
    .i_wr_word_data(bank_wr_word_data),
    .i_rd_req      (bank_rd_req && proc_active_valid && !proc_active_bank_sel),
    .i_rd_word_addr(bank_rd_word_addr),
    .o_rd_valid    (bank0_rd_valid),
    .o_rd_word_data(bank0_rd_word_data)
  );

  mrtc_block_word_bank #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (MRTC_LANES),
    .BLOCK_SAMPLES(MRTC_BLOCK_SAMPLES),
    .READ_LATENCY (1)
  ) u_block_word_bank1 (
    .clk           (clk),
    .rst_n         (rst_n),
    .i_clear       (1'b0),
    .i_wr_en       (bank1_wr_en),
    .i_wr_word_addr(bank_wr_word_addr),
    .i_wr_word_data(bank_wr_word_data),
    .i_rd_req      (bank_rd_req && proc_active_valid && proc_active_bank_sel),
    .i_rd_word_addr(bank_rd_word_addr),
    .o_rd_valid    (bank1_rd_valid),
    .o_rd_word_data(bank1_rd_word_data)
  );

  mrtc_block_sample_read_adapter #(
    .AXIS_DATA_W  (AXIS_DATA_W),
    .LANES        (MRTC_LANES),
    .BLOCK_SAMPLES(MRTC_BLOCK_SAMPLES)
  ) u_block_sample_read_adapter (
    .clk                 (clk),
    .rst_n               (rst_n),
    .i_sample_rd_req     (sample_rd_req_mux),
    .i_sample_rd_addr    (sample_rd_addr_mux),
    .o_bank_rd_req       (sample_bank_rd_req),
    .o_bank_rd_word_addr (sample_bank_rd_word_addr),
    .i_bank_rd_valid     (sample_bank_rd_valid),
    .i_bank_rd_word_data (sample_bank_rd_word_data),
    .o_sample_rd_valid   (sample_rd_valid),
    .o_sample_rd_data    (sample_rd_data)
  );

  mrtc_prefix_capture_buffer #(
    .AXIS_DATA_W    (AXIS_DATA_W),
    .LANES          (MRTC_LANES),
    .PREFIX_SAMPLES (PREFIX_SAMPLES)
  ) u_prefix_capture_buffer0 (
    .clk         (clk),
    .rst_n       (rst_n),
    .i_wr_en     (prefix_buf0_wr_en),
    .i_wr_word_addr(prefix_buf_wr_addr),
    .i_wr_word_data(bank_wr_word_data),
    .i_rd_req    (prefix_pre_rd_req && !prefix_pre_result_bank_sel),
    .i_rd_addr   (prefix_pre_rd_addr[$clog2(PREFIX_SAMPLES)-1:0]),
    .o_rd_valid  (prefix_buf0_rd_valid),
    .o_rd_data   (prefix_buf0_rd_data)
  );

  mrtc_prefix_capture_buffer #(
    .AXIS_DATA_W    (AXIS_DATA_W),
    .LANES          (MRTC_LANES),
    .PREFIX_SAMPLES (PREFIX_SAMPLES)
  ) u_prefix_capture_buffer1 (
    .clk         (clk),
    .rst_n       (rst_n),
    .i_wr_en     (prefix_buf1_wr_en),
    .i_wr_word_addr(prefix_buf_wr_addr),
    .i_wr_word_data(bank_wr_word_data),
    .i_rd_req    (prefix_pre_rd_req && prefix_pre_result_bank_sel),
    .i_rd_addr   (prefix_pre_rd_addr[$clog2(PREFIX_SAMPLES)-1:0]),
    .o_rd_valid  (prefix_buf1_rd_valid),
    .o_rd_data   (prefix_buf1_rd_data)
  );

  mrtc_prefix_precompute_engine #(
    .PREFIX_SAMPLES(PREFIX_SAMPLES),
    .BLOCK_SAMPLES (MRTC_BLOCK_SAMPLES),
    .ADDR_W        (10)
  ) u_prefix_precompute_engine (
    .clk                 (clk),
    .rst_n               (rst_n),
    .i_bank0_ready       (prefix_buf_bank0_ready_reg),
    .i_bank1_ready       (prefix_buf_bank1_ready_reg),
    .i_bank0_result_valid(prefix_result_valid_reg[0]),
    .i_bank1_result_valid(prefix_result_valid_reg[1]),
    .i_bank0_codec_mode  (prefix_codec_mode_reg_bank[0]),
    .i_bank1_codec_mode  (prefix_codec_mode_reg_bank[1]),
    .o_rd_req            (prefix_pre_rd_req),
    .o_rd_addr           (prefix_pre_rd_addr),
    .i_rd_valid          (prefix_pre_rd_valid),
    .i_rd_data           (prefix_pre_rd_data),
    .o_busy              (prefix_pre_busy),
    .o_result_done       (prefix_pre_done),
    .o_result_bank_sel   (prefix_pre_result_bank_sel),
    .o_selected_k        (prefix_pre_selected_k),
    .o_prefix_bits       (prefix_pre_bits),
    .o_prefix_cycles     (prefix_pre_cycles),
    .o_unsupported_codec (prefix_pre_unsupported)
  );

  mrtc_k_policy_engine #(
    .MRTC_K_POLICY_ARCH(MRTC_K_POLICY_ARCH),
    .PREFIX_DURING_CAPTURE(PREFIX_DURING_CAPTURE),
    .PREFIX_STREAM_LENGTH_BY_TLAST(PREFIX_STREAM_LENGTH_BY_TLAST),
    .PREFIX_SAMPLES    (PREFIX_SAMPLES),
    .BLOCK_SAMPLES     (MRTC_BLOCK_SAMPLES),
    .RAW_BYTES         (MRTC_RAW_BYTES),
    .HEADER_BYTES      (MRTC_HEADER_BYTES),
    .ADDR_W            (10)
  ) u_k_policy_engine (
    .clk               (clk),
    .rst_n             (rst_n),
    .i_start           (ksel_start),
    .i_codec_mode      (proc_codec_mode),
    .i_rice_mode       (proc_rice_mode),
    .i_fixed_k         (proc_fixed_k),
    .i_prefix_precomputed_valid(proc_prefix_precomputed_valid),
    .i_prefix_precomputed_k(proc_prefix_precomputed_k),
    .i_prefix_precomputed_bits(proc_prefix_precomputed_bits),
    .i_prefix_precomputed_cycles(proc_prefix_precomputed_cycles),
    .i_prefix_precomputed_unsupported(proc_prefix_precomputed_unsupported),
    .o_rd_req          (ksel_rd_req),
    .o_rd_addr         (ksel_rd_addr),
    .i_rd_valid        (ksel_rd_valid),
    .i_rd_data         (ksel_rd_data),
    .o_busy            (ksel_busy),
    .o_done            (ksel_done),
    .o_selected_k      (ksel_selected_k),
    .o_payload_bits    (ksel_payload_bits),
    .o_payload_bytes   (ksel_payload_bytes),
    .o_use_raw         (ksel_use_raw),
    .o_unsupported_rice(ksel_unsupported_rice),
    .o_prefix_fast_active(ksel_prefix_fast_active),
    .o_prefix_bits     (ksel_prefix_bits),
    .o_prefix_cycles   (ksel_prefix_cycles),
    .o_size_count_cycles(ksel_size_count_cycles),
    .o_total_policy_cycles(ksel_total_policy_cycles)
  );

  generate
    if (MRTC_BPACK_ARCH == MRTC_BPACK_ARCH_LANE_WORD) begin : g_lane_word_bpack
      assign legacy_bpack_busy                     = 1'b0;
      assign legacy_bpack_done                     = 1'b0;
      assign legacy_bpack_rd_req                   = 1'b0;
      assign legacy_bpack_rd_addr                  = '0;
      assign legacy_bpack_axis_tdata               = '0;
      assign legacy_bpack_axis_tvalid              = 1'b0;
      assign legacy_bpack_axis_tlast               = 1'b0;
      assign legacy_bpack_axis_tvalid_bytes_minus1 = '0;
      assign legacy_bpack_payload_bits_counted     = 32'd0;
      assign legacy_bpack_payload_bytes_counted    = 32'd0;
      assign legacy_bpack_count_mismatch           = 1'b0;
      assign legacy_bpack_overflow                 = 1'b0;

      mrtc_rice_bitpacker_lane_axis #(
        .AXIS_DATA_W      (AXIS_DATA_W),
        .LANES            (MRTC_LANES),
        .BLOCK_SAMPLES    (MRTC_BLOCK_SAMPLES),
        .ADDR_W           (10),
        .PACKER_LANE_MODE (PACKER_LANE_MODE)
      ) u_rice_bitpacker_lane_axis (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .i_start                   (bpack_start),
        .i_codec_mode              (proc_codec_mode),
        .i_selected_k              (selected_k_reg),
        .o_word_rd_req             (lane_bpack_word_rd_req),
        .o_word_rd_addr_base       (lane_bpack_word_rd_addr),
        .i_word_rd_valid           (lane_bpack_word_rd_valid),
        .i_word_rd_data            (lane_bpack_word_rd_data),
        .m_axis_tdata              (lane_bpack_axis_tdata),
        .m_axis_tvalid             (lane_bpack_axis_tvalid),
        .m_axis_tready             (bpack_axis_tready),
        .m_axis_tlast              (lane_bpack_axis_tlast),
        .m_axis_tvalid_bytes_minus1(lane_bpack_axis_tvalid_bytes_minus1),
        .o_busy                    (lane_bpack_busy),
        .o_done                    (lane_bpack_done),
        .o_payload_bits_counted    (lane_bpack_payload_bits_counted),
        .o_payload_bytes_counted   (lane_bpack_payload_bytes_counted),
        .o_overflow                (lane_bpack_overflow),
        .o_long_unary_used         (lane_bpack_long_unary_used),
        .o_group_fallback_used     (lane_bpack_group_fallback_used)
      );
    end else begin : g_legacy_sample_bpack
      assign lane_bpack_busy                     = 1'b0;
      assign lane_bpack_done                     = 1'b0;
      assign lane_bpack_word_rd_req              = 1'b0;
      assign lane_bpack_word_rd_addr             = '0;
      assign lane_bpack_axis_tdata               = '0;
      assign lane_bpack_axis_tvalid              = 1'b0;
      assign lane_bpack_axis_tlast               = 1'b0;
      assign lane_bpack_axis_tvalid_bytes_minus1 = '0;
      assign lane_bpack_payload_bits_counted     = 32'd0;
      assign lane_bpack_payload_bytes_counted    = 32'd0;
      assign lane_bpack_overflow                 = 1'b0;
      assign lane_bpack_long_unary_used          = 1'b0;
      assign lane_bpack_group_fallback_used      = 1'b0;

      mrtc_rice_bitpacker_axis #(
        .AXIS_DATA_W  (AXIS_DATA_W),
        .BLOCK_SAMPLES(MRTC_BLOCK_SAMPLES),
        .ADDR_W       (10),
        .FRAG_W       (32)
      ) u_rice_bitpacker_axis (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .i_start                    (bpack_start),
        .i_codec_mode               (proc_codec_mode),
        .i_selected_k               (selected_k_reg),
        .i_expected_length_valid    (bpack_expected_length_valid),
        .i_expected_payload_bits    (payload_bits_pre_reg),
        .i_expected_payload_bytes   (payload_bytes_pre_reg),
        .o_rd_req                   (legacy_bpack_rd_req),
        .o_rd_addr                  (legacy_bpack_rd_addr),
        .i_rd_valid                 (legacy_bpack_rd_valid),
        .i_rd_data                  (legacy_bpack_rd_data),
        .m_axis_tdata               (legacy_bpack_axis_tdata),
        .m_axis_tvalid              (legacy_bpack_axis_tvalid),
        .m_axis_tready              (bpack_axis_tready),
        .m_axis_tlast               (legacy_bpack_axis_tlast),
        .m_axis_tvalid_bytes_minus1 (legacy_bpack_axis_tvalid_bytes_minus1),
        .o_busy                     (legacy_bpack_busy),
        .o_done                     (legacy_bpack_done),
        .o_payload_bits_counted     (legacy_bpack_payload_bits_counted),
        .o_payload_bytes_counted    (legacy_bpack_payload_bytes_counted),
        .o_count_mismatch           (legacy_bpack_count_mismatch),
        .o_overflow                 (legacy_bpack_overflow)
      );
    end
  endgenerate

  always_comb begin
    header_flags = 16'd0;
    if (use_raw_pre_reg) begin
      header_flags = header_flags | MRTC_FLAG_RAW_BYPASS;
    end else if ((proc_codec_mode == MRTC_CODEC_ZERO_RICE) ||
                 (proc_codec_mode == MRTC_CODEC_DELTA_RICE)) begin
      header_flags = header_flags | MRTC_FLAG_SAMPLE_MAJOR_IQ;
    end
    if (proc_last_block) begin
      header_flags = header_flags | MRTC_FLAG_LAST_BLOCK;
    end
    if ((MRTC_K_POLICY_ARCH == MRTC_K_POLICY_FULL_ADAPTIVE) &&
        (proc_rice_mode == MRTC_RICE_BLOCK_ADAPTIVE_K)) begin
      header_flags = header_flags | MRTC_FLAG_BLOCK_ADAPTIVE_K;
    end
    if (prefix_fast_active_reg && !use_raw_pre_reg) begin
      header_flags = header_flags | MRTC_FLAG_PREFIX_K_FAST;
      if (PREFIX_STREAM_LENGTH_BY_TLAST) begin
        header_flags = header_flags | MRTC_FLAG_STREAM_LENGTH_BY_TLAST;
      end
    end
  end

  assign raw_bytes_u32            = 32'(MRTC_RAW_BYTES);
  assign prefix_stream_length_active = prefix_fast_active_reg && !use_raw_pre_reg && PREFIX_STREAM_LENGTH_BY_TLAST;
  assign payload_bytes_for_header = use_raw_pre_reg ? raw_bytes_u32 :
                                    (prefix_stream_length_active ? 32'd0 : payload_bytes_pre_reg);
  assign payload_bits_for_header  = use_raw_pre_reg ? 32'(MRTC_RAW_BYTES * 8) :
                                    (prefix_stream_length_active ? 32'd0 : payload_bits_pre_reg);
  assign bpack_expected_length_valid = !prefix_stream_length_active;

  mrtc_header_gen u_header_gen (
    .i_frame_id            (proc_frame_id),
    .i_block_id            (proc_block_id),
    .i_tensor_spatial_size (proc_tensor_spatial_size),
    .i_tensor_doppler_size (proc_tensor_doppler_size),
    .i_tensor_range_size   (proc_tensor_range_size),
    .i_block_spatial_start (16'd0),
    .i_block_doppler_start (16'd0),
    .i_block_range_start   (proc_block_range_start),
    .i_block_spatial_len   (8'(MRTC_BLOCK_SPATIAL_LEN)),
    .i_block_doppler_len   (8'(MRTC_BLOCK_DOPPLER_LEN)),
    .i_block_range_len     (16'(MRTC_BLOCK_RANGE_LEN)),
    .i_sample_format       (8'(MRTC_SAMPLE_I16Q16)),
    .i_codec_mode          (use_raw_pre_reg ? MRTC_CODEC_RAW : proc_codec_mode),
    .i_predictor_mode      (proc_codec_mode),
    .i_rice_k              (selected_k_reg),
    .i_flags               (header_flags),
    .i_raw_bytes           (raw_bytes_u32),
    .i_payload_bytes       (payload_bytes_for_header),
    .i_payload_bits        (payload_bits_for_header),
    .i_crc32               (32'd0),
    .o_header_bytes_flat   (header_bytes_flat)
  );

  mrtc_header_axis_streamer #(
    .AXIS_DATA_W (AXIS_DATA_W),
    .HEADER_BYTES(MRTC_HEADER_BYTES)
  ) u_header_axis_streamer (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .i_start                 (header_start),
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

  mrtc_raw_bank_axis_streamer #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .BLOCK_WORDS(BLOCK_WORDS)
  ) u_raw_bank_axis_streamer (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .i_start                  (raw_start),
    .o_bank_rd_req            (raw_bank_rd_req),
    .o_bank_rd_word_addr      (raw_bank_rd_word_addr),
    .i_bank_rd_valid          (raw_bank_rd_valid),
    .i_bank_rd_word_data      (raw_bank_rd_word_data),
    .m_axis_tdata             (raw_axis_tdata),
    .m_axis_tvalid            (raw_axis_tvalid),
    .m_axis_tready            (raw_axis_tready),
    .m_axis_tlast             (raw_axis_tlast),
    .m_axis_tvalid_bytes_minus1(raw_axis_tvalid_bytes_minus1),
    .o_busy                   (raw_busy),
    .o_done                   (raw_done)
  );

  always_comb begin
    sample_rd_req_mux          = 1'b0;
    sample_rd_addr_mux         = '0;
    bank_rd_req                = 1'b0;
    bank_rd_word_addr          = '0;
    sample_bank_rd_valid       = 1'b0;
    sample_bank_rd_word_data   = bank_rd_word_data;
    raw_bank_rd_valid          = 1'b0;
    raw_bank_rd_word_data      = bank_rd_word_data;
    internal_state_error_pulse = 1'b0;

    if (bank_wr_en && proc_active_valid && (fill_bank_sel == proc_active_bank_sel)) begin
      internal_state_error_pulse = 1'b1;
    end

    lane_bpack_word_rd_valid    = 1'b0;
    raw_bank_rd_word_data       = bank_rd_word_data;

    if (ksel_rd_req && legacy_bpack_rd_req) begin
      internal_state_error_pulse = 1'b1;
    end else if (ksel_rd_req) begin
      sample_rd_req_mux  = 1'b1;
      sample_rd_addr_mux = ksel_rd_addr;
    end else if (legacy_bpack_rd_req) begin
      sample_rd_req_mux  = 1'b1;
      sample_rd_addr_mux = legacy_bpack_rd_addr;
    end

    if ((sample_bank_rd_req && raw_bank_rd_req) ||
        (sample_bank_rd_req && lane_bpack_word_rd_req) ||
        (raw_bank_rd_req && lane_bpack_word_rd_req)) begin
      internal_state_error_pulse = 1'b1;
    end else if ((bank_owner_reg == BANK_OWNER_NONE) || bank_owner_accept_same_owner_now) begin
      if (!proc_active_valid && (sample_bank_rd_req || raw_bank_rd_req || lane_bpack_word_rd_req)) begin
        internal_state_error_pulse = 1'b1;
      end else if (sample_bank_rd_req) begin
        bank_rd_req       = 1'b1;
        bank_rd_word_addr = sample_bank_rd_word_addr;
      end else if (raw_bank_rd_req) begin
        bank_rd_req       = 1'b1;
        bank_rd_word_addr = raw_bank_rd_word_addr;
      end else if (lane_bpack_word_rd_req) begin
        bank_rd_req       = 1'b1;
        bank_rd_word_addr = lane_bpack_word_rd_addr;
      end
    end else if (sample_bank_rd_req || raw_bank_rd_req || lane_bpack_word_rd_req) begin
      internal_state_error_pulse = 1'b1;
    end

    if (bank0_rd_valid && bank1_rd_valid) begin
      internal_state_error_pulse = 1'b1;
    end

    if ((bank0_rd_valid || bank1_rd_valid) && !proc_active_valid) begin
      internal_state_error_pulse = 1'b1;
    end

    if (bank_rd_valid) begin
      if (bank_owner_reg == BANK_OWNER_SAMPLE) begin
        sample_bank_rd_valid = 1'b1;
      end else if (bank_owner_reg == BANK_OWNER_RAW) begin
        raw_bank_rd_valid = 1'b1;
      end else if (bank_owner_reg == BANK_OWNER_BPACK_WORD) begin
        lane_bpack_word_rd_valid = 1'b1;
      end else begin
        internal_state_error_pulse = 1'b1;
      end
    end

    if (sample_rd_valid && (sample_client_reg == SAMPLE_CLIENT_NONE)) begin
      internal_state_error_pulse = 1'b1;
    end
  end

  always_comb begin
    m_axis_comp_tdata  = '0;
    m_axis_comp_tvalid = 1'b0;
    m_axis_comp_tlast  = 1'b0;
    m_axis_comp_tuser  = '0;
    header_axis_tready = 1'b0;
    raw_axis_tready    = 1'b0;
    bpack_axis_tready  = 1'b0;

    case (state_reg)
      ST_HEADER_STREAM: begin
        m_axis_comp_tdata      = header_axis_tdata;
        m_axis_comp_tvalid     = header_axis_tvalid;
        m_axis_comp_tlast      = header_axis_tlast;
        m_axis_comp_tuser[3:0] = header_axis_tvalid_bytes_minus1[3:0];
        header_axis_tready     = m_axis_comp_tready;
      end

      ST_RAW_STREAM: begin
        m_axis_comp_tdata      = raw_axis_tdata;
        m_axis_comp_tvalid     = raw_axis_tvalid;
        m_axis_comp_tlast      = raw_axis_tlast;
        m_axis_comp_tuser[3:0] = raw_axis_tvalid_bytes_minus1[3:0];
        raw_axis_tready        = m_axis_comp_tready;
      end

      ST_BPACK_STREAM: begin
        m_axis_comp_tdata      = bpack_axis_tdata;
        m_axis_comp_tvalid     = bpack_axis_tvalid;
        m_axis_comp_tlast      = bpack_axis_tlast;
        m_axis_comp_tuser[3:0] = bpack_axis_tvalid_bytes_minus1[3:0];
        bpack_axis_tready      = m_axis_comp_tready;
      end

      default: begin
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    integer bank_idx;
    if (!rst_n) begin
      state_reg                <= ST_CAPTURE;
      bank_owner_reg           <= BANK_OWNER_NONE;
      sample_client_reg        <= SAMPLE_CLIENT_NONE;
      payload_bits_post        <= 32'd0;
      payload_bytes_post       <= 32'd0;
      selected_k_reg           <= 8'd0;
      payload_bits_pre_reg     <= 32'd0;
      payload_bytes_pre_reg    <= 32'd0;
      use_raw_pre_reg          <= 1'b0;
      unsupported_rice_reg     <= 1'b0;
      prefix_fast_active_reg   <= 1'b0;
      prefix_bits_reg          <= 32'd0;
      k_policy_cycles_reg      <= 32'd0;
      k_policy_size_cycles_reg <= 32'd0;
      k_policy_total_cycles_reg <= 32'd0;
      stat_done                <= 1'b0;
      stat_comp_bytes          <= '0;
      stat_raw_bytes           <= '0;
      stat_num_blocks          <= '0;
      stat_error_reg           <= MRTC_ERR_NONE;
      stat_raw_bypass_blocks   <= '0;
      stat_stall_input_cycles  <= '0;
      stat_stall_output_cycles <= '0;
      prefix_buf_bank0_ready_reg <= 1'b0;
      prefix_buf_bank1_ready_reg <= 1'b0;
      block_ready_to_k_done_dbg <= 32'd0;
      for (bank_idx = 0; bank_idx < 2; bank_idx = bank_idx + 1) begin
        prefix_codec_mode_reg_bank[bank_idx] <= 8'd0;
        prefix_result_valid_reg[bank_idx] <= 1'b0;
        prefix_selected_k_reg_bank[bank_idx] <= 8'd0;
        prefix_bits_reg_bank[bank_idx] <= 32'd0;
        prefix_cycles_reg_bank[bank_idx] <= 32'd0;
        prefix_unsupported_reg_bank[bank_idx] <= 1'b0;
      end
    end else begin
      stat_done <= 1'b0;

      if (bank_rd_valid) begin
        if (!bank_owner_accept_same_owner_now) begin
          bank_owner_reg <= BANK_OWNER_NONE;
        end
      end
      if (sample_rd_valid) begin
        sample_client_reg <= SAMPLE_CLIENT_NONE;
      end
      if ((bank_owner_reg == BANK_OWNER_NONE) &&
          sample_bank_rd_req && !raw_bank_rd_req && !lane_bpack_word_rd_req) begin
        bank_owner_reg <= BANK_OWNER_SAMPLE;
        if (ksel_rd_req) begin
          sample_client_reg <= SAMPLE_CLIENT_KSEL;
        end else if (legacy_bpack_rd_req) begin
          sample_client_reg <= SAMPLE_CLIENT_BPACK;
        end
      end else if ((bank_owner_reg == BANK_OWNER_NONE) &&
                   raw_bank_rd_req && !sample_bank_rd_req && !lane_bpack_word_rd_req) begin
        bank_owner_reg <= BANK_OWNER_RAW;
      end else if ((bank_owner_reg == BANK_OWNER_NONE) &&
                   lane_bpack_word_rd_req && !sample_bank_rd_req && !raw_bank_rd_req) begin
        bank_owner_reg <= BANK_OWNER_BPACK_WORD;
      end

      if (i_clear_status) begin
        stat_comp_bytes          <= '0;
        stat_raw_bytes           <= '0;
        stat_num_blocks          <= '0;
        stat_error_reg           <= MRTC_ERR_NONE;
        stat_raw_bypass_blocks   <= '0;
        stat_stall_input_cycles  <= '0;
        stat_stall_output_cycles <= '0;
      end

      if (s_axis_raw_tvalid && !s_axis_raw_tready) begin
        stat_stall_input_cycles <= stat_stall_input_cycles + 32'd1;
      end
      if (m_axis_comp_tvalid && !m_axis_comp_tready) begin
        stat_stall_output_cycles <= stat_stall_output_cycles + 32'd1;
      end

      if (bank_manager_error != MRTC_ERR_NONE) begin
        stat_error_reg <= bank_manager_error;
      end else if (ksel_done && ksel_unsupported_rice) begin
        stat_error_reg <= MRTC_ERR_UNSUPPORTED_RICE;
      end else if (bpack_done && bpack_overflow) begin
        stat_error_reg <= MRTC_ERR_PAYLOAD_TOO_LONG;
      end else if (bpack_done && bpack_count_mismatch) begin
        stat_error_reg <= MRTC_ERR_INTERNAL_STATE;
      end else if (internal_state_error_pulse) begin
        stat_error_reg <= MRTC_ERR_INTERNAL_STATE;
      end

      if (ksel_done) begin
        selected_k_reg        <= ksel_selected_k;
        payload_bits_pre_reg  <= ksel_payload_bits;
        payload_bytes_pre_reg <= ksel_payload_bytes;
        use_raw_pre_reg       <= ksel_use_raw;
        unsupported_rice_reg  <= ksel_unsupported_rice;
        prefix_fast_active_reg <= ksel_prefix_fast_active;
        prefix_bits_reg        <= ksel_prefix_bits;
        k_policy_cycles_reg    <= ksel_prefix_cycles;
        k_policy_size_cycles_reg <= ksel_size_count_cycles;
        k_policy_total_cycles_reg <= ksel_total_policy_cycles;
        block_ready_to_k_done_dbg <= ksel_total_policy_cycles + 32'd3;
      end

      if (bank_wr_en && (fill_word_addr == BLOCK_WORD_ADDR_W'(0))) begin
        if (!fill_bank_sel) begin
          prefix_buf_bank0_ready_reg <= 1'b0;
          prefix_codec_mode_reg_bank[0] <= {6'd0, s_axis_raw_tuser[2:1]};
          prefix_result_valid_reg[0] <= 1'b0;
          prefix_selected_k_reg_bank[0] <= 8'd0;
          prefix_bits_reg_bank[0] <= 32'd0;
          prefix_cycles_reg_bank[0] <= 32'd0;
          prefix_unsupported_reg_bank[0] <= 1'b0;
        end else begin
          prefix_buf_bank1_ready_reg <= 1'b0;
          prefix_codec_mode_reg_bank[1] <= {6'd0, s_axis_raw_tuser[2:1]};
          prefix_result_valid_reg[1] <= 1'b0;
          prefix_selected_k_reg_bank[1] <= 8'd0;
          prefix_bits_reg_bank[1] <= 32'd0;
          prefix_cycles_reg_bank[1] <= 32'd0;
          prefix_unsupported_reg_bank[1] <= 1'b0;
        end
      end

      if (prefix_buf0_wr_en && (fill_word_addr == BLOCK_WORD_ADDR_W'(PREFIX_WORDS - 1))) begin
        prefix_buf_bank0_ready_reg <= 1'b1;
      end
      if (prefix_buf1_wr_en && (fill_word_addr == BLOCK_WORD_ADDR_W'(PREFIX_WORDS - 1))) begin
        prefix_buf_bank1_ready_reg <= 1'b1;
      end

      if (prefix_pre_done) begin
        prefix_result_valid_reg[prefix_pre_result_bank_sel] <= 1'b1;
        prefix_selected_k_reg_bank[prefix_pre_result_bank_sel] <= prefix_pre_selected_k;
        prefix_bits_reg_bank[prefix_pre_result_bank_sel] <= prefix_pre_bits;
        prefix_cycles_reg_bank[prefix_pre_result_bank_sel] <= prefix_pre_cycles;
        prefix_unsupported_reg_bank[prefix_pre_result_bank_sel] <= prefix_pre_unsupported;
      end

      if (proc_done_pulse && proc_active_valid) begin
        prefix_result_valid_reg[proc_active_bank_sel] <= 1'b0;
        prefix_selected_k_reg_bank[proc_active_bank_sel] <= 8'd0;
        prefix_bits_reg_bank[proc_active_bank_sel] <= 32'd0;
        prefix_cycles_reg_bank[proc_active_bank_sel] <= 32'd0;
        prefix_unsupported_reg_bank[proc_active_bank_sel] <= 1'b0;
        if (!proc_active_bank_sel) begin
          prefix_buf_bank0_ready_reg <= 1'b0;
        end else begin
          prefix_buf_bank1_ready_reg <= 1'b0;
        end
      end

      if (bpack_done) begin
        payload_bits_post  <= bpack_payload_bits_counted;
        payload_bytes_post <= bpack_payload_bytes_counted;
      end

      case (state_reg)
        ST_CAPTURE: begin
          if (proc_ready_valid && !ready_prefix_wait_needed) begin
            unsupported_rice_reg  <= 1'b0;
            use_raw_pre_reg       <= 1'b0;
            payload_bits_pre_reg  <= 32'd0;
            payload_bytes_pre_reg <= 32'd0;
            payload_bits_post     <= 32'd0;
            payload_bytes_post    <= 32'd0;
            selected_k_reg        <= 8'd0;
            prefix_fast_active_reg <= 1'b0;
            prefix_bits_reg        <= 32'd0;
            k_policy_cycles_reg    <= 32'd0;
            k_policy_size_cycles_reg <= 32'd0;
            k_policy_total_cycles_reg <= 32'd0;
            state_reg             <= ST_KSEL_START;
          end
        end

        ST_KSEL_START: begin
          state_reg <= ST_KSEL_WAIT;
        end

        ST_KSEL_WAIT: begin
          if (proc_prefix_wait_needed) begin
            state_reg <= ST_KSEL_WAIT;
          end else if (ksel_done) begin
            state_reg <= ST_HEADER_START;
          end
        end

        ST_HEADER_START: begin
          state_reg <= ST_HEADER_STREAM;
        end

        ST_HEADER_STREAM: begin
          if (header_done) begin
            if (use_raw_pre_reg) begin
              state_reg <= ST_RAW_START;
            end else begin
              state_reg <= ST_BPACK_START;
            end
          end
        end

        ST_RAW_START: begin
          state_reg <= ST_RAW_STREAM;
        end

        ST_RAW_STREAM: begin
          if (raw_done) begin
            state_reg <= ST_DRAIN;
          end
        end

        ST_BPACK_START: begin
          state_reg <= ST_BPACK_STREAM;
        end

        ST_BPACK_STREAM: begin
          if (bpack_done) begin
            state_reg <= ST_DRAIN;
          end
        end

        ST_DRAIN: begin
          stat_done       <= 1'b1;
          stat_comp_bytes <= MRTC_HEADER_BYTES + (use_raw_pre_reg ? MRTC_RAW_BYTES : payload_bytes_post);
          stat_raw_bytes  <= MRTC_RAW_BYTES;
          stat_num_blocks <= stat_num_blocks + 32'd1;
          if (use_raw_pre_reg) begin
            stat_raw_bypass_blocks <= stat_raw_bypass_blocks + 32'd1;
          end
          state_reg <= ST_ADVANCE;
        end

        ST_ADVANCE: begin
          state_reg <= ST_CAPTURE;
        end

        default: begin
          state_reg <= ST_CAPTURE;
        end
      endcase
    end
  end
endmodule
