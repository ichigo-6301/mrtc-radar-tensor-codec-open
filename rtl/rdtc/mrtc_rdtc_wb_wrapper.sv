module mrtc_rdtc_wb_wrapper #(
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = mrtc_pkg::MRTC_COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int TUSER_W = 8,
  parameter int COMP_BLOCK_BYTES = mrtc_pkg::MRTC_COMP_BLOCK_BYTES
) (
  input logic clk,
  input logic rst_n,
  input logic i_clear_status,

  input logic job0_valid,
  output logic job0_ready,
  input logic [31:0] job0_id,
  input logic [7:0] job0_codec_mode,
  input logic [7:0] job0_rice_mode,
  input logic [3:0] job0_fixed_k,
  input logic [15:0] job0_frame_id,
  input logic [15:0] job0_block_id,
  input logic [15:0] job0_tensor_spatial_size,
  input logic [15:0] job0_tensor_doppler_size,
  input logic [15:0] job0_tensor_range_size,
  input logic job0_last_block,
  input logic job1_valid,
  output logic job1_ready,
  input logic [31:0] job1_id,
  input logic [7:0] job1_codec_mode,
  input logic [7:0] job1_rice_mode,
  input logic [3:0] job1_fixed_k,
  input logic [15:0] job1_frame_id,
  input logic [15:0] job1_block_id,
  input logic [15:0] job1_tensor_spatial_size,
  input logic [15:0] job1_tensor_doppler_size,
  input logic [15:0] job1_tensor_range_size,
  input logic job1_last_block,

  input logic [AXIS_DATA_W-1:0] s0_axis_tdata,
  input logic s0_axis_tvalid,
  output logic s0_axis_tready,
  input logic s0_axis_tlast,
  input logic [TUSER_W-1:0] s0_axis_tuser,
  output logic [AXIS_DATA_W-1:0] m0_axis_tdata,
  output logic m0_axis_tvalid,
  input logic m0_axis_tready,
  output logic m0_axis_tlast,
  output logic [TUSER_W-1:0] m0_axis_tuser,
  input logic [AXIS_DATA_W-1:0] s1_axis_tdata,
  input logic s1_axis_tvalid,
  output logic s1_axis_tready,
  input logic s1_axis_tlast,
  input logic [TUSER_W-1:0] s1_axis_tuser,
  output logic [AXIS_DATA_W-1:0] m1_axis_tdata,
  output logic m1_axis_tvalid,
  input logic m1_axis_tready,
  output logic m1_axis_tlast,
  output logic [TUSER_W-1:0] m1_axis_tuser,

  output logic completion0_valid,
  input logic completion0_ready,
  output logic [31:0] completion0_job_id,
  output logic [31:0] completion0_raw_bytes,
  output logic [31:0] completion0_comp_bytes,
  output logic [31:0] completion0_error,
  output logic completion1_valid,
  input logic completion1_ready,
  output logic [31:0] completion1_job_id,
  output logic [31:0] completion1_raw_bytes,
  output logic [31:0] completion1_comp_bytes,
  output logic [31:0] completion1_error,

  output logic lane0_job_active,
  output logic lane1_job_active,
  output logic lane0_busy,
  output logic lane1_busy,
  output logic [31:0] lane0_num_blocks,
  output logic [31:0] lane1_num_blocks,
  output logic [31:0] lane0_error,
  output logic [31:0] lane1_error,
  output logic [31:0] lane0_input_stall_cycles,
  output logic [31:0] lane1_input_stall_cycles,
  output logic [31:0] lane0_output_stall_cycles,
  output logic [31:0] lane1_output_stall_cycles
);
  logic [AXIS_DATA_W-1:0] core_s0_tdata;
  logic core_s0_tvalid;
  logic core_s0_tready;
  logic core_s0_tlast;
  logic [TUSER_W-1:0] core_s0_tuser;
  logic [AXIS_DATA_W-1:0] core_m0_tdata;
  logic core_m0_tvalid;
  logic core_m0_tready;
  logic core_m0_tlast;
  logic [TUSER_W-1:0] core_m0_tuser;
  logic [AXIS_DATA_W-1:0] core_s1_tdata;
  logic core_s1_tvalid;
  logic core_s1_tready;
  logic core_s1_tlast;
  logic [TUSER_W-1:0] core_s1_tuser;
  logic [AXIS_DATA_W-1:0] core_m1_tdata;
  logic core_m1_tvalid;
  logic core_m1_tready;
  logic core_m1_tlast;
  logic [TUSER_W-1:0] core_m1_tuser;
  logic [7:0] cfg0_codec_mode;
  logic [7:0] cfg0_rice_mode;
  logic [3:0] cfg0_fixed_k;
  logic [15:0] cfg0_frame_id;
  logic [15:0] cfg0_block_id;
  logic [15:0] cfg0_tensor_spatial_size;
  logic [15:0] cfg0_tensor_doppler_size;
  logic [15:0] cfg0_tensor_range_size;
  logic [7:0] cfg1_codec_mode;
  logic [7:0] cfg1_rice_mode;
  logic [3:0] cfg1_fixed_k;
  logic [15:0] cfg1_frame_id;
  logic [15:0] cfg1_block_id;
  logic [15:0] cfg1_tensor_spatial_size;
  logic [15:0] cfg1_tensor_doppler_size;
  logic [15:0] cfg1_tensor_range_size;
  logic lane0_done_unused;
  logic lane1_done_unused;
  logic [31:0] lane0_raw_bytes_unused;
  logic [31:0] lane1_raw_bytes_unused;
  logic [31:0] lane0_comp_bytes_unused;
  logic [31:0] lane1_comp_bytes_unused;
  logic lane0_soft_reset;
  logic lane1_soft_reset;

  mrtc_rdtc_wb_lane_adapter #(
    .AXIS_DATA_W(AXIS_DATA_W), .TUSER_W(TUSER_W), .COMP_BLOCK_BYTES(COMP_BLOCK_BYTES)
  ) u_adapter0 (
    .clk, .rst_n,
    .job_valid(job0_valid), .job_ready(job0_ready), .job_id(job0_id),
    .job_codec_mode(job0_codec_mode), .job_rice_mode(job0_rice_mode),
    .job_fixed_k(job0_fixed_k), .job_frame_id(job0_frame_id),
    .job_block_id(job0_block_id), .job_tensor_spatial_size(job0_tensor_spatial_size),
    .job_tensor_doppler_size(job0_tensor_doppler_size),
    .job_tensor_range_size(job0_tensor_range_size), .job_last_block(job0_last_block),
    .s_axis_tdata(s0_axis_tdata), .s_axis_tvalid(s0_axis_tvalid),
    .s_axis_tready(s0_axis_tready), .s_axis_tlast(s0_axis_tlast),
    .s_axis_tuser(s0_axis_tuser),
    .core_s_axis_tdata(core_s0_tdata), .core_s_axis_tvalid(core_s0_tvalid),
    .core_s_axis_tready(core_s0_tready), .core_s_axis_tlast(core_s0_tlast),
    .core_s_axis_tuser(core_s0_tuser),
    .core_m_axis_tdata(core_m0_tdata), .core_m_axis_tvalid(core_m0_tvalid),
    .core_m_axis_tready(core_m0_tready), .core_m_axis_tlast(core_m0_tlast),
    .core_m_axis_tuser(core_m0_tuser),
    .m_axis_tdata(m0_axis_tdata), .m_axis_tvalid(m0_axis_tvalid),
    .m_axis_tready(m0_axis_tready), .m_axis_tlast(m0_axis_tlast),
    .m_axis_tuser(m0_axis_tuser),
    .cfg_codec_mode(cfg0_codec_mode), .cfg_rice_mode(cfg0_rice_mode),
    .cfg_fixed_k(cfg0_fixed_k), .cfg_frame_id(cfg0_frame_id),
    .cfg_block_id(cfg0_block_id), .cfg_tensor_spatial_size(cfg0_tensor_spatial_size),
    .cfg_tensor_doppler_size(cfg0_tensor_doppler_size),
    .cfg_tensor_range_size(cfg0_tensor_range_size),
    .core_busy(lane0_busy), .core_error(lane0_error), .core_soft_reset(lane0_soft_reset),
    .completion_valid(completion0_valid), .completion_ready(completion0_ready),
    .completion_job_id(completion0_job_id), .completion_raw_bytes(completion0_raw_bytes),
    .completion_comp_bytes(completion0_comp_bytes), .completion_error(completion0_error),
    .job_active(lane0_job_active)
  );

  mrtc_rdtc_wb_lane_adapter #(
    .AXIS_DATA_W(AXIS_DATA_W), .TUSER_W(TUSER_W), .COMP_BLOCK_BYTES(COMP_BLOCK_BYTES)
  ) u_adapter1 (
    .clk, .rst_n,
    .job_valid(job1_valid), .job_ready(job1_ready), .job_id(job1_id),
    .job_codec_mode(job1_codec_mode), .job_rice_mode(job1_rice_mode),
    .job_fixed_k(job1_fixed_k), .job_frame_id(job1_frame_id),
    .job_block_id(job1_block_id), .job_tensor_spatial_size(job1_tensor_spatial_size),
    .job_tensor_doppler_size(job1_tensor_doppler_size),
    .job_tensor_range_size(job1_tensor_range_size), .job_last_block(job1_last_block),
    .s_axis_tdata(s1_axis_tdata), .s_axis_tvalid(s1_axis_tvalid),
    .s_axis_tready(s1_axis_tready), .s_axis_tlast(s1_axis_tlast),
    .s_axis_tuser(s1_axis_tuser),
    .core_s_axis_tdata(core_s1_tdata), .core_s_axis_tvalid(core_s1_tvalid),
    .core_s_axis_tready(core_s1_tready), .core_s_axis_tlast(core_s1_tlast),
    .core_s_axis_tuser(core_s1_tuser),
    .core_m_axis_tdata(core_m1_tdata), .core_m_axis_tvalid(core_m1_tvalid),
    .core_m_axis_tready(core_m1_tready), .core_m_axis_tlast(core_m1_tlast),
    .core_m_axis_tuser(core_m1_tuser),
    .m_axis_tdata(m1_axis_tdata), .m_axis_tvalid(m1_axis_tvalid),
    .m_axis_tready(m1_axis_tready), .m_axis_tlast(m1_axis_tlast),
    .m_axis_tuser(m1_axis_tuser),
    .cfg_codec_mode(cfg1_codec_mode), .cfg_rice_mode(cfg1_rice_mode),
    .cfg_fixed_k(cfg1_fixed_k), .cfg_frame_id(cfg1_frame_id),
    .cfg_block_id(cfg1_block_id), .cfg_tensor_spatial_size(cfg1_tensor_spatial_size),
    .cfg_tensor_doppler_size(cfg1_tensor_doppler_size),
    .cfg_tensor_range_size(cfg1_tensor_range_size),
    .core_busy(lane1_busy), .core_error(lane1_error), .core_soft_reset(lane1_soft_reset),
    .completion_valid(completion1_valid), .completion_ready(completion1_ready),
    .completion_job_id(completion1_job_id), .completion_raw_bytes(completion1_raw_bytes),
    .completion_comp_bytes(completion1_comp_bytes), .completion_error(completion1_error),
    .job_active(lane1_job_active)
  );

  mrtc_rdtc_dual_core #(
    .PHASES_PER_BEAT(PHASES_PER_BEAT),
    .AXIS_DATA_W(AXIS_DATA_W),
    .COMP_BLOCK_BYTES(COMP_BLOCK_BYTES)
  ) u_dual_core (
    .clk, .rst_n, .lane0_soft_reset, .lane1_soft_reset, .i_clear_status,
    .s0_axis_tdata(core_s0_tdata), .s0_axis_tvalid(core_s0_tvalid),
    .s0_axis_tready(core_s0_tready), .s0_axis_tlast(core_s0_tlast),
    .s0_axis_tuser(core_s0_tuser),
    .m0_axis_tdata(core_m0_tdata), .m0_axis_tvalid(core_m0_tvalid),
    .m0_axis_tready(core_m0_tready), .m0_axis_tlast(core_m0_tlast),
    .m0_axis_tuser(core_m0_tuser),
    .s1_axis_tdata(core_s1_tdata), .s1_axis_tvalid(core_s1_tvalid),
    .s1_axis_tready(core_s1_tready), .s1_axis_tlast(core_s1_tlast),
    .s1_axis_tuser(core_s1_tuser),
    .m1_axis_tdata(core_m1_tdata), .m1_axis_tvalid(core_m1_tvalid),
    .m1_axis_tready(core_m1_tready), .m1_axis_tlast(core_m1_tlast),
    .m1_axis_tuser(core_m1_tuser),
    .cfg0_codec_mode, .cfg0_rice_mode, .cfg0_fixed_k, .cfg0_frame_id,
    .cfg0_block_id, .cfg0_tensor_spatial_size, .cfg0_tensor_doppler_size,
    .cfg0_tensor_range_size,
    .cfg1_codec_mode, .cfg1_rice_mode, .cfg1_fixed_k, .cfg1_frame_id,
    .cfg1_block_id, .cfg1_tensor_spatial_size, .cfg1_tensor_doppler_size,
    .cfg1_tensor_range_size,
    .lane0_busy, .lane0_done(lane0_done_unused),
    .lane0_raw_bytes(lane0_raw_bytes_unused), .lane0_comp_bytes(lane0_comp_bytes_unused),
    .lane0_num_blocks, .lane0_error, .lane0_input_stall_cycles,
    .lane0_output_stall_cycles,
    .lane1_busy, .lane1_done(lane1_done_unused),
    .lane1_raw_bytes(lane1_raw_bytes_unused), .lane1_comp_bytes(lane1_comp_bytes_unused),
    .lane1_num_blocks, .lane1_error, .lane1_input_stall_cycles,
    .lane1_output_stall_cycles
  );
endmodule
