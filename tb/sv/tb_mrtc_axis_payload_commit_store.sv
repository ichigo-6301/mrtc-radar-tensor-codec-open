`timescale 1ns/1ps

module tb_mrtc_axis_payload_commit_store #(
  parameter int PAYLOAD_DEPTH = 512
);
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int TUSER_W = 8;
  localparam int HEADER_BEATS = 4;
  localparam int MAX_PAYLOAD_BEATS = 256;
  localparam int SLOT_COUNT = PAYLOAD_DEPTH / MAX_PAYLOAD_BEATS;
  localparam int OCC_W = $clog2(SLOT_COUNT + 1);
  localparam int MAX_PACKETS = 64;
  localparam int MAX_PACKET_BEATS = HEADER_BEATS + MAX_PAYLOAD_BEATS;
  localparam logic [1:0] SLOT_FREE = 2'd0;
  localparam logic [1:0] SLOT_RESERVED = 2'd1;
  localparam logic [1:0] SLOT_COMMITTED = 2'd2;
  localparam logic [1:0] SLOT_READING = 2'd3;
  localparam logic [1:0] WRITER_IDLE = 2'd0;
  localparam logic [1:0] WRITER_HEADER = 2'd1;
  localparam logic [1:0] WRITER_PAYLOAD = 2'd2;
  localparam logic [1:0] WRITER_SEALED = 2'd3;

  logic clk;
  logic rst_n;
  logic clear_status;
  logic reserve;
  logic reserve_ready;
  logic commit_packet;
  logic abort_packet;
  logic [AXIS_DATA_W-1:0] s_tdata;
  logic s_tvalid;
  logic s_tready;
  logic s_tlast;
  logic [TUSER_W-1:0] s_tuser;
  logic packet_valid;
  logic packet_start;
  logic [AXIS_DATA_W-1:0] m_tdata;
  logic m_tvalid;
  logic m_tready;
  logic m_tlast;
  logic [TUSER_W-1:0] m_tuser;
  logic busy;
  logic full;
  logic overflow;
  logic [31:0] store_error;
  logic [31:0] packets_written;
  logic [31:0] packets_read;
  logic [31:0] write_stalls;
  logic [31:0] read_stalls;
  logic [OCC_W-1:0] max_occupancy;

  logic [AXIS_DATA_W-1:0] expected_data [0:MAX_PACKETS-1][0:MAX_PACKET_BEATS-1];
  logic [TUSER_W-1:0] expected_user [0:MAX_PACKETS-1][0:MAX_PACKET_BEATS-1];
  int expected_beats [0:MAX_PACKETS-1];
  int expected_packet_count;
  int actual_packet_index;
  int actual_beat_index;
  int packet_start_count;
  int packet_done_count;
  int ready_mode;
  int unsigned ready_state;
  logic hold_active;
  logic source_packet_active;
  logic [AXIS_DATA_W-1:0] hold_data;
  logic [TUSER_W-1:0] hold_user;
  logic hold_last;

  function automatic logic [AXIS_DATA_W-1:0] make_word(
    input int packet_id,
    input int beat_id,
    input int kind
  );
    make_word = {
      32'(32'hd000_0000 | (kind << 20) | (packet_id << 8) | beat_id),
      32'(32'hc000_0000 | (kind << 20) | (packet_id << 8) | beat_id),
      32'(32'hb000_0000 | (kind << 20) | (packet_id << 8) | beat_id),
      32'(32'ha000_0000 | (kind << 20) | (packet_id << 8) | beat_id)
    };
  endfunction

  function automatic int unsigned next_rand(input int unsigned state);
    next_rand = (state * 32'd1664525) + 32'd1013904223;
  endfunction

  initial clk = 1'b0;
  always #5 clk = ~clk;

  always @(posedge clk or negedge rst_n) begin
    int unsigned next_state;
    if (!rst_n) begin
      m_tready <= 1'b0;
      ready_state <= 32'h7812_4acd;
    end else begin
      next_state = next_rand(ready_state);
      ready_state <= next_state;
      case (ready_mode)
        1: m_tready <= next_state[5] | next_state[9];
        2: m_tready <= 1'b0;
        default: m_tready <= 1'b1;
      endcase
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      for (int slot = 0; slot < SLOT_COUNT; slot = slot + 1) begin
        case (u_dut.slot_state_reg[slot])
          SLOT_FREE,
          SLOT_RESERVED,
          SLOT_COMMITTED,
          SLOT_READING: begin end
          default: $fatal(1, "slot %0d entered illegal ownership state %0d",
                          slot, u_dut.slot_state_reg[slot]);
        endcase
      end
      if ((u_dut.writer_state_reg != WRITER_IDLE) &&
          (u_dut.slot_state_reg[u_dut.write_slot_reg] != SLOT_RESERVED)) begin
        $fatal(1,
               "writer state %0d depended on non-reserved global slot state %0d",
               u_dut.writer_state_reg,
               u_dut.slot_state_reg[u_dut.write_slot_reg]);
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      actual_packet_index <= 0;
      actual_beat_index <= 0;
      packet_done_count <= 0;
      hold_active <= 1'b0;
      source_packet_active <= 1'b0;
      hold_data <= '0;
      hold_user <= '0;
      hold_last <= 1'b0;
    end else begin
      if (hold_active) begin
        if (!m_tvalid || m_tdata !== hold_data || m_tuser !== hold_user ||
            m_tlast !== hold_last) begin
          $fatal(1, "AXIS output changed under backpressure");
        end
        if (m_tready) begin
          hold_active <= 1'b0;
        end
      end else if (m_tvalid && !m_tready) begin
        hold_active <= 1'b1;
        hold_data <= m_tdata;
        hold_user <= m_tuser;
        hold_last <= m_tlast;
      end

      if (source_packet_active && (ready_mode == 0) && !m_tvalid) begin
        $fatal(1, "source-generated bubble inside committed packet");
      end

      if (m_tvalid && !source_packet_active) begin
        source_packet_active <= 1'b1;
      end

      if (m_tvalid && m_tready) begin
        if (actual_packet_index >= expected_packet_count) begin
          $fatal(1, "unexpected output packet=%0d beat=%0d",
                 actual_packet_index, actual_beat_index);
        end
        if (m_tdata !== expected_data[actual_packet_index][actual_beat_index] ||
            m_tuser !== expected_user[actual_packet_index][actual_beat_index]) begin
          $fatal(1,
                 "output mismatch packet=%0d beat=%0d exp_data=%032h got_data=%032h exp_user=%02h got_user=%02h",
                 actual_packet_index, actual_beat_index,
                 expected_data[actual_packet_index][actual_beat_index], m_tdata,
                 expected_user[actual_packet_index][actual_beat_index], m_tuser);
        end
        if (m_tlast !==
            (actual_beat_index == (expected_beats[actual_packet_index] - 1))) begin
          $fatal(1, "output tlast mismatch packet=%0d beat=%0d tlast=%0d",
                 actual_packet_index, actual_beat_index, m_tlast);
        end
        if (m_tlast) begin
          source_packet_active <= 1'b0;
          actual_packet_index <= actual_packet_index + 1;
          actual_beat_index <= 0;
          packet_done_count <= packet_done_count + 1;
        end else begin
          actual_beat_index <= actual_beat_index + 1;
        end
      end
    end
  end

  task automatic clear_inputs;
    begin
      reserve = 1'b0;
      commit_packet = 1'b0;
      abort_packet = 1'b0;
      packet_start = 1'b0;
      s_tdata = '0;
      s_tvalid = 1'b0;
      s_tlast = 1'b0;
      s_tuser = '0;
    end
  endtask

  task automatic pulse_commit;
    begin
      @(negedge clk);
      commit_packet = 1'b1;
      @(negedge clk);
      commit_packet = 1'b0;
    end
  endtask

  task automatic apply_reset;
    begin
      rst_n = 1'b0;
      clear_status = 1'b0;
      ready_mode = 0;
      clear_inputs();
      repeat (5) @(posedge clk);
      rst_n = 1'b1;
      repeat (3) @(posedge clk);
      if (!reserve_ready || busy || packet_valid || store_error != MRTC_ERR_NONE) begin
        $fatal(1, "reset state invalid depth=%0d ready=%0d busy=%0d valid=%0d error=%0d",
               PAYLOAD_DEPTH, reserve_ready, busy, packet_valid, store_error);
      end
    end
  endtask

  task automatic pulse_reserve;
    begin
      wait (reserve_ready);
      @(negedge clk);
      reserve = 1'b1;
      @(negedge clk);
      reserve = 1'b0;
      wait (s_tready);
    end
  endtask

  task automatic run_registered_reserve;
    logic ready_before_reserve;
    begin
      wait (reserve_ready);
      @(negedge clk);
      ready_before_reserve = reserve_ready;
      reserve = 1'b1;
      #1;
      if ((reserve_ready !== ready_before_reserve) || s_tready) begin
        $fatal(1,
               "reserve changed writer controls combinationally reserve_ready=%0d s_ready=%0d",
               reserve_ready, s_tready);
      end
      @(posedge clk);
      #1;
      if (!u_dut.reserve_pending_reg ||
          (u_dut.writer_state_reg != WRITER_IDLE) || s_tready || reserve_ready) begin
        $fatal(1,
               "reserve request was not isolated for one cycle pending=%0d writer=%0d s_ready=%0d reserve_ready=%0d",
               u_dut.reserve_pending_reg, u_dut.writer_state_reg, s_tready,
               reserve_ready);
      end
      @(negedge clk);
      reserve = 1'b0;
      @(posedge clk);
      #1;
      if (u_dut.reserve_pending_reg ||
          (u_dut.writer_state_reg != WRITER_HEADER) || !s_tready ||
          !u_dut.reservation_active_reg) begin
        $fatal(1,
               "registered reserve did not start writer pending=%0d writer=%0d s_ready=%0d active=%0d",
               u_dut.reserve_pending_reg, u_dut.writer_state_reg, s_tready,
               u_dut.reservation_active_reg);
      end
      pulse_abort();
    end
  endtask

  task automatic drive_beat(
    input logic [AXIS_DATA_W-1:0] data,
    input logic [TUSER_W-1:0] user,
    input logic last
  );
    begin
      @(negedge clk);
      s_tdata = data;
      s_tuser = user;
      s_tlast = last;
      s_tvalid = 1'b1;
      while (!s_tready) begin
        @(negedge clk);
      end
      @(negedge clk);
      s_tvalid = 1'b0;
      s_tlast = 1'b0;
      s_tuser = '0;
      s_tdata = '0;
    end
  endtask

  task automatic send_committed_packet(
    input int packet_id,
    input int payload_beats,
    input int final_valid_bytes
  );
    int packet_index;
    begin
      packet_index = expected_packet_count;
      pulse_reserve();
      for (int beat = 0; beat < HEADER_BEATS; beat = beat + 1) begin
        expected_data[packet_index][beat] = make_word(packet_id, beat, 0);
        expected_user[packet_index][beat] = 8'h0f;
        drive_beat(expected_data[packet_index][beat], 8'h0f, 1'b0);
      end
      for (int beat = 0; beat < payload_beats; beat = beat + 1) begin
        expected_data[packet_index][HEADER_BEATS + beat] =
          make_word(packet_id, beat, 1);
        expected_user[packet_index][HEADER_BEATS + beat] =
          (beat == (payload_beats - 1)) ? 8'(final_valid_bytes - 1) : 8'h0f;
        drive_beat(
          expected_data[packet_index][HEADER_BEATS + beat],
          expected_user[packet_index][HEADER_BEATS + beat],
          (beat == (payload_beats - 1))
        );
      end
      expected_beats[packet_index] = HEADER_BEATS + payload_beats;
      pulse_commit();
      expected_packet_count = expected_packet_count + 1;
      repeat (2) @(posedge clk);
      if (store_error != MRTC_ERR_NONE) begin
        $fatal(1, "commit failed packet=%0d payload=%0d error=%0d",
               packet_id, payload_beats, store_error);
      end
    end
  endtask

  task automatic send_same_cycle_commit_packet(
    input int packet_id,
    input int payload_beats,
    input int final_valid_bytes
  );
    int packet_index;
    int final_beat;
    begin
      packet_index = expected_packet_count;
      final_beat = payload_beats - 1;
      pulse_reserve();
      for (int beat = 0; beat < HEADER_BEATS; beat = beat + 1) begin
        expected_data[packet_index][beat] = make_word(packet_id, beat, 0);
        expected_user[packet_index][beat] = 8'h0f;
        drive_beat(expected_data[packet_index][beat], 8'h0f, 1'b0);
      end
      for (int beat = 0; beat < final_beat; beat = beat + 1) begin
        expected_data[packet_index][HEADER_BEATS + beat] =
          make_word(packet_id, beat, 1);
        expected_user[packet_index][HEADER_BEATS + beat] = 8'h0f;
        drive_beat(
          expected_data[packet_index][HEADER_BEATS + beat],
          8'h0f,
          1'b0
        );
      end

      expected_data[packet_index][HEADER_BEATS + final_beat] =
        make_word(packet_id, final_beat, 1);
      expected_user[packet_index][HEADER_BEATS + final_beat] =
        8'(final_valid_bytes - 1);
      @(negedge clk);
      if (!s_tready) begin
        $fatal(1, "same-cycle final beat was not ready");
      end
      s_tdata = expected_data[packet_index][HEADER_BEATS + final_beat];
      s_tuser = expected_user[packet_index][HEADER_BEATS + final_beat];
      s_tlast = 1'b1;
      s_tvalid = 1'b1;
      commit_packet = 1'b1;
      @(negedge clk);
      s_tvalid = 1'b0;
      s_tlast = 1'b0;
      s_tuser = '0;
      s_tdata = '0;
      commit_packet = 1'b0;

      expected_beats[packet_index] = HEADER_BEATS + payload_beats;
      expected_packet_count = expected_packet_count + 1;
      repeat (2) @(posedge clk);
      if (!packet_valid || store_error != MRTC_ERR_NONE) begin
        $fatal(1, "same-cycle final/commit failed valid=%0d error=%0d",
               packet_valid, store_error);
      end
    end
  endtask

  task automatic send_commit_guard_packet(
    input int packet_id,
    input int payload_beats,
    input int final_valid_bytes
  );
    int packet_index;
    begin
      packet_index = expected_packet_count;
      pulse_reserve();
      for (int beat = 0; beat < HEADER_BEATS; beat = beat + 1) begin
        expected_data[packet_index][beat] = make_word(packet_id, beat, 0);
        expected_user[packet_index][beat] = 8'h0f;
        drive_beat(expected_data[packet_index][beat], 8'h0f, 1'b0);
      end
      for (int beat = 0; beat < payload_beats; beat = beat + 1) begin
        expected_data[packet_index][HEADER_BEATS + beat] =
          make_word(packet_id, beat, 1);
        expected_user[packet_index][HEADER_BEATS + beat] =
          (beat == (payload_beats - 1)) ? 8'(final_valid_bytes - 1) : 8'h0f;
        drive_beat(
          expected_data[packet_index][HEADER_BEATS + beat],
          expected_user[packet_index][HEADER_BEATS + beat],
          (beat == (payload_beats - 1))
        );
      end
      expected_beats[packet_index] = HEADER_BEATS + payload_beats;
      expected_packet_count = expected_packet_count + 1;

      if (packet_valid || (u_dut.writer_state_reg != WRITER_SEALED)) begin
        $fatal(1, "sealed packet became visible before commit request");
      end
      @(negedge clk);
      commit_packet = 1'b1;
      @(posedge clk);
      #1;
      if (packet_valid || !u_dut.commit_pending_reg ||
          (u_dut.writer_state_reg != WRITER_SEALED)) begin
        $fatal(1,
               "commit request bypassed pending guard valid=%0d pending=%0d writer=%0d",
               packet_valid, u_dut.commit_pending_reg, u_dut.writer_state_reg);
      end
      @(negedge clk);
      commit_packet = 1'b0;
      @(posedge clk);
      #1;
      if (!packet_valid || u_dut.commit_pending_reg ||
          (u_dut.writer_state_reg != WRITER_IDLE)) begin
        $fatal(1,
               "guarded commit did not publish on following cycle valid=%0d pending=%0d writer=%0d",
               packet_valid, u_dut.commit_pending_reg, u_dut.writer_state_reg);
      end
    end
  endtask

  task automatic run_clear_status_state_preservation;
    int packet_index;
    int slot_index;
    begin
      packet_index = expected_packet_count;
      pulse_reserve();
      slot_index = int'(u_dut.write_slot_reg);
      for (int beat = 0; beat < 2; beat = beat + 1) begin
        expected_data[packet_index][beat] = make_word(43, beat, 0);
        expected_user[packet_index][beat] = 8'h0f;
        drive_beat(expected_data[packet_index][beat], 8'h0f, 1'b0);
      end

      @(negedge clk);
      clear_status = 1'b1;
      @(negedge clk);
      clear_status = 1'b0;
      #1;
      if ((u_dut.writer_state_reg != WRITER_HEADER) ||
          (u_dut.header_count_reg != 2) ||
          (u_dut.slot_state_reg[slot_index] != SLOT_RESERVED) ||
          (u_dut.occupancy_reg != 1) || packets_written != 0 ||
          packets_read != 0) begin
        $fatal(1,
               "clear_status changed speculative state writer=%0d header=%0d slot=%0d occupancy=%0d",
               u_dut.writer_state_reg, u_dut.header_count_reg,
               u_dut.slot_state_reg[slot_index], u_dut.occupancy_reg);
      end

      for (int beat = 2; beat < HEADER_BEATS; beat = beat + 1) begin
        expected_data[packet_index][beat] = make_word(43, beat, 0);
        expected_user[packet_index][beat] = 8'h0f;
        drive_beat(expected_data[packet_index][beat], 8'h0f, 1'b0);
      end
      for (int beat = 0; beat < 2; beat = beat + 1) begin
        expected_data[packet_index][HEADER_BEATS + beat] = make_word(43, beat, 1);
        expected_user[packet_index][HEADER_BEATS + beat] =
          (beat == 1) ? 8'h07 : 8'h0f;
        drive_beat(expected_data[packet_index][HEADER_BEATS + beat],
                   expected_user[packet_index][HEADER_BEATS + beat], beat == 1);
      end
      expected_beats[packet_index] = HEADER_BEATS + 2;
      expected_packet_count = expected_packet_count + 1;
      pulse_commit();
      repeat (2) @(posedge clk);
      if (!packet_valid ||
          (u_dut.slot_state_reg[slot_index] != SLOT_COMMITTED)) begin
        $fatal(1, "packet was not committed before status clear");
      end

      @(negedge clk);
      clear_status = 1'b1;
      @(negedge clk);
      clear_status = 1'b0;
      #1;
      if (!packet_valid ||
          (u_dut.slot_state_reg[slot_index] != SLOT_COMMITTED) ||
          (u_dut.committed_count_reg != 1) || packets_written != 0) begin
        $fatal(1,
               "clear_status changed committed state valid=%0d slot=%0d committed=%0d",
               packet_valid, u_dut.slot_state_reg[slot_index],
               u_dut.committed_count_reg);
      end
      start_and_wait_packet(1'b0);
    end
  endtask

  task automatic start_and_wait_packet(input bit random_backpressure);
    int done_before;
    begin
      done_before = packet_done_count;
      wait (packet_valid);
      ready_mode = random_backpressure ? 1 : 0;
      @(negedge clk);
      packet_start = 1'b1;
      @(negedge clk);
      packet_start = 1'b0;
      packet_start_count = packet_start_count + 1;
      wait (packet_done_count == (done_before + 1));
      repeat (2) @(posedge clk);
      ready_mode = 0;
    end
  endtask

  task automatic start_after_prefetch_stall;
    int done_before;
    begin
      done_before = packet_done_count;
      wait (packet_valid);
      ready_mode = 2;
      @(negedge clk);
      packet_start = 1'b1;
      @(negedge clk);
      packet_start = 1'b0;
      packet_start_count = packet_start_count + 1;
      repeat (12) @(posedge clk);
      if (u_dut.payload_fifo_count_reg != 3) begin
        $fatal(1, "payload prefetch FIFO did not fill under header stall count=%0d",
               u_dut.payload_fifo_count_reg);
      end
      ready_mode = 0;
      wait (packet_done_count == (done_before + 1));
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic pulse_abort;
    begin
      @(negedge clk);
      abort_packet = 1'b1;
      @(negedge clk);
      abort_packet = 1'b0;
      repeat (2) @(posedge clk);
      if (packet_valid || busy || !reserve_ready) begin
        $fatal(1, "abort did not release speculative slot");
      end
    end
  endtask

  task automatic drive_header_prefix(input int count, input int packet_id);
    begin
      for (int beat = 0; beat < count; beat = beat + 1) begin
        drive_beat(make_word(packet_id, beat, 0), 8'h0f, 1'b0);
      end
    end
  endtask

  task automatic run_abort_matrix;
    int written_before;
    logic ready_before_abort;
    begin
      written_before = packets_written;
      pulse_reserve();
      pulse_abort();

      pulse_reserve();
      drive_header_prefix(2, 20);
      pulse_abort();

      pulse_reserve();
      drive_header_prefix(HEADER_BEATS, 21);
      drive_beat(make_word(21, 0, 1), 8'h0f, 1'b0);
      drive_beat(make_word(21, 1, 1), 8'h0f, 1'b0);
      pulse_abort();

      pulse_reserve();
      drive_header_prefix(HEADER_BEATS, 22);
      @(negedge clk);
      s_tdata = make_word(22, 0, 1);
      s_tuser = 8'hf3;
      s_tlast = 1'b1;
      s_tvalid = 1'b1;
      ready_before_abort = s_tready;
      abort_packet = 1'b1;
      commit_packet = 1'b1;
      #1;
      if (s_tready !== ready_before_abort) begin
        $fatal(1, "abort changed write ready combinationally");
      end
      @(negedge clk);
      s_tvalid = 1'b0;
      s_tlast = 1'b0;
      abort_packet = 1'b0;
      commit_packet = 1'b0;
      repeat (2) @(posedge clk);
      if (packet_valid || busy || packets_written != written_before ||
          store_error != MRTC_ERR_NONE) begin
        $fatal(1, "abort did not win over final payload beat");
      end

      pulse_reserve();
      drive_header_prefix(HEADER_BEATS, 23);
      drive_beat(make_word(23, 0, 1), 8'h03, 1'b1);
      @(negedge clk);
      abort_packet = 1'b1;
      commit_packet = 1'b1;
      @(negedge clk);
      abort_packet = 1'b0;
      commit_packet = 1'b0;
      repeat (2) @(posedge clk);
      if (packet_valid || busy || packets_written != written_before ||
          store_error != MRTC_ERR_NONE) begin
        $fatal(1, "abort did not win over sealed-slot commit");
      end
    end
  endtask

  task automatic run_abort_ready_independence;
    logic reserve_ready_before;
    begin
      @(negedge clk);
      reserve_ready_before = reserve_ready;
      abort_packet = 1'b1;
      #1;
      if (reserve_ready !== reserve_ready_before) begin
        $fatal(1, "abort changed reserve ready combinationally");
      end
      @(negedge clk);
      abort_packet = 1'b0;
      repeat (2) @(posedge clk);
      if (!reserve_ready || busy || store_error != MRTC_ERR_NONE) begin
        $fatal(1, "idle abort changed store state");
      end
    end
  endtask

  task automatic run_registered_abort;
    logic ready_before_abort;
    begin
      pulse_reserve();
      if ((u_dut.writer_state_reg != WRITER_HEADER) ||
          !u_dut.reservation_active_reg) begin
        $fatal(1, "reservation did not enter writer header state");
      end
      @(negedge clk);
      ready_before_abort = s_tready;
      abort_packet = 1'b1;
      #1;
      if (s_tready !== ready_before_abort) begin
        $fatal(1, "abort changed AXIS ready before registration");
      end
      @(posedge clk);
      #1;
      if (!u_dut.abort_pending_reg ||
          (u_dut.writer_state_reg != WRITER_HEADER) || !s_tready) begin
        $fatal(1,
               "abort was not registered before writer rollback pending=%0d writer=%0d ready=%0d",
               u_dut.abort_pending_reg, u_dut.writer_state_reg, s_tready);
      end
      @(negedge clk);
      abort_packet = 1'b0;
      @(posedge clk);
      #1;
      if ((u_dut.writer_state_reg != WRITER_IDLE) || busy || packet_valid ||
          (store_error != MRTC_ERR_NONE)) begin
        $fatal(1,
               "registered abort did not roll back speculative writer writer=%0d busy=%0d error=%0d",
               u_dut.writer_state_reg, busy, store_error);
      end
    end
  endtask

  task automatic run_write_error_blocks_commit;
    int written_before;
    begin
      written_before = packets_written;
      pulse_reserve();
      drive_header_prefix(HEADER_BEATS, 44);
      drive_beat(make_word(44, 0, 1), 8'h03, 1'b1);
      @(negedge clk);
      s_tdata = make_word(44, 99, 1);
      s_tuser = 8'h0f;
      s_tvalid = 1'b1;
      commit_packet = 1'b1;
      @(negedge clk);
      s_tdata = '0;
      s_tuser = '0;
      s_tvalid = 1'b0;
      commit_packet = 1'b0;
      repeat (2) @(posedge clk);
      if ((store_error != MRTC_ERR_INTERNAL_STATE) || packet_valid || busy ||
          (packets_written != written_before) ||
          (u_dut.writer_state_reg != WRITER_IDLE)) begin
        $fatal(1,
               "write error did not outrank commit error=%0d valid=%0d busy=%0d written=%0d/%0d writer=%0d",
               store_error, packet_valid, busy, packets_written, written_before,
               u_dut.writer_state_reg);
      end
    end
  endtask

  task automatic run_sticky_error_blocks_commit;
    int written_before;
    begin
      written_before = packets_written;
      pulse_reserve();
      drive_header_prefix(HEADER_BEATS, 34);
      drive_beat(make_word(34, 0, 1), 8'h03, 1'b1);
      @(negedge clk);
      packet_start = 1'b1;
      commit_packet = 1'b1;
      @(negedge clk);
      packet_start = 1'b0;
      commit_packet = 1'b0;
      repeat (3) @(posedge clk);
      if (store_error != MRTC_ERR_INTERNAL_STATE ||
          packets_written != written_before || packet_valid) begin
        $fatal(1,
               "store error did not block same-cycle commit error=%0d written=%0d/%0d valid=%0d",
               store_error, packets_written, written_before, packet_valid);
      end
      pulse_commit();
      repeat (2) @(posedge clk);
      if (packets_written != written_before || packet_valid) begin
        $fatal(1, "sticky store error allowed a later commit");
      end
    end
  endtask

  task automatic run_internal_error_preserves_committed_read;
    int done_before;
    int packets_read_before;
    begin
      apply_reset();
      expected_packet_count = 0;
      actual_packet_index = 0;
      actual_beat_index = 0;
      packet_start_count = 0;
      packet_done_count = 0;

      send_committed_packet(36, 4, 8);
      done_before = packet_done_count;
      packets_read_before = packets_read;
      wait (packet_valid);
      ready_mode = 0;
      @(negedge clk);
      packet_start = 1'b1;
      @(negedge clk);
      packet_start = 1'b0;
      packet_start_count = packet_start_count + 1;
      wait (m_tvalid && m_tready);
      @(negedge clk);
      s_tdata = make_word(36, 99, 0);
      s_tuser = 8'h0f;
      s_tvalid = 1'b1;
      #1;
      if (!m_tvalid || (m_tvalid !== u_dut.output_valid_raw)) begin
        $fatal(1, "internal error combinationally changed committed output valid");
      end
      @(posedge clk);
      #1;
      if ((store_error != MRTC_ERR_INTERNAL_STATE) || !m_tvalid) begin
        $fatal(1,
               "internal error disturbed ready committed read error=%0d valid=%0d",
               store_error, m_tvalid);
      end
      @(negedge clk);
      s_tvalid = 1'b0;
      s_tdata = '0;
      s_tuser = '0;
      wait (packet_done_count == (done_before + 1));
      repeat (2) @(posedge clk);
      if ((packets_read != (packets_read_before + 1)) || busy || packet_valid) begin
        $fatal(1,
               "internal error prevented committed drain read=%0d/%0d busy=%0d valid=%0d",
               packets_read, packets_read_before + 1, busy, packet_valid);
      end
      expect_sticky_error(MRTC_ERR_INTERNAL_STATE,
                          "error_during_committed_read");
    end
  endtask

  task automatic run_internal_error_holds_stalled_committed_beat;
    int done_before;
    logic [AXIS_DATA_W-1:0] stalled_data;
    logic [TUSER_W-1:0] stalled_user;
    logic stalled_last;
    begin
      apply_reset();
      expected_packet_count = 0;
      actual_packet_index = 0;
      actual_beat_index = 0;
      packet_start_count = 0;
      packet_done_count = 0;

      send_committed_packet(39, 4, 8);
      done_before = packet_done_count;
      wait (packet_valid);
      ready_mode = 2;
      @(negedge clk);
      packet_start = 1'b1;
      @(negedge clk);
      packet_start = 1'b0;
      packet_start_count = packet_start_count + 1;
      wait (m_tvalid && !m_tready);
      stalled_data = m_tdata;
      stalled_user = m_tuser;
      stalled_last = m_tlast;

      @(negedge clk);
      s_tdata = make_word(39, 99, 0);
      s_tuser = 8'h0f;
      s_tvalid = 1'b1;
      @(posedge clk);
      #1;
      if ((store_error != MRTC_ERR_INTERNAL_STATE) || !m_tvalid ||
          (m_tdata !== stalled_data) || (m_tuser !== stalled_user) ||
          (m_tlast !== stalled_last)) begin
        $fatal(1,
               "internal error changed stalled committed beat error=%0d valid=%0d",
               store_error, m_tvalid);
      end
      repeat (2) begin
        @(posedge clk);
        #1;
        if (!m_tvalid || (m_tdata !== stalled_data) ||
            (m_tuser !== stalled_user) || (m_tlast !== stalled_last)) begin
          $fatal(1, "sticky error changed stalled committed beat");
        end
      end

      @(negedge clk);
      s_tvalid = 1'b0;
      s_tdata = '0;
      s_tuser = '0;
      ready_mode = 0;
      wait (packet_done_count == (done_before + 1));
      repeat (2) @(posedge clk);
      if (busy || packet_valid) begin
        $fatal(1,
               "stalled committed packet did not drain busy=%0d valid=%0d",
               busy, packet_valid);
      end
      expect_sticky_error(MRTC_ERR_INTERNAL_STATE,
                          "error_during_stalled_committed_read");
    end
  endtask

  task automatic run_abort_preserves_committed_read;
    int done_before;
    begin
      apply_reset();
      expected_packet_count = 0;
      actual_packet_index = 0;
      actual_beat_index = 0;
      packet_start_count = 0;
      packet_done_count = 0;

      send_committed_packet(37, 32, 11);
      done_before = packet_done_count;
      wait (packet_valid);
      ready_mode = 0;
      @(negedge clk);
      packet_start = 1'b1;
      @(negedge clk);
      packet_start = 1'b0;
      packet_start_count = packet_start_count + 1;

      wait (u_dut.read_active_reg);
      pulse_reserve();
      drive_header_prefix(2, 38);
      @(negedge clk);
      abort_packet = 1'b1;
      @(negedge clk);
      abort_packet = 1'b0;

      wait (packet_done_count == (done_before + 1));
      repeat (2) @(posedge clk);
      if (store_error != MRTC_ERR_NONE || busy || packets_written != 1 ||
          packets_read != 1) begin
        $fatal(1,
               "speculative abort disturbed committed read error=%0d busy=%0d written=%0d read=%0d",
               store_error, busy, packets_written, packets_read);
      end
    end
  endtask

  task automatic expect_sticky_error(input logic [31:0] expected, input string label);
    begin
      repeat (3) @(posedge clk);
      if (store_error != expected || !overflow || reserve_ready || packet_valid) begin
        $fatal(1, "%s expected sticky error=%0d got=%0d overflow=%0d ready=%0d valid=%0d",
               label, expected, store_error, overflow, reserve_ready, packet_valid);
      end
      @(negedge clk);
      clear_status = 1'b1;
      @(negedge clk);
      clear_status = 1'b0;
      repeat (2) @(posedge clk);
      if (store_error != expected) begin
        $fatal(1, "%s clear_status incorrectly cleared sticky error", label);
      end
    end
  endtask

  task automatic run_internal_error_cases;
    begin
      @(negedge clk);
      s_tvalid = 1'b1;
      s_tdata = make_word(30, 0, 0);
      s_tuser = 8'h0f;
      @(negedge clk);
      s_tvalid = 1'b0;
      expect_sticky_error(MRTC_ERR_INTERNAL_STATE, "write_without_reservation");

      apply_reset();
      @(negedge clk);
      reserve = 1'b1;
      s_tvalid = 1'b1;
      s_tdata = make_word(35, 0, 0);
      s_tuser = 8'h0f;
      @(negedge clk);
      reserve = 1'b0;
      s_tvalid = 1'b0;
      expect_sticky_error(MRTC_ERR_INTERNAL_STATE, "reserve_with_illegal_write");
      if (busy || u_dut.reservation_active_reg ||
          (u_dut.occupancy_reg != 0)) begin
        $fatal(1,
               "internal error advanced reservation state busy=%0d active=%0d occupancy=%0d",
               busy, u_dut.reservation_active_reg, u_dut.occupancy_reg);
      end

      apply_reset();
      pulse_reserve();
      drive_beat(make_word(31, 0, 0), 8'h00, 1'b1);
      expect_sticky_error(MRTC_ERR_INTERNAL_STATE, "header_tlast");

      apply_reset();
      pulse_reserve();
      drive_header_prefix(HEADER_BEATS, 32);
      for (int beat = 0; beat < MAX_PAYLOAD_BEATS; beat = beat + 1) begin
        drive_beat(make_word(32, beat, 1), 8'h0f, 1'b0);
        if (store_error != MRTC_ERR_NONE) begin
          break;
        end
      end
      expect_sticky_error(MRTC_ERR_PAYLOAD_TOO_LONG, "payload_257_required");
    end
  endtask

  initial begin
    expected_packet_count = 0;
    actual_packet_index = 0;
    actual_beat_index = 0;
    packet_start_count = 0;
    packet_done_count = 0;
    apply_reset();
    run_registered_reserve();

    for (int valid_bytes = 1; valid_bytes <= 16; valid_bytes = valid_bytes + 1) begin
      send_committed_packet(valid_bytes, 1, valid_bytes);
      start_and_wait_packet(valid_bytes[0]);
    end

    send_committed_packet(40, 255, 16);
    start_and_wait_packet(1'b1);
    send_committed_packet(41, 256, 7);
    start_and_wait_packet(1'b0);
    send_same_cycle_commit_packet(42, 3, 6);
    start_after_prefetch_stall();
    send_commit_guard_packet(43, 3, 10);
    start_and_wait_packet(1'b0);
    run_clear_status_state_preservation();

    if (SLOT_COUNT == 2) begin
      ready_mode = 2;
      send_committed_packet(50, 256, 16);
      send_committed_packet(51, 256, 5);
      if (!full || max_occupancy != OCC_W'(2)) begin
        $fatal(1, "two-slot occupancy mismatch full=%0d max=%0d", full, max_occupancy);
      end
      start_and_wait_packet(1'b0);
      start_and_wait_packet(1'b1);

      send_committed_packet(52, 200, 16);
      fork
        start_and_wait_packet(1'b0);
        begin
          repeat (8) @(posedge clk);
          send_committed_packet(53, 200, 9);
        end
      join
      start_and_wait_packet(1'b0);
    end

    run_abort_ready_independence();
    run_registered_abort();
    run_abort_matrix();

    send_committed_packet(60, 3, 4);
    @(negedge clk);
    abort_packet = 1'b1;
    @(negedge clk);
    abort_packet = 1'b0;
    repeat (2) @(posedge clk);
    if (!packet_valid) begin
      $fatal(1, "abort after commit removed a committed packet");
    end
    start_and_wait_packet(1'b0);

    apply_reset();
    expected_packet_count = 0;
    actual_packet_index = 0;
    actual_beat_index = 0;
    packet_start_count = 0;
    packet_done_count = 0;
    run_internal_error_cases();

    apply_reset();
    run_write_error_blocks_commit();

    apply_reset();
    run_sticky_error_blocks_commit();

    if (SLOT_COUNT == 2) begin
      run_abort_preserves_committed_read();
    end

    run_internal_error_preserves_committed_read();
    run_internal_error_holds_stalled_committed_beat();

    $display(
      "PASS tb_mrtc_axis_payload_commit_store depth=%0d slots=%0d packets_written=%0d packets_read=%0d",
      PAYLOAD_DEPTH, SLOT_COUNT, packets_written, packets_read);
    $finish;
  end

  initial begin
    repeat (500000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_axis_payload_commit_store depth=%0d", PAYLOAD_DEPTH);
  end

  mrtc_axis_payload_commit_store #(
    .AXIS_DATA_W      (AXIS_DATA_W),
    .TUSER_W          (TUSER_W),
    .HEADER_BEATS     (HEADER_BEATS),
    .MAX_PAYLOAD_BEATS(MAX_PAYLOAD_BEATS),
    .PAYLOAD_DEPTH    (PAYLOAD_DEPTH)
  ) u_dut (
    .clk,
    .rst_n,
    .i_clear_status       (clear_status),
    .i_reserve            (reserve),
    .o_reserve_ready      (reserve_ready),
    .i_commit             (commit_packet),
    .i_abort              (abort_packet),
    .s_axis_tdata         (s_tdata),
    .s_axis_tvalid        (s_tvalid),
    .s_axis_tready        (s_tready),
    .s_axis_tlast         (s_tlast),
    .s_axis_tuser         (s_tuser),
    .o_packet_valid       (packet_valid),
    .i_packet_start       (packet_start),
    .m_axis_tdata         (m_tdata),
    .m_axis_tvalid        (m_tvalid),
    .m_axis_tready        (m_tready),
    .m_axis_tlast         (m_tlast),
    .m_axis_tuser         (m_tuser),
    .o_busy               (busy),
    .o_full               (full),
    .o_overflow           (overflow),
    .o_error              (store_error),
    .o_packets_written    (packets_written),
    .o_packets_read       (packets_read),
    .o_write_stall_cycles (write_stalls),
    .o_read_stall_cycles  (read_stalls),
    .o_max_occupancy      (max_occupancy)
  );
endmodule
