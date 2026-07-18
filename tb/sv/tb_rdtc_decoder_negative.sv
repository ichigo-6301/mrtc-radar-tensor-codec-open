`timescale 1ns/1ps

module tb_rdtc_decoder_negative #(
  parameter string CASE_DIR = ""
);
  logic clk;
  logic rst_n;

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

  logic         stat_busy;
  logic         stat_done;
  logic [31:0]  stat_comp_bytes;
  logic [31:0]  stat_raw_bytes;
  logic [31:0]  stat_num_blocks;
  logic [31:0]  stat_error;

  logic driver_done;
  integer monitor_byte_count;
  integer monitor_beat_count;
  integer protocol_error_count;
  integer expected_error;
  integer expected_timeout;
  integer timeout_flag;
  byte monitor_bytes [0:32767];
  string resolved_case_dir;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rst_n = 1'b0;
    timeout_flag = 0;
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
        vec_root = "vectors/rdtc_v1_negative";
        case_name = "";
        void'($value$plusargs("VEC_ROOT=%s", vec_root));
        void'($value$plusargs("CASE=%s", case_name));
        if (case_name.len() == 0) begin
          $fatal(1, "tb_rdtc_decoder_negative requires CASE_DIR or +CASE");
        end
        out_case_dir = {vec_root, "/", case_name};
      end
    end
  endtask

  task automatic load_expected_error(input string case_dir, output integer error_code);
    int fd;
    int code;
    string path;
    begin
      path = {case_dir, "/expected_error.txt"};
      error_code = -1;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        $fatal(1, "failed to open %s", path);
      end
      code = $fscanf(fd, "%d\n", error_code);
      $fclose(fd);
      if (code != 1) begin
        $fatal(1, "failed to parse expected_error from %s", path);
      end
    end
  endtask

  task automatic load_expected_timeout(input string case_dir, output integer timeout_expect);
    int fd;
    int code;
    string path;
    begin
      path = {case_dir, "/expected_timeout.txt"};
      timeout_expect = 0;
      fd = $fopen(path, "r");
      if (fd != 0) begin
        code = $fscanf(fd, "%d\n", timeout_expect);
        $fclose(fd);
        if (code != 1) begin
          $fatal(1, "failed to parse expected_timeout from %s", path);
        end
      end
    end
  endtask

  initial begin
    resolve_case_dir(resolved_case_dir);
    load_expected_error(resolved_case_dir, expected_error);
    load_expected_timeout(resolved_case_dir, expected_timeout);
  end

  mrtc_axis_driver #(
    .CASE_DIR(CASE_DIR),
    .HEX_FILE("axis_comp_bad.hex"),
    .CTRL_FILE("axis_comp_bad_ctrl.csv"),
    .LOAD_BLOCK_CODECS(1'b0),
    .EMIT_LAST_BYTE_COUNT(1'b1)
  ) u_driver (
    .clk     (clk),
    .rst_n   (rst_n),
    .m_tdata (s_axis_comp_tdata),
    .m_tvalid(s_axis_comp_tvalid),
    .m_tready(s_axis_comp_tready),
    .m_tlast (s_axis_comp_tlast),
    .m_tuser (s_axis_comp_tuser),
    .o_done  (driver_done)
  );

  mrtc_rdtc_decoder_top #(
    .AXIS_DATA_W(128)
  ) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(1'b0),
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
    .stat_busy(stat_busy),
    .stat_done(stat_done),
    .stat_comp_bytes(stat_comp_bytes),
    .stat_raw_bytes(stat_raw_bytes),
    .stat_num_blocks(stat_num_blocks),
    .stat_error(stat_error),
    .stat_error_blocks(),
    .stat_stall_input_cycles(),
    .stat_stall_output_cycles()
  );

  mrtc_axis_monitor #(
    .USE_TUSER_BYTE_COUNT_ON_TLAST(1'b0)
  ) u_monitor (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(m_axis_raw_tdata),
    .s_tvalid(m_axis_raw_tvalid),
    .s_tready(m_axis_raw_tready),
    .s_tlast(m_axis_raw_tlast),
    .s_tuser(m_axis_raw_tuser),
    .o_done(),
    .o_byte_count(monitor_byte_count),
    .o_beat_count(monitor_beat_count),
    .o_bytes(monitor_bytes)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("decoder_negative_m_axis_raw")
  ) u_protocol_checker (
    .clk(clk),
    .rst_n(rst_n),
    .tdata(m_axis_raw_tdata),
    .tvalid(m_axis_raw_tvalid),
    .tready(m_axis_raw_tready),
    .tlast(m_axis_raw_tlast),
    .tuser(m_axis_raw_tuser),
    .protocol_error_count(protocol_error_count)
  );

  initial begin
    wait(rst_n);
    wait((stat_error != 0) || (driver_done && !stat_busy) || timeout_flag);
    repeat (4) @(posedge clk);
    if (expected_timeout != 0) begin
      if (!timeout_flag) begin
        $fatal(
          1,
          "FAIL tb_rdtc_decoder_negative %s expected timeout but got actual_error=%0d raw_words_output=%0d",
          resolved_case_dir, stat_error, monitor_beat_count
        );
      end
      if (stat_error != 0) begin
        $fatal(
          1,
          "FAIL tb_rdtc_decoder_negative %s expected timeout-only but actual_error=%0d raw_words_output=%0d",
          resolved_case_dir, stat_error, monitor_beat_count
        );
      end
      if (monitor_byte_count != 0 || monitor_beat_count != 0) begin
        $fatal(
          1,
          "FAIL tb_rdtc_decoder_negative %s expected timeout-only raw_words_output=%0d",
          resolved_case_dir, monitor_beat_count
        );
      end
      if (protocol_error_count != 0) begin
        $fatal(1, "FAIL tb_rdtc_decoder_negative %s protocol_error_count=%0d", resolved_case_dir, protocol_error_count);
      end
      $display("PASS tb_rdtc_decoder_negative %s timeout", resolved_case_dir);
      $finish;
    end
    if (timeout_flag) begin
      $fatal(
        1,
        "FAIL tb_rdtc_decoder_negative %s expected_error=%0d actual_error=%0d raw_words_output=%0d timeout=1",
        resolved_case_dir, expected_error, stat_error, monitor_beat_count
      );
    end
    if (stat_error != expected_error) begin
      $fatal(
        1,
        "FAIL tb_rdtc_decoder_negative %s expected_error=%0d actual_error=%0d raw_words_output=%0d timeout=0",
        resolved_case_dir, expected_error, stat_error, monitor_beat_count
      );
    end
    if (monitor_byte_count != 0 || monitor_beat_count != 0) begin
      $fatal(
        1,
        "FAIL tb_rdtc_decoder_negative %s expected_error=%0d actual_error=%0d raw_words_output=%0d timeout=0",
        resolved_case_dir, expected_error, stat_error, monitor_beat_count
      );
    end
    if (protocol_error_count != 0) begin
      $fatal(1, "FAIL tb_rdtc_decoder_negative %s protocol_error_count=%0d", resolved_case_dir, protocol_error_count);
    end
    $display("PASS tb_rdtc_decoder_negative %s", resolved_case_dir);
    $finish;
  end

  initial begin
    repeat (500000) @(posedge clk);
    timeout_flag = 1;
  end
endmodule
