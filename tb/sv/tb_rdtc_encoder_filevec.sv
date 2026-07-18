`timescale 1ns/1ps

module tb_rdtc_encoder_filevec #(
  parameter string CASE_DIR = "vectors/rdtc_v1/smoke_raw_bypass",
  parameter int CFG_CODEC_MODE = 1,
  parameter int CFG_RICE_MODE = 1,
  parameter int CFG_FIXED_K = 0,
  parameter int CFG_FRAME_ID = 1,
  parameter int BLOCK_ID_BASE = 0,
  parameter int TENSOR_SPATIAL_SIZE = 1,
  parameter int TENSOR_DOPPLER_SIZE = 64,
  parameter int TENSOR_RANGE_SIZE = 16
);
  import mrtc_pkg::*;

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

  logic         stat_busy;
  logic         stat_done;
  logic [31:0]  stat_raw_bytes;
  logic [31:0]  stat_comp_bytes;
  logic [31:0]  stat_num_blocks;
  logic [31:0]  stat_error;
  logic [7:0]   cfg_codec_mode_runtime;
  logic [7:0]   cfg_rice_mode_runtime;
  logic [3:0]   cfg_fixed_k_runtime;
  logic [15:0]  cfg_frame_id_runtime;
  integer       block_id_base_runtime;
  integer       tensor_spatial_size_runtime;
  integer       tensor_doppler_size_runtime;
  integer       tensor_range_size_runtime;
  string        resolved_case_dir;

  logic driver_done;
  logic monitor_done;
  integer monitor_byte_count;
  integer monitor_beat_count;
  integer protocol_error_count;
  byte monitor_bytes [0:32767];
  logic compare_start;
  logic compare_pass;
  logic print_encoder_cycles;
  logic check_ksel_wait;
  logic check_bpack_wait;
  logic supported_scan_case;
  logic expected_raw_bypass_case;
  int unsigned obs_cycle_count;
  int unsigned obs_block_ready_cycle;
  int unsigned obs_first_byte_cycle;
  int unsigned obs_ksel_wait_cycles;
  int unsigned obs_ksel_start_cycles;
  int unsigned obs_bpack_wait_cycles;
  logic obs_block_ready_seen;
  logic obs_first_byte_seen;
  logic obs_ksel_wait_seen;
  logic obs_bpack_wait_seen;
  logic obs_header_stream_seen;
  logic obs_raw_stream_seen;
  logic obs_bpack_stream_seen;

  localparam logic [3:0] ENC_ST_CAPTURE     = 4'd0;
  localparam logic [3:0] ENC_ST_KSEL_START  = 4'd1;
  localparam logic [3:0] ENC_ST_KSEL_WAIT   = 4'd2;
  localparam logic [3:0] ENC_ST_HEADER_START  = 4'd3;
  localparam logic [3:0] ENC_ST_HEADER_STREAM = 4'd4;
  localparam logic [3:0] ENC_ST_RAW_START     = 4'd5;
  localparam logic [3:0] ENC_ST_RAW_STREAM    = 4'd6;
  localparam logic [3:0] ENC_ST_BPACK_START   = 4'd7;
  localparam logic [3:0] ENC_ST_BPACK_STREAM  = 4'd8;
  localparam int RAW_PACKET_BEATS_128 = (MRTC_HEADER_BYTES + MRTC_RAW_BYTES + 15) / 16;

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
          $fatal(1, "tb_rdtc_encoder_filevec requires CASE_DIR or +CASE");
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
      expected_raw_bypass_case = ((flags & MRTC_FLAG_RAW_BYPASS) != 0);
    end
  endtask

  initial begin
    print_encoder_cycles = $test$plusargs("PRINT_ENCODER_CYCLES");
    check_ksel_wait = $test$plusargs("CHECK_KSEL_WAIT");
    check_bpack_wait = $test$plusargs("CHECK_BPACK_WAIT");
    cfg_codec_mode_runtime = CFG_CODEC_MODE[7:0];
    cfg_rice_mode_runtime = CFG_RICE_MODE[7:0];
    cfg_fixed_k_runtime = CFG_FIXED_K[3:0];
    cfg_frame_id_runtime = CFG_FRAME_ID[15:0];
    block_id_base_runtime = BLOCK_ID_BASE;
    tensor_spatial_size_runtime = TENSOR_SPATIAL_SIZE;
    tensor_doppler_size_runtime = TENSOR_DOPPLER_SIZE;
    tensor_range_size_runtime = TENSOR_RANGE_SIZE;
    expected_raw_bypass_case = 1'b0;
    resolve_case_dir(resolved_case_dir);
    if (CASE_DIR.len() == 0) begin
      load_case_cfg(resolved_case_dir);
    end
    supported_scan_case =
      ((cfg_codec_mode_runtime == MRTC_CODEC_ZERO_RICE) ||
       (cfg_codec_mode_runtime == MRTC_CODEC_DELTA_RICE)) &&
      ((cfg_rice_mode_runtime == MRTC_RICE_FIXED_K) ||
       (cfg_rice_mode_runtime == MRTC_RICE_BLOCK_ADAPTIVE_K));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      obs_cycle_count <= 0;
      obs_block_ready_cycle <= 0;
      obs_first_byte_cycle <= 0;
      obs_ksel_wait_cycles <= 0;
      obs_ksel_start_cycles <= 0;
      obs_bpack_wait_cycles <= 0;
      obs_block_ready_seen <= 1'b0;
      obs_first_byte_seen <= 1'b0;
      obs_ksel_wait_seen <= 1'b0;
      obs_bpack_wait_seen <= 1'b0;
      obs_header_stream_seen <= 1'b0;
      obs_raw_stream_seen <= 1'b0;
      obs_bpack_stream_seen <= 1'b0;
    end else begin
      obs_cycle_count <= obs_cycle_count + 1;

      if (u_dut.block_ready && !obs_block_ready_seen) begin
        obs_block_ready_seen <= 1'b1;
        obs_block_ready_cycle <= obs_cycle_count;
      end

      if ((u_dut.state_reg == ENC_ST_KSEL_START) && u_dut.ksel_start) begin
        obs_ksel_start_cycles <= obs_ksel_start_cycles + 1;
      end

      if (u_dut.state_reg == ENC_ST_KSEL_WAIT) begin
        obs_ksel_wait_seen <= 1'b1;
        obs_ksel_wait_cycles <= obs_ksel_wait_cycles + 1;
      end

      if (u_dut.state_reg == ENC_ST_HEADER_STREAM) begin
        obs_header_stream_seen <= 1'b1;
      end

      if (u_dut.state_reg == ENC_ST_RAW_STREAM) begin
        obs_raw_stream_seen <= 1'b1;
      end

      if (u_dut.state_reg == ENC_ST_BPACK_STREAM) begin
        obs_bpack_wait_seen <= 1'b1;
        obs_bpack_wait_cycles <= obs_bpack_wait_cycles + 1;
        obs_bpack_stream_seen <= 1'b1;
      end

      if ((m_axis_comp_tvalid && m_axis_comp_tready) && !obs_first_byte_seen) begin
        obs_first_byte_seen <= 1'b1;
        obs_first_byte_cycle <= obs_cycle_count;
      end
    end
  end

  mrtc_axis_driver #(
    .CASE_DIR(CASE_DIR)
  ) u_driver (
    .clk    (clk),
    .rst_n  (rst_n),
    .m_tdata(s_axis_raw_tdata),
    .m_tvalid(s_axis_raw_tvalid),
    .m_tready(s_axis_raw_tready),
    .m_tlast(s_axis_raw_tlast),
    .m_tuser(s_axis_raw_tuser),
    .o_done (driver_done)
  );

  mrtc_rdtc_encoder_top #(
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
    .cfg_codec_mode(cfg_codec_mode_runtime),
    .cfg_rice_mode(cfg_rice_mode_runtime),
    .cfg_fixed_k(cfg_fixed_k_runtime),
    .cfg_frame_id(cfg_frame_id_runtime),
    .cfg_block_id_base(block_id_base_runtime[15:0]),
    .cfg_tensor_spatial_size(tensor_spatial_size_runtime[15:0]),
    .cfg_tensor_doppler_size(tensor_doppler_size_runtime[15:0]),
    .cfg_tensor_range_size(tensor_range_size_runtime[15:0]),
    .stat_busy(stat_busy),
    .stat_done(stat_done),
    .stat_raw_bytes(stat_raw_bytes),
    .stat_comp_bytes(stat_comp_bytes),
    .stat_num_blocks(stat_num_blocks),
    .stat_error(stat_error),
    .stat_raw_bypass_blocks(),
    .stat_stall_input_cycles(),
    .stat_stall_output_cycles()
  );

  mrtc_axis_monitor u_monitor (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(m_axis_comp_tdata),
    .s_tvalid(m_axis_comp_tvalid),
    .s_tready(m_axis_comp_tready),
    .s_tlast(m_axis_comp_tlast),
    .s_tuser(m_axis_comp_tuser),
    .o_done(monitor_done),
    .o_byte_count(monitor_byte_count),
    .o_beat_count(monitor_beat_count),
    .o_bytes(monitor_bytes)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("encoder_m_axis_comp")
  ) u_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(m_axis_comp_tdata),
    .tvalid(m_axis_comp_tvalid),
    .tready(m_axis_comp_tready),
    .tlast(m_axis_comp_tlast),
    .tuser(m_axis_comp_tuser),
    .protocol_error_count(protocol_error_count)
  );

  mrtc_scoreboard #(
    .CASE_DIR(CASE_DIR)
  ) u_scoreboard (
    .i_compare_start(compare_start),
    .i_byte_count(monitor_byte_count),
    .i_beat_count(monitor_beat_count),
    .i_bytes(monitor_bytes),
    .o_pass(compare_pass)
  );

  initial begin
    wait(rst_n);
    wait(((driver_done && !stat_busy) || (stat_error != 0)));
    repeat (4) @(posedge clk);
    compare_start = 1'b1;
    #1;
    if (stat_error != 0) begin
      $fatal(1, "FAIL case=%s stat_error=%0d", resolved_case_dir, stat_error);
    end
    if (protocol_error_count != 0) begin
      $fatal(1, "FAIL case=%s protocol_error_count=%0d", resolved_case_dir, protocol_error_count);
    end
    if ((stat_num_blocks == 32'd1) && (monitor_beat_count != ((monitor_byte_count + 15) / 16))) begin
      $fatal(1,
             "FAIL case=%s beat_count=%0d byte_count=%0d expected_beats=%0d",
             resolved_case_dir, monitor_beat_count, monitor_byte_count, ((monitor_byte_count + 15) / 16));
    end
    if (expected_raw_bypass_case && (monitor_beat_count != RAW_PACKET_BEATS_128)) begin
      $fatal(1,
             "FAIL case=%s raw packet beat_count=%0d expected=%0d",
             resolved_case_dir, monitor_beat_count, RAW_PACKET_BEATS_128);
    end
    if (check_ksel_wait) begin
      if (obs_ksel_start_cycles != 1) begin
        $fatal(1, "FAIL case=%s expected one ksel_start pulse, got %0d",
               resolved_case_dir, obs_ksel_start_cycles);
      end
      if (supported_scan_case && !obs_ksel_wait_seen) begin
        $fatal(1, "FAIL case=%s expected ST_KSEL_WAIT for supported scan case", resolved_case_dir);
      end
      if (supported_scan_case && !obs_header_stream_seen) begin
        $fatal(1, "FAIL case=%s expected ST_HEADER_STREAM after k-select wait", resolved_case_dir);
      end
    end
    if (check_bpack_wait) begin
      if (supported_scan_case && !expected_raw_bypass_case && !obs_bpack_stream_seen) begin
        $fatal(1, "FAIL case=%s expected ST_BPACK_STREAM for compressed AXIS-width case", resolved_case_dir);
      end
    end
    if (print_encoder_cycles) begin
      $display(
        "ENCODER_CYCLES case=%s codec=%0d rice=%0d block_ready_to_first_beat=%0d ksel_wait_cycles=%0d bpack_stream_cycles=%0d ksel_start_pulses=%0d wait_seen=%0d header_seen=%0d raw_seen=%0d bpack_seen=%0d raw_bypass=%0d",
        resolved_case_dir,
        cfg_codec_mode_runtime,
        cfg_rice_mode_runtime,
        (obs_block_ready_seen && obs_first_byte_seen) ? (obs_first_byte_cycle - obs_block_ready_cycle) : 32'hFFFF_FFFF,
        obs_ksel_wait_cycles,
        obs_bpack_wait_cycles,
        obs_ksel_start_cycles,
        obs_ksel_wait_seen,
        obs_header_stream_seen,
        obs_raw_stream_seen,
        obs_bpack_wait_seen,
        expected_raw_bypass_case
      );
    end
    if (!compare_pass) begin
      $display(
        "FAIL_STATS case=%s raw_bytes=%0d comp_bytes=%0d blocks=%0d monitor_bytes=%0d monitor_beats=%0d",
        resolved_case_dir, stat_raw_bytes, stat_comp_bytes, stat_num_blocks, monitor_byte_count, monitor_beat_count
      );
      $display(
        "ACTUAL_HDR bytes24_29=%02x %02x %02x %02x %02x %02x",
        monitor_bytes[24], monitor_bytes[25], monitor_bytes[26],
        monitor_bytes[27], monitor_bytes[28], monitor_bytes[29]
      );
      $display(
        "ACTUAL_PAYLOAD bytes64_79=%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
        monitor_bytes[64], monitor_bytes[65], monitor_bytes[66], monitor_bytes[67],
        monitor_bytes[68], monitor_bytes[69], monitor_bytes[70], monitor_bytes[71],
        monitor_bytes[72], monitor_bytes[73], monitor_bytes[74], monitor_bytes[75],
        monitor_bytes[76], monitor_bytes[77], monitor_bytes[78], monitor_bytes[79]
      );
      $display(
        "PAYLOAD_DBG use_raw=%0d selected_k=%0d bits_pre=%0d bits_post=%0d bytes_pre=%0d bytes_post=%0d",
        u_dut.use_raw_pre, u_dut.selected_k, u_dut.payload_bits_pre, u_dut.payload_bits_post,
        u_dut.payload_bytes_pre, u_dut.payload_bytes_post
      );
      $display(
        "READ_DBG bank_owner=%0d sample_client=%0d bank_rd_req=%0d bank_rd_addr=%0d bank_rd_valid=%0d ksel_req=%0d bpack_req=%0d raw_req=%0d",
        u_dut.bank_owner_reg, u_dut.sample_client_reg, u_dut.bank_rd_req, u_dut.bank_rd_word_addr,
        u_dut.bank_rd_valid, u_dut.ksel_rd_req, u_dut.bpack_rd_req, u_dut.raw_bank_rd_req
      );
      $display(
        "OBS_DBG first_beat=%0d header_seen=%0d raw_seen=%0d bpack_seen=%0d beats=%0d",
        obs_first_byte_seen,
        obs_header_stream_seen,
        obs_raw_stream_seen,
        obs_bpack_stream_seen,
        monitor_beat_count
      );
      $fatal(1, "FAIL case=%s compare failed", resolved_case_dir);
    end
    $display(
      "PASS case=%s comp_bytes=%0d blocks=%0d protocol_errors=%0d",
      resolved_case_dir, stat_comp_bytes, stat_num_blocks, protocol_error_count
    );
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "TIMEOUT case=%s", resolved_case_dir);
  end
endmodule
