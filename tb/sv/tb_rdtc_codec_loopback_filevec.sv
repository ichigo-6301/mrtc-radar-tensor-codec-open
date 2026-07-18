`timescale 1ns/1ps

module tb_rdtc_codec_loopback_filevec #(
  parameter string CASE_DIR = ""
);
  logic clk;
  logic rst_n;

  logic [127:0] s_axis_raw_tdata;
  logic         s_axis_raw_tvalid;
  logic         s_axis_raw_tready;
  logic         s_axis_raw_tlast;
  logic [7:0]   s_axis_raw_tuser;

  logic [127:0] enc_axis_comp_tdata;
  logic         enc_axis_comp_tvalid;
  logic         enc_axis_comp_tready;
  logic         enc_axis_comp_tlast;
  logic [7:0]   enc_axis_comp_tuser;

  logic [127:0] dec_axis_raw_tdata;
  logic         dec_axis_raw_tvalid;
  logic         dec_axis_raw_tready;
  logic         dec_axis_raw_tlast;
  logic [7:0]   dec_axis_raw_tuser;

  logic         enc_stat_busy;
  logic         enc_stat_done;
  logic [31:0]  enc_stat_raw_bytes;
  logic [31:0]  enc_stat_comp_bytes;
  logic [31:0]  enc_stat_num_blocks;
  logic [31:0]  enc_stat_error;

  logic         dec_stat_busy;
  logic         dec_stat_done;
  logic [31:0]  dec_stat_comp_bytes;
  logic [31:0]  dec_stat_raw_bytes;
  logic [31:0]  dec_stat_num_blocks;
  logic [31:0]  dec_stat_error;

  logic [7:0]   cfg_codec_mode_runtime;
  logic [7:0]   cfg_rice_mode_runtime;
  logic [3:0]   cfg_fixed_k_runtime;
  logic [15:0]  cfg_frame_id_runtime;
  integer       block_id_base_runtime;
  integer       tensor_spatial_size_runtime;
  integer       tensor_doppler_size_runtime;
  integer       tensor_range_size_runtime;

  logic         driver_done;
  integer       monitor_byte_count;
  integer       monitor_beat_count;
  integer       enc_protocol_error_count;
  integer       dec_protocol_error_count;
  byte          monitor_bytes [0:32767];
  logic         compare_start;
  logic         compare_pass;
  string        resolved_case_dir;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rst_n = 1'b0;
    compare_start = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
  end

  task automatic resolve_case_dir(output string out_case_dir);
    string vec_root;
    string case_name;
    begin
      if (CASE_DIR.len() != 0) begin
        out_case_dir = CASE_DIR;
      end else begin
        vec_root = "vectors/rdtc_v1";
        case_name = "";
        void'($value$plusargs("VEC_ROOT=%s", vec_root));
        void'($value$plusargs("CASE=%s", case_name));
        if (case_name.len() == 0) begin
          $fatal(1, "tb_rdtc_codec_loopback_filevec requires CASE_DIR or +CASE");
        end
        out_case_dir = {vec_root, "/", case_name};
      end
    end
  endtask

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
    resolve_case_dir(resolved_case_dir);
    load_case_cfg(resolved_case_dir);
  end

  mrtc_axis_driver #(
    .CASE_DIR(CASE_DIR),
    .HEX_FILE("axis_raw_in.hex"),
    .CTRL_FILE("axis_raw_in_ctrl.csv"),
    .LOAD_BLOCK_CODECS(1'b1),
    .EMIT_LAST_BYTE_COUNT(1'b0)
  ) u_driver (
    .clk     (clk),
    .rst_n   (rst_n),
    .m_tdata (s_axis_raw_tdata),
    .m_tvalid(s_axis_raw_tvalid),
    .m_tready(s_axis_raw_tready),
    .m_tlast (s_axis_raw_tlast),
    .m_tuser (s_axis_raw_tuser),
    .o_done  (driver_done)
  );

  mrtc_rdtc_encoder_top #(
    .AXIS_DATA_W(128)
  ) u_encoder (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(1'b0),
    .s_axis_raw_tdata(s_axis_raw_tdata),
    .s_axis_raw_tvalid(s_axis_raw_tvalid),
    .s_axis_raw_tready(s_axis_raw_tready),
    .s_axis_raw_tlast(s_axis_raw_tlast),
    .s_axis_raw_tuser(s_axis_raw_tuser),
    .m_axis_comp_tdata(enc_axis_comp_tdata),
    .m_axis_comp_tvalid(enc_axis_comp_tvalid),
    .m_axis_comp_tready(enc_axis_comp_tready),
    .m_axis_comp_tlast(enc_axis_comp_tlast),
    .m_axis_comp_tuser(enc_axis_comp_tuser),
    .cfg_codec_mode(cfg_codec_mode_runtime),
    .cfg_rice_mode(cfg_rice_mode_runtime),
    .cfg_fixed_k(cfg_fixed_k_runtime),
    .cfg_frame_id(cfg_frame_id_runtime),
    .cfg_block_id_base(block_id_base_runtime[15:0]),
    .cfg_tensor_spatial_size(tensor_spatial_size_runtime[15:0]),
    .cfg_tensor_doppler_size(tensor_doppler_size_runtime[15:0]),
    .cfg_tensor_range_size(tensor_range_size_runtime[15:0]),
    .stat_busy(enc_stat_busy),
    .stat_done(enc_stat_done),
    .stat_raw_bytes(enc_stat_raw_bytes),
    .stat_comp_bytes(enc_stat_comp_bytes),
    .stat_num_blocks(enc_stat_num_blocks),
    .stat_error(enc_stat_error),
    .stat_raw_bypass_blocks(),
    .stat_stall_input_cycles(),
    .stat_stall_output_cycles()
  );

  mrtc_rdtc_decoder_top #(
    .AXIS_DATA_W(128)
  ) u_decoder (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(1'b0),
    .s_axis_comp_tdata(enc_axis_comp_tdata),
    .s_axis_comp_tvalid(enc_axis_comp_tvalid),
    .s_axis_comp_tready(enc_axis_comp_tready),
    .s_axis_comp_tlast(enc_axis_comp_tlast),
    .s_axis_comp_tuser(enc_axis_comp_tuser),
    .m_axis_raw_tdata(dec_axis_raw_tdata),
    .m_axis_raw_tvalid(dec_axis_raw_tvalid),
    .m_axis_raw_tready(dec_axis_raw_tready),
    .m_axis_raw_tlast(dec_axis_raw_tlast),
    .m_axis_raw_tuser(dec_axis_raw_tuser),
    .stat_busy(dec_stat_busy),
    .stat_done(dec_stat_done),
    .stat_comp_bytes(dec_stat_comp_bytes),
    .stat_raw_bytes(dec_stat_raw_bytes),
    .stat_num_blocks(dec_stat_num_blocks),
    .stat_error(dec_stat_error),
    .stat_error_blocks(),
    .stat_stall_input_cycles(),
    .stat_stall_output_cycles()
  );

  mrtc_axis_monitor #(
    .USE_TUSER_BYTE_COUNT_ON_TLAST(1'b0)
  ) u_monitor (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(dec_axis_raw_tdata),
    .s_tvalid(dec_axis_raw_tvalid),
    .s_tready(dec_axis_raw_tready),
    .s_tlast(dec_axis_raw_tlast),
    .s_tuser(dec_axis_raw_tuser),
    .o_done(),
    .o_byte_count(monitor_byte_count),
    .o_beat_count(monitor_beat_count),
    .o_bytes(monitor_bytes)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("loopback_enc_comp")
  ) u_enc_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(enc_axis_comp_tdata),
    .tvalid(enc_axis_comp_tvalid),
    .tready(enc_axis_comp_tready),
    .tlast(enc_axis_comp_tlast),
    .tuser(enc_axis_comp_tuser),
    .protocol_error_count(enc_protocol_error_count)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("loopback_dec_raw")
  ) u_dec_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(dec_axis_raw_tdata),
    .tvalid(dec_axis_raw_tvalid),
    .tready(dec_axis_raw_tready),
    .tlast(dec_axis_raw_tlast),
    .tuser(dec_axis_raw_tuser),
    .protocol_error_count(dec_protocol_error_count)
  );

  mrtc_scoreboard #(
    .CASE_DIR(CASE_DIR),
    .EXPECTED_HEX_FILE("axis_raw_in.hex"),
    .EXPECTED_CTRL_FILE("axis_raw_in_ctrl.csv")
  ) u_scoreboard (
    .i_compare_start(compare_start),
    .i_byte_count(monitor_byte_count),
    .i_beat_count(monitor_beat_count),
    .i_bytes(monitor_bytes),
    .o_pass(compare_pass)
  );

  initial begin
    wait(rst_n);
    wait(((driver_done && !enc_stat_busy && !dec_stat_busy) || (enc_stat_error != 0) || (dec_stat_error != 0)));
    repeat (4) @(posedge clk);
    compare_start = 1'b1;
    #1;
    if (enc_stat_error != 0) begin
      $fatal(1, "FAIL loopback encoder case=%s stat_error=%0d", resolved_case_dir, enc_stat_error);
    end
    if (dec_stat_error != 0) begin
      $fatal(1, "FAIL loopback decoder case=%s stat_error=%0d", resolved_case_dir, dec_stat_error);
    end
    if (enc_protocol_error_count != 0) begin
      $fatal(1, "FAIL loopback encoder case=%s protocol_error_count=%0d", resolved_case_dir, enc_protocol_error_count);
    end
    if (dec_protocol_error_count != 0) begin
      $fatal(1, "FAIL loopback decoder case=%s protocol_error_count=%0d", resolved_case_dir, dec_protocol_error_count);
    end
    if (!compare_pass) begin
      $display(
        "FAIL_LOOPBACK case=%s enc_blocks=%0d dec_blocks=%0d monitor_bytes=%0d monitor_beats=%0d",
        resolved_case_dir, enc_stat_num_blocks, dec_stat_num_blocks, monitor_byte_count, monitor_beat_count
      );
      $fatal(1, "FAIL loopback case=%s compare failed", resolved_case_dir);
    end
    $display(
      "PASS tb_rdtc_codec_loopback_filevec %s enc_protocol_errors=%0d dec_protocol_errors=%0d",
      resolved_case_dir, enc_protocol_error_count, dec_protocol_error_count
    );
    $finish;
  end

  initial begin
    repeat (700000) @(posedge clk);
    $fatal(1, "TIMEOUT loopback case=%s", resolved_case_dir);
  end
endmodule
