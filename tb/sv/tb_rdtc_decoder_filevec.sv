`timescale 1ns/1ps

module tb_rdtc_decoder_filevec #(
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
  byte monitor_bytes [0:32767];
  logic compare_start;
  logic compare_pass;
  string resolved_case_dir;

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
          $fatal(1, "tb_rdtc_decoder_filevec requires CASE_DIR or +CASE");
        end
        out_case_dir = {vec_root, "/", case_name};
      end
    end
  endtask

  initial begin
    resolve_case_dir(resolved_case_dir);
  end

  mrtc_axis_driver #(
    .CASE_DIR(CASE_DIR),
    .HEX_FILE("axis_comp_expected.hex"),
    .CTRL_FILE("axis_comp_expected_ctrl.csv"),
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
    .NAME("decoder_m_axis_raw")
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
    wait(((driver_done && !stat_busy) || (stat_error != 0)));
    repeat (4) @(posedge clk);
    compare_start = 1'b1;
    #1;
    if (stat_error != 0) begin
      $fatal(1, "FAIL decoder case=%s stat_error=%0d", resolved_case_dir, stat_error);
    end
    if (protocol_error_count != 0) begin
      $fatal(1, "FAIL decoder case=%s protocol_error_count=%0d", resolved_case_dir, protocol_error_count);
    end
    if (!compare_pass) begin
      $display(
        "FAIL_DECODER case=%s comp_bytes=%0d raw_bytes=%0d blocks=%0d monitor_bytes=%0d monitor_beats=%0d",
        resolved_case_dir, stat_comp_bytes, stat_raw_bytes, stat_num_blocks, monitor_byte_count, monitor_beat_count
      );
      $fatal(1, "FAIL decoder case=%s compare failed", resolved_case_dir);
    end
    $display("PASS tb_rdtc_decoder_filevec %s protocol_errors=%0d", resolved_case_dir, protocol_error_count);
    $finish;
  end

  initial begin
    repeat (400000) @(posedge clk);
    $fatal(1, "TIMEOUT decoder case=%s", resolved_case_dir);
  end
endmodule
