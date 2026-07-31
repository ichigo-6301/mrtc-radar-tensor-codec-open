module mrtc_rdtc_engine_lane #(
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = mrtc_pkg::MRTC_COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int COMP_BLOCK_BYTES = mrtc_pkg::MRTC_COMP_BLOCK_BYTES,
  parameter int PREFIX_COMPLEX_SAMPLES = mrtc_pkg::MRTC_PREFIX_COMPLEX_SAMPLES,
  parameter int STREAMING_PREFIX_SAMPLES = 128,
  parameter int BOUNDED_WAY_COUNT = 4
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_soft_reset,
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
  input  logic [15:0]            cfg_block_id,
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
  logic engine_rst_n;

  assign engine_rst_n = rst_n && !i_soft_reset;

`ifdef RDTC_FULL_BLOCK_SINGLE_BANK_PREFIX
`ifndef RDTC_FULL_BLOCK_ENCODER
  initial begin
    $fatal(1, "RDTC_FULL_BLOCK_SINGLE_BANK_PREFIX requires RDTC_FULL_BLOCK_ENCODER");
  end
`endif
`endif

`ifdef RDTC_BOUNDED_HT_WAY_RING
  mrtc_rdtc_encoder_bounded_ht #(
    .AXIS_DATA_W      (AXIS_DATA_W),
    .WAY_COUNT        (BOUNDED_WAY_COUNT),
    .WAY_DEPTH_WORDS  (32),
    .PREFIX_SAMPLES   (STREAMING_PREFIX_SAMPLES)
  ) u_engine (
    .clk,
    .rst_n(engine_rst_n),
    .i_clear_status,
    .s_axis_raw_tdata,
    .s_axis_raw_tvalid,
    .s_axis_raw_tready,
    .s_axis_raw_tlast,
    .s_axis_raw_tuser,
    .m_axis_comp_tdata,
    .m_axis_comp_tvalid,
    .m_axis_comp_tready,
    .m_axis_comp_tlast,
    .m_axis_comp_tuser,
    .cfg_codec_mode,
    .cfg_rice_mode,
    .cfg_fixed_k,
    .cfg_frame_id,
    .cfg_block_id_base(cfg_block_id),
    .cfg_tensor_spatial_size,
    .cfg_tensor_doppler_size,
    .cfg_tensor_range_size,
    .stat_busy,
    .stat_done,
    .stat_raw_bytes,
    .stat_comp_bytes,
    .stat_num_blocks,
    .stat_error,
    .stat_raw_bypass_blocks,
    .stat_stall_input_cycles,
    .stat_stall_output_cycles
  );
`elsif RDTC_FULL_BLOCK_ENCODER
`ifdef RDTC_FULL_BLOCK_SINGLE_BANK_PREFIX
  localparam int FULL_BLOCK_K_POLICY_ARCH = mrtc_pkg::MRTC_K_POLICY_PREFIX_FAST;
  localparam int FULL_BLOCK_BPACK_ARCH = mrtc_pkg::MRTC_BPACK_ARCH_LANE_WORD;
  localparam bit FULL_BLOCK_PREFIX_DURING_CAPTURE = 1'b1;
  localparam bit FULL_BLOCK_PREFIX_STREAM_LENGTH_BY_TLAST = 1'b1;
  localparam int FULL_BLOCK_PREFIX_SAMPLES = STREAMING_PREFIX_SAMPLES;
  localparam bit FULL_BLOCK_SINGLE_BANK = 1'b1;
  localparam bit FULL_BLOCK_STREAMING_PREFIX_K = 1'b1;
  localparam bit FULL_BLOCK_ELASTIC_WORD_ISSUE = 1'b1;
`else
  localparam int FULL_BLOCK_K_POLICY_ARCH = mrtc_pkg::MRTC_K_POLICY_FULL_ADAPTIVE;
`ifdef RDTC_FULL_BLOCK_LANE_WORD_BPACK
  localparam int FULL_BLOCK_BPACK_ARCH = mrtc_pkg::MRTC_BPACK_ARCH_LANE_WORD;
`else
  localparam int FULL_BLOCK_BPACK_ARCH = mrtc_pkg::MRTC_BPACK_ARCH_LEGACY_SAMPLE;
