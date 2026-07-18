module mrtc_top #(
  parameter int AXIS_DATA_W = 128,
  parameter int AXIL_ADDR_W = 12,
  parameter int AXIL_DATA_W = 32,
  parameter int MRTC_K_POLICY_ARCH = mrtc_pkg::MRTC_K_POLICY_FULL_ADAPTIVE,
  parameter bit PREFIX_STREAM_LENGTH_BY_TLAST = 1'b1,
  parameter int PREFIX_SAMPLES = 256
) (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic [AXIL_ADDR_W-1:0]    s_axil_awaddr,
  input  logic                      s_axil_awvalid,
  output logic                      s_axil_awready,
  input  logic [AXIL_DATA_W-1:0]    s_axil_wdata,
  input  logic [(AXIL_DATA_W/8)-1:0] s_axil_wstrb,
  input  logic                      s_axil_wvalid,
  output logic                      s_axil_wready,
  output logic [1:0]                s_axil_bresp,
  output logic                      s_axil_bvalid,
  input  logic                      s_axil_bready,
  input  logic [AXIL_ADDR_W-1:0]    s_axil_araddr,
  input  logic                      s_axil_arvalid,
  output logic                      s_axil_arready,
  output logic [AXIL_DATA_W-1:0]    s_axil_rdata,
  output logic [1:0]                s_axil_rresp,
  output logic                      s_axil_rvalid,
  input  logic                      s_axil_rready,

  input  logic [AXIS_DATA_W-1:0]    s_axis_raw_tdata,
  input  logic                      s_axis_raw_tvalid,
  output logic                      s_axis_raw_tready,
  input  logic                      s_axis_raw_tlast,
  input  logic [7:0]                s_axis_raw_tuser,
  output logic [AXIS_DATA_W-1:0]    m_axis_comp_tdata,
  output logic                      m_axis_comp_tvalid,
  input  logic                      m_axis_comp_tready,
  output logic                      m_axis_comp_tlast,
  output logic [7:0]                m_axis_comp_tuser,
  input  logic [AXIS_DATA_W-1:0]    s_axis_comp_tdata,
  input  logic                      s_axis_comp_tvalid,
  output logic                      s_axis_comp_tready,
  input  logic                      s_axis_comp_tlast,
  input  logic [7:0]                s_axis_comp_tuser,
  output logic [AXIS_DATA_W-1:0]    m_axis_raw_tdata,
  output logic                      m_axis_raw_tvalid,
  input  logic                      m_axis_raw_tready,
  output logic                      m_axis_raw_tlast,
  output logic [7:0]                m_axis_raw_tuser,
  output logic                      irq_done,
  output logic                      irq_error,
  output logic                      irq
);
  logic        reg_enable;
  logic        reg_encoder_enable;
  logic        reg_decoder_enable;
  logic        reg_soft_reset_pulse;
  logic        reg_clear_status_pulse;
  logic [7:0]  reg_cfg_codec_mode;
  logic [7:0]  reg_cfg_rice_mode;
  logic [3:0]  reg_cfg_fixed_k;
  logic [15:0] reg_cfg_frame_id;
  logic [15:0] reg_cfg_tensor_spatial_size;
  logic [15:0] reg_cfg_tensor_doppler_size;
  logic [15:0] reg_cfg_tensor_range_size;

  logic        stat_enc_busy;
  logic        stat_enc_done;
  logic [31:0] stat_enc_raw_bytes;
  logic [31:0] stat_enc_comp_bytes;
  logic [31:0] stat_enc_num_blocks;
  logic [31:0] stat_enc_error;
  logic [31:0] stat_enc_raw_bypass_blocks;
  logic [31:0] stat_enc_stall_input_cycles;
  logic [31:0] stat_enc_stall_output_cycles;
  logic        stat_dec_busy;
  logic        stat_dec_done;
  logic [31:0] stat_dec_comp_bytes;
  logic [31:0] stat_dec_raw_bytes;
  logic [31:0] stat_dec_num_blocks;
  logic [31:0] stat_dec_error;
  logic [31:0] stat_dec_error_blocks;
  logic [31:0] stat_dec_stall_input_cycles;
  logic [31:0] stat_dec_stall_output_cycles;

  logic        codec_rst_n;
  logic [AXIS_DATA_W-1:0] codec_s_axis_raw_tdata;
  logic                   codec_s_axis_raw_tvalid;
  logic                   codec_s_axis_raw_tready;
  logic                   codec_s_axis_raw_tlast;
  logic [7:0]             codec_s_axis_raw_tuser;
  logic [AXIS_DATA_W-1:0] codec_s_axis_comp_tdata;
  logic                   codec_s_axis_comp_tvalid;
  logic                   codec_s_axis_comp_tready;
  logic                   codec_s_axis_comp_tlast;
  logic [7:0]             codec_s_axis_comp_tuser;

  assign codec_rst_n = rst_n & ~reg_soft_reset_pulse;

  assign codec_s_axis_raw_tdata = s_axis_raw_tdata;
  assign codec_s_axis_raw_tlast = s_axis_raw_tlast;
  assign codec_s_axis_raw_tuser = s_axis_raw_tuser;
  assign codec_s_axis_raw_tvalid = reg_enable && reg_encoder_enable && s_axis_raw_tvalid;
  assign s_axis_raw_tready = (reg_enable && reg_encoder_enable) ? codec_s_axis_raw_tready : 1'b0;

  assign codec_s_axis_comp_tdata = s_axis_comp_tdata;
  assign codec_s_axis_comp_tlast = s_axis_comp_tlast;
  assign codec_s_axis_comp_tuser = s_axis_comp_tuser;
  assign codec_s_axis_comp_tvalid = reg_enable && reg_decoder_enable && s_axis_comp_tvalid;
  assign s_axis_comp_tready = (reg_enable && reg_decoder_enable) ? codec_s_axis_comp_tready : 1'b0;

  mrtc_axi_lite_reg_block #(
    .ADDR_W(AXIL_ADDR_W),
    .DATA_W(AXIL_DATA_W)
  ) u_reg_block (
    .clk(clk),
    .rst_n(rst_n),
    .s_axil_awaddr(s_axil_awaddr),
    .s_axil_awvalid(s_axil_awvalid),
    .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata),
    .s_axil_wstrb(s_axil_wstrb),
    .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp),
    .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr),
    .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata),
    .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid),
    .s_axil_rready(s_axil_rready),
    .i_stat_enc_busy(stat_enc_busy),
    .i_stat_enc_done(stat_enc_done),
    .i_stat_enc_raw_bytes(stat_enc_raw_bytes),
    .i_stat_enc_comp_bytes(stat_enc_comp_bytes),
    .i_stat_enc_num_blocks(stat_enc_num_blocks),
    .i_stat_enc_error(stat_enc_error),
    .i_stat_enc_raw_bypass_blocks(stat_enc_raw_bypass_blocks),
    .i_stat_enc_stall_input_cycles(stat_enc_stall_input_cycles),
    .i_stat_enc_stall_output_cycles(stat_enc_stall_output_cycles),
    .i_stat_dec_busy(stat_dec_busy),
    .i_stat_dec_done(stat_dec_done),
    .i_stat_dec_raw_bytes(stat_dec_raw_bytes),
    .i_stat_dec_comp_bytes(stat_dec_comp_bytes),
    .i_stat_dec_num_blocks(stat_dec_num_blocks),
    .i_stat_dec_error(stat_dec_error),
    .i_stat_dec_error_blocks(stat_dec_error_blocks),
    .i_stat_dec_stall_input_cycles(stat_dec_stall_input_cycles),
    .i_stat_dec_stall_output_cycles(stat_dec_stall_output_cycles),
    .o_enable(reg_enable),
    .o_encoder_enable(reg_encoder_enable),
    .o_decoder_enable(reg_decoder_enable),
    .o_soft_reset_pulse(reg_soft_reset_pulse),
    .o_clear_status_pulse(reg_clear_status_pulse),
    .o_cfg_codec_mode(reg_cfg_codec_mode),
    .o_cfg_rice_mode(reg_cfg_rice_mode),
    .o_cfg_fixed_k(reg_cfg_fixed_k),
    .o_cfg_frame_id(reg_cfg_frame_id),
    .o_cfg_tensor_spatial_size(reg_cfg_tensor_spatial_size),
    .o_cfg_tensor_doppler_size(reg_cfg_tensor_doppler_size),
    .o_cfg_tensor_range_size(reg_cfg_tensor_range_size),
    .o_irq_done(irq_done),
    .o_irq_error(irq_error),
    .o_irq(irq)
  );

  mrtc_rdtc_codec_top #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .MRTC_K_POLICY_ARCH(MRTC_K_POLICY_ARCH),
    .PREFIX_STREAM_LENGTH_BY_TLAST(PREFIX_STREAM_LENGTH_BY_TLAST),
    .PREFIX_SAMPLES(PREFIX_SAMPLES)
  ) u_codec_top (
    .clk(clk),
    .rst_n(codec_rst_n),
    .i_clear_status(reg_clear_status_pulse),
    .s_axis_raw_tdata(codec_s_axis_raw_tdata),
    .s_axis_raw_tvalid(codec_s_axis_raw_tvalid),
    .s_axis_raw_tready(codec_s_axis_raw_tready),
    .s_axis_raw_tlast(codec_s_axis_raw_tlast),
    .s_axis_raw_tuser(codec_s_axis_raw_tuser),
    .m_axis_comp_tdata(m_axis_comp_tdata),
    .m_axis_comp_tvalid(m_axis_comp_tvalid),
    .m_axis_comp_tready(m_axis_comp_tready),
    .m_axis_comp_tlast(m_axis_comp_tlast),
    .m_axis_comp_tuser(m_axis_comp_tuser),
    .s_axis_comp_tdata(codec_s_axis_comp_tdata),
    .s_axis_comp_tvalid(codec_s_axis_comp_tvalid),
    .s_axis_comp_tready(codec_s_axis_comp_tready),
    .s_axis_comp_tlast(codec_s_axis_comp_tlast),
    .s_axis_comp_tuser(codec_s_axis_comp_tuser),
    .m_axis_raw_tdata(m_axis_raw_tdata),
    .m_axis_raw_tvalid(m_axis_raw_tvalid),
    .m_axis_raw_tready(m_axis_raw_tready),
    .m_axis_raw_tlast(m_axis_raw_tlast),
    .m_axis_raw_tuser(m_axis_raw_tuser),
    .cfg_codec_mode(reg_cfg_codec_mode),
    .cfg_rice_mode(reg_cfg_rice_mode),
    .cfg_fixed_k(reg_cfg_fixed_k),
    .cfg_frame_id(reg_cfg_frame_id),
    .cfg_block_id_base(16'd1),
    .cfg_tensor_spatial_size(reg_cfg_tensor_spatial_size),
    .cfg_tensor_doppler_size(reg_cfg_tensor_doppler_size),
    .cfg_tensor_range_size(reg_cfg_tensor_range_size),
    .stat_enc_busy(stat_enc_busy),
    .stat_enc_done(stat_enc_done),
    .stat_enc_raw_bytes(stat_enc_raw_bytes),
    .stat_enc_comp_bytes(stat_enc_comp_bytes),
    .stat_enc_num_blocks(stat_enc_num_blocks),
    .stat_enc_error(stat_enc_error),
    .stat_enc_raw_bypass_blocks(stat_enc_raw_bypass_blocks),
    .stat_enc_stall_input_cycles(stat_enc_stall_input_cycles),
    .stat_enc_stall_output_cycles(stat_enc_stall_output_cycles),
    .stat_dec_busy(stat_dec_busy),
    .stat_dec_done(stat_dec_done),
    .stat_dec_comp_bytes(stat_dec_comp_bytes),
    .stat_dec_raw_bytes(stat_dec_raw_bytes),
    .stat_dec_num_blocks(stat_dec_num_blocks),
    .stat_dec_error(stat_dec_error),
    .stat_dec_error_blocks(stat_dec_error_blocks),
    .stat_dec_stall_input_cycles(stat_dec_stall_input_cycles),
    .stat_dec_stall_output_cycles(stat_dec_stall_output_cycles)
  );
endmodule
