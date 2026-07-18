module mrtc_rdtc_wb_lane_adapter #(
  parameter int AXIS_DATA_W = 128,
  parameter int TUSER_W = 8,
  parameter int COMP_BLOCK_BYTES = 4096
) (
  input logic clk,
  input logic rst_n,

  input logic job_valid,
  output logic job_ready,
  input logic [31:0] job_id,
  input logic [7:0] job_codec_mode,
  input logic [7:0] job_rice_mode,
  input logic [3:0] job_fixed_k,
  input logic [15:0] job_frame_id,
  input logic [15:0] job_block_id,
  input logic [15:0] job_tensor_spatial_size,
  input logic [15:0] job_tensor_doppler_size,
  input logic [15:0] job_tensor_range_size,
  input logic job_last_block,

  input logic [AXIS_DATA_W-1:0] s_axis_tdata,
  input logic s_axis_tvalid,
  output logic s_axis_tready,
  input logic s_axis_tlast,
  input logic [TUSER_W-1:0] s_axis_tuser,

  output logic [AXIS_DATA_W-1:0] core_s_axis_tdata,
  output logic core_s_axis_tvalid,
  input logic core_s_axis_tready,
  output logic core_s_axis_tlast,
  output logic [TUSER_W-1:0] core_s_axis_tuser,

  input logic [AXIS_DATA_W-1:0] core_m_axis_tdata,
  input logic core_m_axis_tvalid,
  output logic core_m_axis_tready,
  input logic core_m_axis_tlast,
  input logic [TUSER_W-1:0] core_m_axis_tuser,

  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic m_axis_tvalid,
  input logic m_axis_tready,
  output logic m_axis_tlast,
  output logic [TUSER_W-1:0] m_axis_tuser,

  output logic [7:0] cfg_codec_mode,
  output logic [7:0] cfg_rice_mode,
  output logic [3:0] cfg_fixed_k,
  output logic [15:0] cfg_frame_id,
  output logic [15:0] cfg_block_id,
  output logic [15:0] cfg_tensor_spatial_size,
  output logic [15:0] cfg_tensor_doppler_size,
  output logic [15:0] cfg_tensor_range_size,

  input logic core_busy,
  input logic [31:0] core_error,
  output logic core_soft_reset,
  output logic completion_valid,
  input logic completion_ready,
  output logic [31:0] completion_job_id,
  output logic [31:0] completion_raw_bytes,
  output logic [31:0] completion_comp_bytes,
  output logic [31:0] completion_error,
  output logic job_active
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;

  logic [31:0] active_job_id;
  logic active_last_block;
  logic input_started;
  logic flush_reg;
  logic [31:0] comp_bytes_reg;
  logic [31:0] raw_bytes_reg;
  logic input_skid_ready;
  logic [TUSER_W-1:0] job_tuser;
  logic output_accept;
  logic output_last_accept;
  logic [31:0] output_valid_bytes;
  logic error_completion;

  assign job_ready = !job_active && !completion_valid && !core_busy && (core_error == 32'd0);
  assign s_axis_tready = job_active && input_skid_ready;
  assign job_tuser = {s_axis_tuser[TUSER_W-1:4], active_last_block,
                      cfg_codec_mode[1:0], s_axis_tuser[0]};
  assign output_accept = m_axis_tvalid && m_axis_tready;
  assign output_last_accept = output_accept && m_axis_tlast;
  assign output_valid_bytes = {28'd0, m_axis_tuser[3:0]} + 32'd1;
  assign error_completion = job_active && input_started && !core_busy &&
                            (core_error != 32'd0) && !output_last_accept;

  mrtc_axis_skid_buffer_flushable #(
    .DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W)
  ) u_input_skid (
    .clk,
    .rst_n,
    .i_flush(flush_reg),
    .s_tdata(s_axis_tdata),
    .s_tuser(job_tuser),
    .s_tvalid(s_axis_tvalid && job_active),
    .s_tlast(s_axis_tlast),
    .s_tready(input_skid_ready),
    .m_tdata(core_s_axis_tdata),
    .m_tuser(core_s_axis_tuser),
    .m_tvalid(core_s_axis_tvalid),
    .m_tlast(core_s_axis_tlast),
    .m_tready(core_s_axis_tready)
  );

  mrtc_axis_skid_buffer_flushable #(
    .DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W)
  ) u_output_skid (
    .clk,
    .rst_n,
    .i_flush(flush_reg),
    .s_tdata(core_m_axis_tdata),
    .s_tuser(core_m_axis_tuser),
    .s_tvalid(core_m_axis_tvalid),
    .s_tlast(core_m_axis_tlast),
    .s_tready(core_m_axis_tready),
    .m_tdata(m_axis_tdata),
    .m_tuser(m_axis_tuser),
    .m_tvalid(m_axis_tvalid),
    .m_tlast(m_axis_tlast),
    .m_tready(m_axis_tready)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      job_active <= 1'b0;
      active_job_id <= 32'd0;
      active_last_block <= 1'b0;
      input_started <= 1'b0;
      flush_reg <= 1'b0;
      comp_bytes_reg <= 32'd0;
      raw_bytes_reg <= 32'd0;
      cfg_codec_mode <= 8'd0;
      cfg_rice_mode <= 8'd0;
      cfg_fixed_k <= 4'd0;
      cfg_frame_id <= 16'd0;
      cfg_block_id <= 16'd0;
      cfg_tensor_spatial_size <= 16'd0;
      cfg_tensor_doppler_size <= 16'd0;
      cfg_tensor_range_size <= 16'd0;
      completion_valid <= 1'b0;
      completion_job_id <= 32'd0;
      completion_raw_bytes <= 32'd0;
      completion_comp_bytes <= 32'd0;
      completion_error <= 32'd0;
      core_soft_reset <= 1'b0;
    end else begin
      flush_reg <= 1'b0;
      core_soft_reset <= 1'b0;

      if (completion_valid && completion_ready) begin
        completion_valid <= 1'b0;
      end

      if (job_valid && job_ready) begin
        job_active <= 1'b1;
        active_job_id <= job_id;
        active_last_block <= job_last_block;
        input_started <= 1'b0;
        comp_bytes_reg <= 32'd0;
        raw_bytes_reg <= 32'd0;
        cfg_codec_mode <= job_codec_mode;
        cfg_rice_mode <= job_rice_mode;
        cfg_fixed_k <= job_fixed_k;
        cfg_frame_id <= job_frame_id;
        cfg_block_id <= job_block_id;
        cfg_tensor_spatial_size <= job_tensor_spatial_size;
        cfg_tensor_doppler_size <= job_tensor_doppler_size;
        cfg_tensor_range_size <= job_tensor_range_size;
        flush_reg <= 1'b1;
      end

      if (core_s_axis_tvalid && core_s_axis_tready) begin
        input_started <= 1'b1;
      end

      if (s_axis_tvalid && s_axis_tready) begin
        raw_bytes_reg <= raw_bytes_reg + 32'(AXIS_BYTES);
      end

      if (output_accept) begin
        comp_bytes_reg <= comp_bytes_reg + output_valid_bytes;
      end

      if (output_last_accept) begin
        job_active <= 1'b0;
        input_started <= 1'b0;
        completion_valid <= 1'b1;
        completion_job_id <= active_job_id;
        completion_raw_bytes <= raw_bytes_reg;
        completion_comp_bytes <= comp_bytes_reg + output_valid_bytes;
        completion_error <= core_error;
      end else if (error_completion) begin
        job_active <= 1'b0;
        input_started <= 1'b0;
        flush_reg <= 1'b1;
        completion_valid <= 1'b1;
        completion_job_id <= active_job_id;
        completion_raw_bytes <= raw_bytes_reg;
        completion_comp_bytes <= comp_bytes_reg;
        completion_error <= core_error;
        core_soft_reset <= 1'b1;
      end
    end
  end
endmodule