`endif
  localparam bit FULL_BLOCK_PREFIX_DURING_CAPTURE = 1'b0;
  localparam bit FULL_BLOCK_PREFIX_STREAM_LENGTH_BY_TLAST = 1'b0;
  localparam int FULL_BLOCK_PREFIX_SAMPLES = PREFIX_COMPLEX_SAMPLES;
  localparam bit FULL_BLOCK_SINGLE_BANK = 1'b0;
  localparam bit FULL_BLOCK_STREAMING_PREFIX_K = 1'b0;
  localparam bit FULL_BLOCK_ELASTIC_WORD_ISSUE = 1'b0;
`endif

  mrtc_rdtc_encoder_top #(
    .AXIS_DATA_W               (AXIS_DATA_W),
    .MRTC_K_POLICY_ARCH        (FULL_BLOCK_K_POLICY_ARCH),
    .MRTC_BPACK_ARCH           (FULL_BLOCK_BPACK_ARCH),
    .PACKER_LANE_MODE          (PHASES_PER_BEAT),
    .PREFIX_DURING_CAPTURE     (FULL_BLOCK_PREFIX_DURING_CAPTURE),
    .PREFIX_STREAM_LENGTH_BY_TLAST(FULL_BLOCK_PREFIX_STREAM_LENGTH_BY_TLAST),
    .PREFIX_SAMPLES            (FULL_BLOCK_PREFIX_SAMPLES),
    .SINGLE_FULL_BLOCK_BANK    (FULL_BLOCK_SINGLE_BANK),
    .STREAMING_PREFIX_K        (FULL_BLOCK_STREAMING_PREFIX_K),
    .ELASTIC_WORD_ISSUE        (FULL_BLOCK_ELASTIC_WORD_ISSUE)
  ) u_engine (
    .clk,
    .rst_n(engine_rst_n),
    .i_clear_status,
    .s_axis_raw_tdata,
    .s_axis_raw_tvalid,
    .s_axis_raw_tready,
    .s_axis_raw_tlast,
    .s_axis_raw_tuser,
    .m_axis_comp_tdata,
    .m_axis_comp_tvalid,
    .m_axis_comp_tready,
    .m_axis_comp_tlast,
    .m_axis_comp_tuser,
    .cfg_codec_mode,
    .cfg_rice_mode,
    .cfg_fixed_k,
    .cfg_frame_id,
    .cfg_block_id_base(cfg_block_id),
    .cfg_tensor_spatial_size,
    .cfg_tensor_doppler_size,
    .cfg_tensor_range_size,
    .stat_busy,
    .stat_done,
    .stat_raw_bytes,
    .stat_comp_bytes,
    .stat_num_blocks,
    .stat_error,
    .stat_raw_bypass_blocks,
    .stat_stall_input_cycles,
    .stat_stall_output_cycles
  );
`else
  mrtc_rdtc_encoder_top_axis_bp_smallbuf #(
    .PHASES_PER_BEAT           (PHASES_PER_BEAT),
    .AXIS_DATA_W               (AXIS_DATA_W),
    .COMP_BLOCK_BYTES          (COMP_BLOCK_BYTES),
    .PREFIX_COMPLEX_SAMPLES    (PREFIX_COMPLEX_SAMPLES),
    .ENABLE_INTERNAL_RAW_BYPASS(1'b0)
  ) u_engine (
    .clk,
    .rst_n(engine_rst_n),
    .i_clear_status,
    .s_axis_raw_tdata,
    .s_axis_raw_tvalid,
    .s_axis_raw_tready,
    .s_axis_raw_tlast,
    .s_axis_raw_tuser,
    .m_axis_comp_tdata,
    .m_axis_comp_tvalid,
    .m_axis_comp_tready,
    .m_axis_comp_tlast,
    .m_axis_comp_tuser,
    .cfg_codec_mode,
    .cfg_rice_mode,
    .cfg_fixed_k,
    .cfg_frame_id,
    .cfg_block_id_base(cfg_block_id),
    .cfg_tensor_spatial_size,
    .cfg_tensor_doppler_size,
    .cfg_tensor_range_size,
    .stat_busy,
    .stat_done,
    .stat_raw_bytes,
    .stat_comp_bytes,
    .stat_num_blocks,
    .stat_error,
    .stat_raw_bypass_blocks,
    .stat_stall_input_cycles,
    .stat_stall_output_cycles
  );
`endif
endmodule
