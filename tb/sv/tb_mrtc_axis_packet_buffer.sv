`timescale 1ns/1ps

module tb_mrtc_axis_packet_buffer;
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int TUSER_W = 8;
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int MAX_PACKET_BYTES = MRTC_MAX_OUTPUT_BYTES;
  localparam int MAX_PACKET_BEATS = (MAX_PACKET_BYTES + AXIS_BYTES - 1) / AXIS_BYTES;
  localparam int PACKET_DEPTH = 2;
  localparam int MAX_CAPTURE_BYTES = 16384;
  localparam int MAX_PACKET_HISTORY = 32;

  logic clk;
  logic rst_n;
  logic i_clear_status;

  logic [AXIS_DATA_W-1:0] s_axis_tdata;
  logic                   s_axis_tvalid;
  logic                   s_axis_tready;
  logic                   s_axis_tlast;
  logic [TUSER_W-1:0]     s_axis_tuser;

  logic                   o_packet_valid;
  logic                   i_packet_start;
  logic [AXIS_DATA_W-1:0] m_axis_tdata;
  logic                   m_axis_tvalid;
  logic                   m_axis_tready;
  logic                   m_axis_tlast;
  logic [TUSER_W-1:0]     m_axis_tuser;

  logic                   o_busy;
  logic                   o_full;
  logic                   o_overflow;
  logic [31:0]            o_packets_written;
  logic [31:0]            o_packets_read;
  logic [31:0]            o_write_stall_cycles;
  logic [31:0]            o_read_stall_cycles;
  logic [$clog2(PACKET_DEPTH + 1)-1:0] o_max_occupancy;

  byte expected_bytes [0:MAX_CAPTURE_BYTES-1];
  byte actual_bytes [0:MAX_CAPTURE_BYTES-1];
  int expected_byte_count;
  int case_expected_packets;
  int case_actual_start;
  int case_done_start;
  int case_write_stall_start;
  int case_read_stall_start;
  int case_packets_written_start;
  int case_packets_read_start;
  int case_last_valid_bytes [0:MAX_PACKET_HISTORY-1];
  int case_last_valid_count;
  int packet_start_count;
  int packet_done_count;
  int actual_byte_count;
  int packet_last_valid_bytes_hist [0:MAX_PACKET_HISTORY-1];
  int byte_idx;

  int ready_mode;
  int unsigned ready_rand_state;

  function automatic int unsigned next_rand(input int unsigned cur_state);
    next_rand = (cur_state * 32'd1664525) + 32'd1013904223;
  endfunction

  mrtc_axis_packet_buffer #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W),
    .MAX_PACKET_BYTES(MAX_PACKET_BYTES),
    .MAX_PACKET_BEATS(MAX_PACKET_BEATS),
    .PACKET_DEPTH(PACKET_DEPTH)
  ) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(i_clear_status),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .o_packet_valid(o_packet_valid),
    .i_packet_start(i_packet_start),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser),
    .o_busy(o_busy),
    .o_full(o_full),
    .o_overflow(o_overflow),
    .o_packets_written(o_packets_written),
    .o_packets_read(o_packets_read),
    .o_write_stall_cycles(o_write_stall_cycles),
    .o_read_stall_cycles(o_read_stall_cycles),
    .o_max_occupancy(o_max_occupancy)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_n) begin
    int valid_bytes;
    int unsigned next_state;
    if (!rst_n) begin
      actual_byte_count <= 0;
      packet_done_count <= 0;
      ready_rand_state <= 32'h42AA_1701;
      m_axis_tready <= 1'b0;
    end else begin
      next_state = next_rand(ready_rand_state);
      ready_rand_state <= next_state;
      if (ready_mode == 1) begin
        m_axis_tready <= next_state[7];
      end else begin
        m_axis_tready <= 1'b1;
      end

      if (m_axis_tvalid && m_axis_tready) begin
        valid_bytes = m_axis_tlast ? (m_axis_tuser[3:0] + 1) : AXIS_BYTES;
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          actual_bytes[actual_byte_count + byte_idx] <= m_axis_tdata[(byte_idx * 8) +: 8];
        end
        actual_byte_count <= actual_byte_count + valid_bytes;
        if (m_axis_tlast) begin
          packet_last_valid_bytes_hist[packet_done_count] <= valid_bytes;
          packet_done_count <= packet_done_count + 1;
        end
      end
    end
  end

  task automatic begin_case(input int expected_packets);
    begin
      expected_byte_count = 0;
      case_expected_packets = expected_packets;
      case_actual_start = actual_byte_count;
      case_done_start = packet_done_count;
      case_write_stall_start = o_write_stall_cycles;
      case_read_stall_start = o_read_stall_cycles;
      case_packets_written_start = o_packets_written;
      case_packets_read_start = o_packets_read;
      case_last_valid_count = 0;
      for (byte_idx = 0; byte_idx < MAX_CAPTURE_BYTES; byte_idx = byte_idx + 1) begin
        expected_bytes[byte_idx] = 8'h00;
      end
    end
  endtask

  task automatic append_expected_word(
    input logic [AXIS_DATA_W-1:0] word_data,
    input int valid_bytes,
    input bit last_word
  );
    begin
      for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
        expected_bytes[expected_byte_count + byte_idx] = word_data[(byte_idx * 8) +: 8];
      end
      expected_byte_count = expected_byte_count + valid_bytes;
      if (last_word) begin
        case_last_valid_bytes[case_last_valid_count] = valid_bytes;
        case_last_valid_count = case_last_valid_count + 1;
      end
    end
  endtask

  task automatic drive_word(
    input logic [AXIS_DATA_W-1:0] word_data,
    input int valid_bytes,
    input logic word_last,
    input int idle_cycles
  );
    begin
      repeat (idle_cycles) @(negedge clk);
      append_expected_word(word_data, valid_bytes, word_last);
      s_axis_tdata = word_data;
      s_axis_tuser = TUSER_W'(valid_bytes - 1);
      s_axis_tlast = word_last;
      s_axis_tvalid = 1'b1;
      while (!s_axis_tready) begin
        @(negedge clk);
      end
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tuser = '0;
      s_axis_tdata = '0;
    end
  endtask

  task automatic start_packet_read;
    begin
      wait (o_packet_valid && !m_axis_tvalid);
      @(negedge clk);
      i_packet_start = 1'b1;
      @(negedge clk);
      i_packet_start = 1'b0;
      packet_start_count = packet_start_count + 1;
    end
  endtask

  task automatic finish_case(input string case_name);
    int actual_delta;
    begin
      wait (packet_done_count == (case_done_start + case_expected_packets));
      @(posedge clk);
      actual_delta = actual_byte_count - case_actual_start;
      if (o_overflow !== 1'b0) begin
        $fatal(1, "FAIL tb_mrtc_axis_packet_buffer case=%s overflow", case_name);
      end
      if (actual_delta != expected_byte_count) begin
        $fatal(1, "FAIL tb_mrtc_axis_packet_buffer case=%s byte_count exp=%0d got=%0d",
               case_name, expected_byte_count, actual_delta);
      end
      for (byte_idx = 0; byte_idx < expected_byte_count; byte_idx = byte_idx + 1) begin
        if (actual_bytes[case_actual_start + byte_idx] !== expected_bytes[byte_idx]) begin
          $fatal(1, "FAIL tb_mrtc_axis_packet_buffer case=%s byte=%0d exp=%02x got=%02x",
                 case_name, byte_idx, expected_bytes[byte_idx], actual_bytes[case_actual_start + byte_idx]);
        end
      end
      for (byte_idx = 0; byte_idx < case_last_valid_count; byte_idx = byte_idx + 1) begin
        if (packet_last_valid_bytes_hist[case_done_start + byte_idx] != case_last_valid_bytes[byte_idx]) begin
          $fatal(1, "FAIL tb_mrtc_axis_packet_buffer case=%s last_valid_bytes idx=%0d exp=%0d got=%0d",
                 case_name,
                 byte_idx,
                 case_last_valid_bytes[byte_idx],
                 packet_last_valid_bytes_hist[case_done_start + byte_idx]);
        end
      end
    end
  endtask

  task automatic run_single_sparse_packet;
    logic [AXIS_DATA_W-1:0] word0;
    logic [AXIS_DATA_W-1:0] word1;
    begin
      ready_mode = 0;
      begin_case(1);
      word0 = 128'h0011_2233_4455_6677_8899_AABB_CCDD_EEFF;
      word1 = 128'h1234_5678_9ABC_DEF0_0F1E_2D3C_4B5A_6978;
      drive_word(word0, 16, 1'b0, 0);
      drive_word(word1, 5, 1'b1, 7);
      start_packet_read();
      finish_case("single_sparse_packet");
    end
  endtask

  task automatic run_max_raw_packet;
    logic [AXIS_DATA_W-1:0] word_data;
    int beat_idx;
    begin
      ready_mode = 0;
      begin_case(1);
      for (beat_idx = 0; beat_idx < MAX_PACKET_BEATS; beat_idx = beat_idx + 1) begin
        word_data = {
          32'(beat_idx + 32'h3000),
          32'(beat_idx + 32'h2000),
          32'(beat_idx + 32'h1000),
          32'(beat_idx + 32'h0000)
        };
        drive_word(word_data, 16, (beat_idx == (MAX_PACKET_BEATS - 1)), 0);
      end
      start_packet_read();
      finish_case("max_raw_packet");
    end
  endtask

  task automatic run_two_packets_back_to_back;
    logic [AXIS_DATA_W-1:0] word_data;
    begin
      ready_mode = 0;
      begin_case(2);
      word_data = 128'hAA00_AA01_AA02_AA03_AA04_AA05_AA06_AA07;
      drive_word(word_data, 9, 1'b1, 0);
      word_data = 128'hBB00_BB01_BB02_BB03_BB04_BB05_BB06_BB07;
      drive_word(word_data, 16, 1'b0, 0);
      word_data = 128'hCC00_CC01_CC02_CC03_CC04_CC05_CC06_CC07;
      drive_word(word_data, 3, 1'b1, 0);
      start_packet_read();
      start_packet_read();
      finish_case("two_packets_back_to_back");
      if (o_max_occupancy < 2) begin
        $fatal(1, "FAIL tb_mrtc_axis_packet_buffer expected occupancy >= 2, got %0d", o_max_occupancy);
      end
    end
  endtask

  task automatic run_random_output_backpressure;
    logic [AXIS_DATA_W-1:0] word0;
    logic [AXIS_DATA_W-1:0] word1;
    logic [AXIS_DATA_W-1:0] word2;
    int read_stall_start;
    begin
      ready_mode = 1;
      begin_case(1);
      read_stall_start = o_read_stall_cycles;
      word0 = 128'h1100_1101_1102_1103_1104_1105_1106_1107;
      word1 = 128'h2200_2201_2202_2203_2204_2205_2206_2207;
      word2 = 128'h3300_3301_3302_3303_3304_3305_3306_3307;
      drive_word(word0, 16, 1'b0, 0);
      drive_word(word1, 16, 1'b0, 2);
      drive_word(word2, 11, 1'b1, 3);
      start_packet_read();
      finish_case("random_output_backpressure");
      if (o_read_stall_cycles <= read_stall_start) begin
        $fatal(1, "FAIL tb_mrtc_axis_packet_buffer expected read stall increment");
      end
      ready_mode = 0;
    end
  endtask

  task automatic run_buffer_full_backpressure;
    logic [AXIS_DATA_W-1:0] word_data;
    int write_stall_start;
    begin
      ready_mode = 0;
      begin_case(3);
      write_stall_start = o_write_stall_cycles;
      word_data = 128'hD000_D001_D002_D003_D004_D005_D006_D007;
      drive_word(word_data, 16, 1'b1, 0);
      word_data = 128'hE000_E001_E002_E003_E004_E005_E006_E007;
      drive_word(word_data, 16, 1'b1, 0);

      append_expected_word(128'hF000_F001_F002_F003_F004_F005_F006_F007, 16, 1'b1);
      s_axis_tdata = 128'hF000_F001_F002_F003_F004_F005_F006_F007;
      s_axis_tuser = TUSER_W'(15);
      s_axis_tlast = 1'b1;
      s_axis_tvalid = 1'b1;
      repeat (4) @(negedge clk);
      if (s_axis_tready !== 1'b0) begin
        $fatal(1, "FAIL tb_mrtc_axis_packet_buffer expected input backpressure when full");
      end
      start_packet_read();
      while (!s_axis_tready) begin
        @(negedge clk);
      end
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tuser = '0;
      s_axis_tdata = '0;

      start_packet_read();
      start_packet_read();
      finish_case("buffer_full_backpressure");
      if (o_write_stall_cycles <= write_stall_start) begin
        $fatal(1, "FAIL tb_mrtc_axis_packet_buffer expected write stall increment");
      end
    end
  endtask

  task automatic run_overlength_packet_fail_stop;
    logic [AXIS_DATA_W-1:0] word_data;
    int beat_idx;
    begin
      ready_mode = 0;
      wait (!o_busy);

      for (beat_idx = 0; beat_idx < MAX_PACKET_BEATS; beat_idx = beat_idx + 1) begin
        @(negedge clk);
        word_data = {
          32'(beat_idx + 32'h7300),
          32'(beat_idx + 32'h7200),
          32'(beat_idx + 32'h7100),
          32'(beat_idx + 32'h7000)
        };
        s_axis_tdata = word_data;
        s_axis_tuser = TUSER_W'(15);
        s_axis_tlast = 1'b0;
        s_axis_tvalid = 1'b1;
        while (!s_axis_tready) begin
          @(negedge clk);
        end
        @(posedge clk);
      end

      @(negedge clk);
      s_axis_tdata = 128'hDEAD_BEEF_DEAD_BEEF_DEAD_BEEF_DEAD_BEEF;
      s_axis_tuser = TUSER_W'(15);
      s_axis_tlast = 1'b1;
      s_axis_tvalid = 1'b1;
      repeat (3) @(posedge clk);
      #1;
      if ((o_overflow !== 1'b1) || (s_axis_tready !== 1'b0)) begin
        $fatal(1,
               "FAIL tb_mrtc_axis_packet_buffer overlength packet did not fail-stop overflow=%0b ready=%0b",
               o_overflow,
               s_axis_tready);
      end

      @(negedge clk);
      i_clear_status = 1'b1;
      @(posedge clk);
      #1;
      if ((o_write_stall_cycles != 0) || (o_overflow !== 1'b1) || (s_axis_tready !== 1'b0)) begin
        $fatal(1,
               "FAIL tb_mrtc_axis_packet_buffer clear semantics stall=%0d overflow=%0b ready=%0b",
               o_write_stall_cycles,
               o_overflow,
               s_axis_tready);
      end

      @(negedge clk);
      i_clear_status = 1'b0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tuser = '0;
      s_axis_tdata = '0;
      rst_n = 1'b0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      rst_n = 1'b1;
      @(posedge clk);
      #1;
      if ((o_overflow !== 1'b0) || (s_axis_tready !== 1'b1)) begin
        $fatal(1,
               "FAIL tb_mrtc_axis_packet_buffer reset did not recover overflow=%0b ready=%0b",
               o_overflow,
               s_axis_tready);
      end
    end
  endtask

  initial begin
    rst_n = 1'b0;
    i_clear_status = 1'b0;
    s_axis_tdata = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    s_axis_tuser = '0;
    i_packet_start = 1'b0;
    ready_mode = 0;
    packet_start_count = 0;
    expected_byte_count = 0;
    case_expected_packets = 0;
    case_actual_start = 0;
    case_done_start = 0;
    case_write_stall_start = 0;
    case_read_stall_start = 0;
    case_packets_written_start = 0;
    case_packets_read_start = 0;
    case_last_valid_count = 0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_single_sparse_packet();
    run_max_raw_packet();
    run_two_packets_back_to_back();
    run_random_output_backpressure();
    run_buffer_full_backpressure();
    run_overlength_packet_fail_stop();

    $display("PASS tb_mrtc_axis_packet_buffer");
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_axis_packet_buffer");
  end
endmodule
