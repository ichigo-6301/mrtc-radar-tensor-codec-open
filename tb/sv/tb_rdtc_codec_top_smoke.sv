`timescale 1ns/1ps

module tb_rdtc_codec_top_smoke #(
  parameter string CASE_DIR = "vectors/rdtc_v1/smoke_zero_sparse"
);
  logic clk;
  logic rst_n;
  logic [127:0] s_axis_raw_tdata;
  logic         s_axis_raw_tvalid;
  logic         s_axis_raw_tready;
  logic         s_axis_raw_tlast;
  logic [7:0]   s_axis_raw_tuser;
  logic [127:0] m_axis_comp_tdata;
  logic         m_axis_comp_tvalid;
  logic         m_axis_comp_tready;
  logic         m_axis_comp_tlast;
  logic [7:0]   m_axis_comp_tuser;
  logic [127:0] s_axis_comp_tdata;
  logic         s_axis_comp_tvalid;
  logic         s_axis_comp_tready;
  logic         s_axis_comp_tlast;
  logic [7:0]   s_axis_comp_tuser;
  logic [127:0] m_axis_raw_tdata;
  logic         m_axis_raw_tvalid;
  logic         m_axis_raw_tready;
  logic         m_axis_raw_tlast;
  logic [7:0]   m_axis_raw_tuser;
  logic         stat_enc_busy;
  logic         stat_enc_done;
  logic [31:0]  stat_enc_raw_bytes;
  logic [31:0]  stat_enc_comp_bytes;
  logic [31:0]  stat_enc_num_blocks;
  logic [31:0]  stat_enc_error;
  logic         stat_dec_busy;
  logic         stat_dec_done;
  logic [31:0]  stat_dec_comp_bytes;
  logic [31:0]  stat_dec_raw_bytes;
  logic [31:0]  stat_dec_num_blocks;
  logic [31:0]  stat_dec_error;
  logic         driver_raw_done;
  logic         driver_comp_done;
  integer       comp_monitor_byte_count;
  integer       comp_monitor_beat_count;
  byte          comp_monitor_bytes [0:32767];
  integer       raw_monitor_byte_count;
  integer       raw_monitor_beat_count;
  byte          raw_monitor_bytes [0:32767];
  logic         comp_compare_start;
  logic         raw_compare_start;
  logic         comp_compare_pass;
  logic         raw_compare_pass;
  integer       comp_protocol_error_count;
  integer       raw_protocol_error_count;
  logic [7:0]   cfg_codec_mode_runtime;
  logic [7:0]   cfg_rice_mode_runtime;
  logic [3:0]   cfg_fixed_k_runtime;
  logic [15:0]  cfg_frame_id_runtime;
  integer       block_id_base_runtime;
  integer       tensor_spatial_size_runtime;
  integer       tensor_doppler_size_runtime;
  integer       tensor_range_size_runtime;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rst_n = 1'b0;
    comp_compare_start = 1'b0;
    raw_compare_start = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
  end

  task automatic load_case_cfg(input string cfg_case_dir);
    int fd;
    string line;
    string hdr_path;
    int code;
    int magic;
    int version;
    int header_len;
    int frame_id;
    int block_id;
    int tensor_spatial;
    int tensor_doppler;
    int tensor_range;
    int block_spatial_start;
    int block_doppler_start;
    int block_range_start;
    int block_spatial_len;
    int block_doppler_len;
    int block_range_len;
    int sample_format;
    int codec_mode;
    int predictor_mode;
    int rice_k;
    int flags;
    int reserved0;
    int raw_bytes;
    int payload_bytes;
    int payload_bits;
    int crc32;
    begin
      hdr_path = {cfg_case_dir, "/block_000_header.csv"};
      fd = $fopen(hdr_path, "r");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", hdr_path);
      end
      void'($fgets(line, fd));
      line = "";
      void'($fgets(line, fd));
      code = $sscanf(
        line,
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
        magic, version, header_len, frame_id, block_id,
        tensor_spatial, tensor_doppler, tensor_range,
        block_spatial_start, block_doppler_start, block_range_start,
        block_spatial_len, block_doppler_len, block_range_len,
        sample_format, codec_mode, predictor_mode, rice_k, flags, reserved0,
        raw_bytes, payload_bytes, payload_bits, crc32
      );
      $fclose(fd);
      if (code != 24) begin
        $fatal(1, "failed to parse %s", hdr_path);
      end
      cfg_codec_mode_runtime = predictor_mode[7:0];
      cfg_rice_mode_runtime = ((flags & 8) != 0) ? 8'd1 : 8'd0;
      cfg_fixed_k_runtime = rice_k[3:0];
      cfg_frame_id_runtime = frame_id[15:0];
      block_id_base_runtime = block_id;
      tensor_spatial_size_runtime = tensor_spatial;
      tensor_doppler_size_runtime = tensor_doppler;
      tensor_range_size_runtime = tensor_range;
    end
  endtask

  initial begin
    cfg_codec_mode_runtime = 8'd1;
    cfg_rice_mode_runtime = 8'd0;
    cfg_fixed_k_runtime = 4'd0;
    cfg_frame_id_runtime = 16'd1;
    block_id_base_runtime = 0;
    tensor_spatial_size_runtime = 1;
    tensor_doppler_size_runtime = 64;
    tensor_range_size_runtime = 16;
    load_case_cfg(CASE_DIR);
  end

  mrtc_axis_driver #(
    .CASE_DIR(CASE_DIR)
  ) u_raw_driver (
    .clk(clk),
    .rst_n(rst_n),
    .m_tdata(s_axis_raw_tdata),
    .m_tvalid(s_axis_raw_tvalid),
    .m_tready(s_axis_raw_tready),
    .m_tlast(s_axis_raw_tlast),
    .m_tuser(s_axis_raw_tuser),
    .o_done(driver_raw_done)
  );

  mrtc_axis_driver #(
    .CASE_DIR(CASE_DIR),
    .HEX_FILE("axis_comp_expected.hex"),
    .CTRL_FILE("axis_comp_expected_ctrl.csv"),
    .LOAD_BLOCK_CODECS(1'b0),
    .EMIT_LAST_BYTE_COUNT(1'b1)
  ) u_comp_driver (
    .clk(clk),
    .rst_n(rst_n),
    .m_tdata(s_axis_comp_tdata),
    .m_tvalid(s_axis_comp_tvalid),
    .m_tready(s_axis_comp_tready),
    .m_tlast(s_axis_comp_tlast),
    .m_tuser(s_axis_comp_tuser),
    .o_done(driver_comp_done)
  );

  mrtc_rdtc_codec_top #(
    .AXIS_DATA_W(128)
  ) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(1'b0),
    .s_axis_raw_tdata(s_axis_raw_tdata),
    .s_axis_raw_tvalid(s_axis_raw_tvalid),
    .s_axis_raw_tready(s_axis_raw_tready),
    .s_axis_raw_tlast(s_axis_raw_tlast),
    .s_axis_raw_tuser(s_axis_raw_tuser),
    .m_axis_comp_tdata(m_axis_comp_tdata),
    .m_axis_comp_tvalid(m_axis_comp_tvalid),
    .m_axis_comp_tready(m_axis_comp_tready),
    .m_axis_comp_tlast(m_axis_comp_tlast),
    .m_axis_comp_tuser(m_axis_comp_tuser),
    .s_axis_comp_tdata(s_axis_comp_tdata),
    .s_axis_comp_tvalid(s_axis_comp_tvalid),
    .s_axis_comp_tready(s_axis_comp_tready),
    .s_axis_comp_tlast(s_axis_comp_tlast),
    .s_axis_comp_tuser(s_axis_comp_tuser),
    .m_axis_raw_tdata(m_axis_raw_tdata),
    .m_axis_raw_tvalid(m_axis_raw_tvalid),
    .m_axis_raw_tready(m_axis_raw_tready),
    .m_axis_raw_tlast(m_axis_raw_tlast),
    .m_axis_raw_tuser(m_axis_raw_tuser),
    .cfg_codec_mode(cfg_codec_mode_runtime),
    .cfg_rice_mode(cfg_rice_mode_runtime),
    .cfg_fixed_k(cfg_fixed_k_runtime),
    .cfg_frame_id(cfg_frame_id_runtime),
    .cfg_block_id_base(block_id_base_runtime[15:0]),
    .cfg_tensor_spatial_size(tensor_spatial_size_runtime[15:0]),
    .cfg_tensor_doppler_size(tensor_doppler_size_runtime[15:0]),
    .cfg_tensor_range_size(tensor_range_size_runtime[15:0]),
    .stat_enc_busy(stat_enc_busy),
    .stat_enc_done(stat_enc_done),
    .stat_enc_raw_bytes(stat_enc_raw_bytes),
    .stat_enc_comp_bytes(stat_enc_comp_bytes),
    .stat_enc_num_blocks(stat_enc_num_blocks),
    .stat_enc_error(stat_enc_error),
    .stat_enc_raw_bypass_blocks(),
    .stat_enc_stall_input_cycles(),
    .stat_enc_stall_output_cycles(),
    .stat_dec_busy(stat_dec_busy),
    .stat_dec_done(stat_dec_done),
    .stat_dec_comp_bytes(stat_dec_comp_bytes),
    .stat_dec_raw_bytes(stat_dec_raw_bytes),
    .stat_dec_num_blocks(stat_dec_num_blocks),
    .stat_dec_error(stat_dec_error),
    .stat_dec_error_blocks(),
    .stat_dec_stall_input_cycles(),
    .stat_dec_stall_output_cycles()
  );

  mrtc_axis_monitor u_comp_monitor (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(m_axis_comp_tdata),
    .s_tvalid(m_axis_comp_tvalid),
    .s_tready(m_axis_comp_tready),
    .s_tlast(m_axis_comp_tlast),
    .s_tuser(m_axis_comp_tuser),
    .o_done(),
    .o_byte_count(comp_monitor_byte_count),
    .o_beat_count(comp_monitor_beat_count),
    .o_bytes(comp_monitor_bytes)
  );

  mrtc_axis_monitor #(
    .USE_TUSER_BYTE_COUNT_ON_TLAST(1'b0)
  ) u_raw_monitor (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(m_axis_raw_tdata),
    .s_tvalid(m_axis_raw_tvalid),
    .s_tready(m_axis_raw_tready),
    .s_tlast(m_axis_raw_tlast),
    .s_tuser(m_axis_raw_tuser),
    .o_done(),
    .o_byte_count(raw_monitor_byte_count),
    .o_beat_count(raw_monitor_beat_count),
    .o_bytes(raw_monitor_bytes)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("codec_top_m_axis_comp")
  ) u_comp_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(m_axis_comp_tdata),
    .tvalid(m_axis_comp_tvalid),
    .tready(m_axis_comp_tready),
    .tlast(m_axis_comp_tlast),
    .tuser(m_axis_comp_tuser),
    .protocol_error_count(comp_protocol_error_count)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("codec_top_m_axis_raw")
  ) u_raw_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(m_axis_raw_tdata),
    .tvalid(m_axis_raw_tvalid),
    .tready(m_axis_raw_tready),
    .tlast(m_axis_raw_tlast),
    .tuser(m_axis_raw_tuser),
    .protocol_error_count(raw_protocol_error_count)
  );

  mrtc_scoreboard #(
    .CASE_DIR(CASE_DIR),
    .EXPECTED_HEX_FILE("axis_comp_expected.hex"),
    .EXPECTED_CTRL_FILE("axis_comp_expected_ctrl.csv")
  ) u_comp_scoreboard (
    .i_compare_start(comp_compare_start),
    .i_byte_count(comp_monitor_byte_count),
    .i_beat_count(comp_monitor_beat_count),
    .i_bytes(comp_monitor_bytes),
    .o_pass(comp_compare_pass)
  );

  mrtc_scoreboard #(
    .CASE_DIR(CASE_DIR),
    .EXPECTED_HEX_FILE("axis_raw_in.hex"),
    .EXPECTED_CTRL_FILE("axis_raw_in_ctrl.csv")
  ) u_raw_scoreboard (
    .i_compare_start(raw_compare_start),
    .i_byte_count(raw_monitor_byte_count),
    .i_beat_count(raw_monitor_beat_count),
    .i_bytes(raw_monitor_bytes),
    .o_pass(raw_compare_pass)
  );

  initial begin
    wait(rst_n);
    wait(((driver_raw_done && driver_comp_done) && !stat_enc_busy && !stat_dec_busy) || (stat_enc_error != 0) || (stat_dec_error != 0));
    repeat (4) @(posedge clk);
    comp_compare_start = 1'b1;
    raw_compare_start = 1'b1;
    #1;
    if (stat_enc_error != 0) begin
      $fatal(1, "FAIL codec_top encoder stat_error=%0d", stat_enc_error);
    end
    if (stat_dec_error != 0) begin
      $fatal(1, "FAIL codec_top decoder stat_error=%0d", stat_dec_error);
    end
    if (comp_protocol_error_count != 0 || raw_protocol_error_count != 0) begin
      $fatal(1, "FAIL codec_top protocol errors comp=%0d raw=%0d", comp_protocol_error_count, raw_protocol_error_count);
    end
    if (!comp_compare_pass) begin
      $fatal(1, "FAIL codec_top encoder compare");
    end
    if (!raw_compare_pass) begin
      $fatal(1, "FAIL codec_top decoder compare");
    end
    $display("PASS tb_rdtc_codec_top_smoke enc_blocks=%0d dec_blocks=%0d", stat_enc_num_blocks, stat_dec_num_blocks);
    $finish;
  end

  initial begin
    repeat (500000) @(posedge clk);
    $fatal(1, "TIMEOUT codec_top smoke");
  end
endmodule
