`timescale 1ns/1ps

module tb_rdtc_encoder_pingpong_two_block;
  import mrtc_pkg::*;

  localparam string CASE_DIR = "vectors/rdtc_v1/smoke_multi_block";
  localparam int RAW_PACKET0_BEATS_128 = (1266 + 15) / 16;
  localparam int RAW_PACKET1_BEATS_128 = (1477 + 15) / 16;

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
  logic [31:0]  stat_raw_bypass_blocks;
  logic [31:0]  stat_stall_input_cycles;
  logic [31:0]  stat_stall_output_cycles;

  logic monitor_done;
  integer monitor_byte_count;
  integer monitor_beat_count;
  integer monitor_packet_count;
  integer protocol_error_count;
  byte monitor_bytes [0:32767];
  logic compare_start;
  logic compare_pass;

  int unsigned first_block_done_cycle;
  int unsigned second_block_start_cycle;
  int unsigned second_block_done_cycle;
  logic first_block_done_seen;
  logic second_block_start_seen;
  logic second_block_done_seen;
  logic overlap_capture_seen;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rst_n = 1'b0;
    compare_start = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      first_block_done_cycle <= 0;
      second_block_start_cycle <= 0;
      second_block_done_cycle <= 0;
      first_block_done_seen <= 1'b0;
      second_block_start_seen <= 1'b0;
      second_block_done_seen <= 1'b0;
      overlap_capture_seen <= 1'b0;
    end else begin
      if (!first_block_done_seen && u_dut.u_pingpong_block_bank_manager.o_capture_accepted_blocks >= 32'd1) begin
        first_block_done_seen <= 1'b1;
        first_block_done_cycle <= $time;
      end
      if (!second_block_start_seen &&
          u_driver.current_beat > 0 &&
          u_driver.beat_block_idx[u_driver.current_beat] == 1 &&
          s_axis_raw_tvalid && s_axis_raw_tready) begin
        second_block_start_seen <= 1'b1;
        second_block_start_cycle <= $time;
      end
      if (!second_block_done_seen && u_dut.u_pingpong_block_bank_manager.o_capture_accepted_blocks >= 32'd2) begin
        second_block_done_seen <= 1'b1;
        second_block_done_cycle <= $time;
      end
      if (u_dut.proc_active_valid && s_axis_raw_tvalid && s_axis_raw_tready &&
          u_dut.fill_bank_valid && (u_dut.fill_bank_sel != u_dut.proc_active_bank_sel)) begin
        overlap_capture_seen <= 1'b1;
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
    .o_done ()
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
    .cfg_codec_mode(8'd1),
    .cfg_rice_mode(8'd1),
    .cfg_fixed_k(4'd0),
    .cfg_frame_id(16'd1),
    .cfg_block_id_base(16'd6),
    .cfg_tensor_spatial_size(16'd1),
    .cfg_tensor_doppler_size(16'd64),
    .cfg_tensor_range_size(16'd32),
    .stat_busy(stat_busy),
    .stat_done(stat_done),
    .stat_raw_bytes(stat_raw_bytes),
    .stat_comp_bytes(stat_comp_bytes),
    .stat_num_blocks(stat_num_blocks),
    .stat_error(stat_error),
    .stat_raw_bypass_blocks(stat_raw_bypass_blocks),
    .stat_stall_input_cycles(stat_stall_input_cycles),
    .stat_stall_output_cycles(stat_stall_output_cycles)
  );

  mrtc_axis_packet_monitor u_monitor (
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
    .o_packet_count(monitor_packet_count),
    .o_bytes(monitor_bytes)
  );

  mrtc_axis_protocol_checker #(
    .AXIS_DATA_W(128),
    .TUSER_W(8),
    .NAME("encoder_m_axis_comp_pingpong")
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
    wait(((monitor_done && !stat_busy) || (stat_error != 0)));
    repeat (4) @(posedge clk);
    compare_start = 1'b1;
    #1;
    if (stat_error != 0) begin
      $fatal(1, "FAIL tb_rdtc_encoder_pingpong_two_block stat_error=%0d", stat_error);
    end
    if (protocol_error_count != 0) begin
      $fatal(1, "FAIL tb_rdtc_encoder_pingpong_two_block protocol_error_count=%0d", protocol_error_count);
    end
    if (monitor_packet_count != 2) begin
      $fatal(1, "FAIL tb_rdtc_encoder_pingpong_two_block packet_count=%0d expected=2", monitor_packet_count);
    end
    if (stat_num_blocks != 32'd2) begin
      $fatal(1, "FAIL tb_rdtc_encoder_pingpong_two_block stat_num_blocks=%0d", stat_num_blocks);
    end
    if (!overlap_capture_seen) begin
      $fatal(1, "FAIL tb_rdtc_encoder_pingpong_two_block expected capture/processing overlap");
    end
    if (!compare_pass) begin
      $fatal(1, "FAIL tb_rdtc_encoder_pingpong_two_block compare failed");
    end
    $display(
      "PASS tb_rdtc_encoder_pingpong_two_block packets=%0d bytes=%0d beats=%0d overlap=%0d stall_in=%0d stall_out=%0d",
      monitor_packet_count, monitor_byte_count, monitor_beat_count,
      overlap_capture_seen, stat_stall_input_cycles, stat_stall_output_cycles
    );
    $finish;
  end

  initial begin
    repeat (400000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_rdtc_encoder_pingpong_two_block");
  end
endmodule
