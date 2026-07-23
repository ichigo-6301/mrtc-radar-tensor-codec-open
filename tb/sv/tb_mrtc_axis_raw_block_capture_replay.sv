`timescale 1ns/1ps

module tb_mrtc_axis_raw_block_capture_replay #(
  parameter int CAPTURE_SLOTS_PER_ENGINE = 2
);
  localparam int AXIS_DATA_W = 32;
  localparam int TUSER_W = 8;
  localparam int BLOCK_BEATS = 4;

  logic clk;
  logic rst_n;
  logic clear_status;
  logic clear_status_manual;
  logic clear_on_replay_last;
  logic replay_start_ready;
  logic [AXIS_DATA_W-1:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [TUSER_W-1:0] s_axis_tuser;
  logic [AXIS_DATA_W-1:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic [TUSER_W-1:0] m_axis_tuser;
  logic [31:0] stat_capture_accepted_blocks;
  logic [31:0] stat_replay_started_blocks;
  logic [31:0] stat_replay_completed_blocks;
  logic [31:0] stat_slot_full_cycles;
  logic [31:0] stat_active_input_bubble_cycles;
  logic [31:0] stat_metadata_mismatch_count;
  logic [31:0] stat_error_flags;
  logic [3:0] stat_current_occupancy_slots;
  logic [3:0] stat_max_occupancy_slots;
  logic [1:0] stat_slot0_state;
  logic [1:0] stat_slot1_state;

  integer observed_block_index;
  integer observed_beat_index;
  integer observed_blocks;
  integer capture_clear_checks;
  integer replay_clear_checks;

  assign clear_status = clear_status_manual |
                        (clear_on_replay_last && m_axis_tvalid &&
                         m_axis_tready && m_axis_tlast);

  function automatic logic [AXIS_DATA_W-1:0] block_word(
    input integer block_id,
    input integer beat_id
  );
    block_word = 32'hA5000000 | ((block_id & 8'hff) << 8) | (beat_id & 8'hff);
  endfunction

  function automatic logic [TUSER_W-1:0] block_tuser(input integer block_id);
    block_tuser = {4'd0, block_id[2:0], 1'b0};
  endfunction

  mrtc_axis_raw_block_capture_replay #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W(TUSER_W),
    .BLOCK_BEATS(BLOCK_BEATS),
    .BLOCK_WORDS(BLOCK_BEATS),
    .CAPTURE_SLOTS_PER_ENGINE(CAPTURE_SLOTS_PER_ENGINE)
  ) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .i_clear_status(clear_status),
    .i_replay_start_ready(replay_start_ready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tuser(m_axis_tuser),
    .stat_capture_accepted_blocks(stat_capture_accepted_blocks),
    .stat_replay_started_blocks(stat_replay_started_blocks),
    .stat_replay_completed_blocks(stat_replay_completed_blocks),
    .stat_slot_full_cycles(stat_slot_full_cycles),
    .stat_active_input_bubble_cycles(stat_active_input_bubble_cycles),
    .stat_metadata_mismatch_count(stat_metadata_mismatch_count),
    .stat_error_flags(stat_error_flags),
    .stat_current_occupancy_slots(stat_current_occupancy_slots),
    .stat_max_occupancy_slots(stat_max_occupancy_slots),
    .stat_slot0_state(stat_slot0_state),
    .stat_slot1_state(stat_slot1_state)
  );

  always #5 clk = ~clk;

  task automatic send_block(
    input integer block_id,
    input integer clear_beat,
    input integer replay_enable_beat
  );
    integer beat_id;
    begin
      for (beat_id = 0; beat_id < BLOCK_BEATS; beat_id = beat_id + 1) begin
        @(negedge clk);
        s_axis_tdata = block_word(block_id, beat_id);
        s_axis_tuser = block_tuser(block_id);
        s_axis_tlast = (beat_id == (BLOCK_BEATS - 1));
        s_axis_tvalid = 1'b1;
        clear_status_manual = (beat_id == clear_beat);
        if (beat_id == replay_enable_beat) begin
          replay_start_ready = 1'b1;
        end
        while (!s_axis_tready) begin
          @(negedge clk);
        end
        @(posedge clk);
      end
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      clear_status_manual = 1'b0;
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && clear_status_manual && s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
      #1;
      if ((stat_capture_accepted_blocks != 0) || (stat_replay_started_blocks != 0)) begin
        $fatal(1,
               "capture clear lost priority capture=%0d replay_started=%0d",
               stat_capture_accepted_blocks,
               stat_replay_started_blocks);
      end
      capture_clear_checks = capture_clear_checks + 1;
    end
    if (rst_n && clear_on_replay_last && m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
      #1;
      if (stat_replay_completed_blocks != 0) begin
        $fatal(1,
               "replay clear lost priority replay_completed=%0d",
               stat_replay_completed_blocks);
      end
      replay_clear_checks = replay_clear_checks + 1;
      clear_on_replay_last = 1'b0;
    end
  end

  always @(posedge clk) begin
    integer expected_block_id;
    if (!rst_n) begin
      observed_block_index = 0;
      observed_beat_index = 0;
      observed_blocks = 0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      case (observed_block_index)
        0: expected_block_id = 0;
        1: expected_block_id = 1;
        2: expected_block_id = 2;
        default: expected_block_id = -1;
      endcase
      if (expected_block_id < 0) begin
        $fatal(1, "unexpected replay block index=%0d", observed_block_index);
      end
      if (m_axis_tdata !== block_word(expected_block_id, observed_beat_index)) begin
        $fatal(1,
               "replay data mismatch block=%0d beat=%0d expected=%08x actual=%08x",
               expected_block_id,
               observed_beat_index,
               block_word(expected_block_id, observed_beat_index),
               m_axis_tdata);
      end
      if (m_axis_tuser !== block_tuser(expected_block_id)) begin
        $fatal(1,
               "replay metadata order mismatch block=%0d expected=%02x actual=%02x",
               expected_block_id,
               block_tuser(expected_block_id),
               m_axis_tuser);
      end
      if (m_axis_tlast !== (observed_beat_index == (BLOCK_BEATS - 1))) begin
        $fatal(1,
               "replay tlast mismatch block=%0d beat=%0d actual=%0d",
               expected_block_id,
               observed_beat_index,
               m_axis_tlast);
      end
      if (observed_beat_index == (BLOCK_BEATS - 1)) begin
        observed_block_index = observed_block_index + 1;
        observed_beat_index = 0;
        observed_blocks = observed_blocks + 1;
      end else begin
        observed_beat_index = observed_beat_index + 1;
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_status_manual = 1'b0;
    clear_on_replay_last = 1'b0;
    replay_start_ready = 1'b0;
    s_axis_tdata = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    s_axis_tuser = '0;
    m_axis_tready = 1'b0;
    capture_clear_checks = 0;
    replay_clear_checks = 0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    if (CAPTURE_SLOTS_PER_ENGINE == 1) begin
      replay_start_ready = 1'b1;
      m_axis_tready = 1'b1;
      send_block(0, -1, -1);
      wait (observed_blocks == 1);
      wait (s_axis_tready);
      send_block(1, -1, -1);
      wait (observed_blocks == 2);
      wait (s_axis_tready);
      send_block(2, -1, -1);
    end else begin
      send_block(0, -1, -1);
      send_block(1, BLOCK_BEATS - 1, BLOCK_BEATS - 1);
      m_axis_tready = 1'b1;
      wait (observed_blocks == 1);
      clear_on_replay_last = 1'b1;
      send_block(2, -1, -1);
    end

    wait (observed_blocks == 3);
    repeat (4) @(posedge clk);
    if (stat_error_flags != 32'd0) begin
      $fatal(1, "unexpected capture/replay error flags=%08x", stat_error_flags);
    end
    if (stat_current_occupancy_slots != 4'd0) begin
      $fatal(1, "capture/replay occupancy did not drain: %0d", stat_current_occupancy_slots);
    end
    if ((CAPTURE_SLOTS_PER_ENGINE > 1) &&
        ((capture_clear_checks != 1) || (replay_clear_checks != 1))) begin
      $fatal(1,
             "capture/replay clear checks missing capture=%0d replay=%0d",
             capture_clear_checks,
             replay_clear_checks);
    end
    $display("PASS tb_mrtc_axis_raw_block_capture_replay slots=%0d",
             CAPTURE_SLOTS_PER_ENGINE);
    $finish;
  end

  initial begin
    repeat (5000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_axis_raw_block_capture_replay");
  end
endmodule
