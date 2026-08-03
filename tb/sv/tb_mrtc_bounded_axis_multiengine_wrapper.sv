`timescale 1ns/1ps

module tb_mrtc_bounded_axis_multiengine_wrapper #(
  parameter int BLOCK_COUNT = 32,
  parameter bit SHORT_BACKPRESSURE = 1'b0,
  parameter bit EXPECT_SCHEDULER_FAILURE = 1'b0,
  parameter real CLOCK_HALF_PERIOD_NS = 2.5
);
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int NUM_ENGINES = 2;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;
  localparam int MAX_PACKET_BEATS = MRTC_MAX_OUTPUT_BYTES / (AXIS_DATA_W / 8);
  localparam int TRACE_OUTPUT_FIFO_DEPTH = 16;
  localparam int BLOCK_COUNT_CHECK = 1 / (((BLOCK_COUNT >= 2) &&
                                           ((BLOCK_COUNT % 2) == 0)) ? 1 : 0);

  logic clk;
  logic rst_n;
  logic clear_status;

  logic desc_valid;
  logic desc_ready;
  logic [15:0] desc_block_id;
  logic [15:0] desc_block_range_start;
  logic desc_last_block;

  logic [AXIS_DATA_W-1:0] raw_tdata;
  logic raw_tvalid;
  logic raw_tready;
  logic raw_tlast;

  logic [AXIS_DATA_W-1:0] out_tdata;
  logic out_tvalid;
  logic out_tready;
  logic out_tlast;
  logic [7:0] out_tuser;

  logic stat_busy;
  logic stat_done;
  logic [31:0] stat_num_blocks;
  logic [31:0] stat_raw_bytes;
  logic [31:0] stat_comp_bytes;
  logic [31:0] stat_error;
  logic [31:0] stat_stall_input;
  logic [31:0] stat_stall_output;
  logic [31:0] stat_desc_accepted;
  logic [31:0] stat_input_blocks;
  logic [31:0] stat_output_packets;
  logic [4:0] stat_fifo_level;
  logic [4:0] stat_fifo_max_level;

  logic [NUM_ENGINES-1:0] bpack_req;
  logic [NUM_ENGINES-1:0][7:0] bpack_addr;
`ifdef RDTC_DIRECT_PROFILE_TRACE
  logic [NUM_ENGINES-1:0] ring_rsp_valid;
  logic [NUM_ENGINES-1:0][7:0] ring_rsp_addr;
  logic trace_fifo_identity_valid [0:TRACE_OUTPUT_FIFO_DEPTH-1];
  logic trace_fifo_owner [0:TRACE_OUTPUT_FIFO_DEPTH-1];
  logic [15:0] trace_fifo_block [0:TRACE_OUTPUT_FIFO_DEPTH-1];
`endif
  integer read_count [0:NUM_ENGINES-1];
  integer read_last_cycle [0:NUM_ENGINES-1];
  integer read_sequences [0:NUM_ENGINES-1];
  logic read_active [0:NUM_ENGINES-1];

  integer cycle_count;
  integer first_input_cycle;
  integer last_output_cycle;
  integer descriptor_count;
  integer input_block_count;
  integer input_word_count;
  integer packet_count;
  integer packet_beat_index;
  integer current_packet_block;
  integer current_packet_k;
  integer packets_seen [0:BLOCK_COUNT-1];
  integer engine_blocks [0:NUM_ENGINES-1];
  integer output_hold_checks;
  logic output_hold_active;
  logic [AXIS_DATA_W-1:0] output_hold_data;
  logic output_hold_last;
  logic [7:0] output_hold_user;
  integer bp_stall_count;
  logic bp_stall_header;
  logic bp_header_done;
  logic bp_payload_done;
  logic bp_header_target;
  logic bp_payload_target;

  logic [AXIS_DATA_W-1:0] captured_data [0:1][0:MAX_PACKET_BEATS-1];
  logic [7:0] captured_user [0:1][0:MAX_PACKET_BEATS-1];
  logic captured_last [0:1][0:MAX_PACKET_BEATS-1];
  integer captured_beats [0:1];

  logic [AXIS_DATA_W-1:0] dec_in_tdata;
  logic dec_in_tvalid;
  logic dec_in_tready;
  logic dec_in_tlast;
  logic [7:0] dec_in_tuser;
  logic [AXIS_DATA_W-1:0] dec_out_tdata;
  logic dec_out_tvalid;
  logic dec_out_tlast;
  logic [7:0] dec_out_tuser;
  logic dec_busy;
  logic dec_done;
  logic [31:0] dec_num_blocks;
  logic [31:0] dec_error;
  integer decode_target_block;
  integer decode_word_index;
  integer decode_packets_done;
  logic decode_active;
  logic scheduler_failure_seen;

  initial clk = 1'b0;
  always #(CLOCK_HALF_PERIOD_NS) clk = ~clk;

  assign bp_header_target = SHORT_BACKPRESSURE && !bp_header_done &&
                            (packet_count == 0) &&
                            (packet_beat_index == 1) && out_tvalid;
  assign bp_payload_target = SHORT_BACKPRESSURE && !bp_payload_done &&
                             (packet_count == 0) &&
                             (packet_beat_index == 4) && out_tvalid;
  assign out_tready = !SHORT_BACKPRESSURE ||
                      !((bp_stall_count != 0) || bp_header_target ||
                        bp_payload_target);

  assign bpack_req[0] = u_dut.g_engine[0].u_engine.bpack_word_rd_req;
  assign bpack_req[1] = u_dut.g_engine[1].u_engine.bpack_word_rd_req;
  assign bpack_addr[0] = u_dut.g_engine[0].u_engine.bpack_word_rd_addr;
  assign bpack_addr[1] = u_dut.g_engine[1].u_engine.bpack_word_rd_addr;
`ifdef RDTC_DIRECT_PROFILE_TRACE
  assign ring_rsp_valid[0] = u_dut.g_engine[0].u_engine.ring_rd_valid;
  assign ring_rsp_valid[1] = u_dut.g_engine[1].u_engine.ring_rd_valid;
  assign ring_rsp_addr[0] = u_dut.g_engine[0].u_engine.ring_rd_word_index;
  assign ring_rsp_addr[1] = u_dut.g_engine[1].u_engine.ring_rd_word_index;

  // Mirror only output identity alongside the DUT FIFO; packet bytes remain in
  // the DUT and the trace samples them directly at the external AXIS boundary.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int slot = 0; slot < TRACE_OUTPUT_FIFO_DEPTH; slot = slot + 1) begin
        trace_fifo_identity_valid[slot] <= 1'b0;
        trace_fifo_owner[slot] <= 1'b0;
        trace_fifo_block[slot] <= 16'd0;
      end
    end else begin
      if (u_dut.output_fifo_pop) begin
        trace_fifo_identity_valid[u_dut.u_output_fifo.rd_ptr_reg] <= 1'b0;
      end
      if (u_dut.output_fifo_push) begin
        trace_fifo_identity_valid[u_dut.u_output_fifo.wr_ptr_reg] <= 1'b1;
        trace_fifo_owner[u_dut.u_output_fifo.wr_ptr_reg] <=
          u_dut.job_engine_reg[u_dut.output_rd_ptr_reg];
        trace_fifo_block[u_dut.u_output_fifo.wr_ptr_reg] <=
          u_dut.job_block_id_reg[u_dut.output_rd_ptr_reg];
      end
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bp_stall_count <= 0;
      bp_stall_header <= 1'b0;
      bp_header_done <= 1'b0;
      bp_payload_done <= 1'b0;
    end else if (!SHORT_BACKPRESSURE) begin
      bp_stall_count <= 0;
      bp_stall_header <= 1'b0;
      bp_header_done <= 1'b0;
      bp_payload_done <= 1'b0;
    end else if (bp_stall_count != 0) begin
      if (bp_stall_count == 1) begin
        bp_stall_count <= 0;
        if (bp_stall_header) begin
          bp_header_done <= 1'b1;
        end else begin
          bp_payload_done <= 1'b1;
        end
      end else begin
        bp_stall_count <= bp_stall_count - 1;
      end
    end else if (bp_header_target || bp_payload_target) begin
      // The target cycle is already stalled; retain one more cycle here.
      bp_stall_count <= 1;
      bp_stall_header <= bp_header_target;
`ifdef RDTC_DIRECT_PROFILE_TRACE
      if (bp_header_target) begin
        $display(
          "DIRECT_AXIS_TRACE_BP kind=header cycle=%0d packet=0 beat=1 stall_cycles=2",
          cycle_count + 1);
      end else begin
        $display(
          "DIRECT_AXIS_TRACE_BP kind=payload cycle=%0d packet=0 beat=4 stall_cycles=2",
          cycle_count + 1);
      end
`endif
    end
  end

`ifdef RDTC_DIRECT_PROFILE_TRACE
  // Capture edge events before NBA, then emit one row after NBA settles.
  always @(posedge clk) begin : direct_axis_cycle_trace
    integer trace_cycle;
    integer trace_input_fire;
    integer trace_input_owner;
    integer trace_input_block;
    integer trace_e0_prefix_done;
    integer trace_e0_k_valid;
    integer trace_e0_k;
    integer trace_e0_ring_wr;
    integer trace_e0_ring_wr_addr;
    integer trace_e0_ring_wr_block;
    integer trace_e0_ring_rd_req;
    integer trace_e0_ring_rd_req_addr;
    integer trace_e0_ring_rd_req_block;
    integer trace_e0_ring_rd_rsp;
    integer trace_e0_ring_rd_rsp_addr;
    integer trace_e0_ring_rd_rsp_block;
    integer trace_e0_block;
    integer trace_e1_prefix_done;
    integer trace_e1_k_valid;
    integer trace_e1_k;
    integer trace_e1_ring_wr;
    integer trace_e1_ring_wr_addr;
    integer trace_e1_ring_wr_block;
    integer trace_e1_ring_rd_req;
    integer trace_e1_ring_rd_req_addr;
    integer trace_e1_ring_rd_req_block;
    integer trace_e1_ring_rd_rsp;
    integer trace_e1_ring_rd_rsp_addr;
    integer trace_e1_ring_rd_rsp_block;
    integer trace_e1_block;
    integer trace_m_tvalid;
    integer trace_m_tready;
    logic [AXIS_DATA_W-1:0] trace_m_tdata;
    logic [7:0] trace_m_tuser;
    integer trace_m_tlast;
    integer trace_output_owner;
    integer trace_output_block;
    integer trace_wrapper_error;
    integer trace_e0_error;
    integer trace_e1_error;

    if (rst_n) begin
      trace_cycle = cycle_count + 1;
      trace_input_fire = u_dut.input_fire;
      trace_input_owner = u_dut.input_fire ?
                          int'(u_dut.job_engine_reg[u_dut.input_rd_ptr_reg]) : -1;
      trace_input_block = u_dut.input_fire ?
                          int'(u_dut.job_block_id_reg[u_dut.input_rd_ptr_reg]) : -1;

      trace_e0_prefix_done = u_dut.g_engine[0].u_engine.prefix_done;
      trace_e0_k_valid = u_dut.g_engine[0].u_engine.selected_k_valid_reg;
      trace_e0_k = trace_e0_k_valid ?
                   int'(u_dut.g_engine[0].u_engine.selected_k_reg) : -1;
      trace_e0_ring_wr = u_dut.g_engine[0].u_engine.ring_wr_en;
      trace_e0_ring_wr_addr = trace_e0_ring_wr ?
        int'(u_dut.g_engine[0].u_engine.capture_word_count_reg) : -1;
      trace_e0_ring_wr_block = trace_e0_ring_wr ?
        int'(u_dut.g_engine[0].u_engine.block_id_reg) : -1;
      trace_e0_ring_rd_req = u_dut.g_engine[0].u_engine.ring_rd_req;
      trace_e0_ring_rd_req_addr = trace_e0_ring_rd_req ?
        int'(u_dut.g_engine[0].u_engine.bpack_word_rd_addr) : -1;
      trace_e0_ring_rd_req_block = trace_e0_ring_rd_req ?
        int'(u_dut.g_engine[0].u_engine.block_id_reg) : -1;
      trace_e0_ring_rd_rsp = u_dut.g_engine[0].u_engine.ring_rd_valid;
      trace_e0_ring_rd_rsp_addr = trace_e0_ring_rd_rsp ?
        int'(u_dut.g_engine[0].u_engine.ring_rd_word_index) : -1;
      trace_e0_ring_rd_rsp_block = trace_e0_ring_rd_rsp ?
        int'(u_dut.g_engine[0].u_engine.block_id_reg) : -1;
      trace_e0_block = u_dut.g_engine[0].u_engine.block_active_reg ?
                       int'(u_dut.g_engine[0].u_engine.block_id_reg) : -1;

      trace_e1_prefix_done = u_dut.g_engine[1].u_engine.prefix_done;
      trace_e1_k_valid = u_dut.g_engine[1].u_engine.selected_k_valid_reg;
      trace_e1_k = trace_e1_k_valid ?
                   int'(u_dut.g_engine[1].u_engine.selected_k_reg) : -1;
      trace_e1_ring_wr = u_dut.g_engine[1].u_engine.ring_wr_en;
      trace_e1_ring_wr_addr = trace_e1_ring_wr ?
        int'(u_dut.g_engine[1].u_engine.capture_word_count_reg) : -1;
      trace_e1_ring_wr_block = trace_e1_ring_wr ?
        int'(u_dut.g_engine[1].u_engine.block_id_reg) : -1;
      trace_e1_ring_rd_req = u_dut.g_engine[1].u_engine.ring_rd_req;
      trace_e1_ring_rd_req_addr = trace_e1_ring_rd_req ?
        int'(u_dut.g_engine[1].u_engine.bpack_word_rd_addr) : -1;
      trace_e1_ring_rd_req_block = trace_e1_ring_rd_req ?
        int'(u_dut.g_engine[1].u_engine.block_id_reg) : -1;
      trace_e1_ring_rd_rsp = u_dut.g_engine[1].u_engine.ring_rd_valid;
      trace_e1_ring_rd_rsp_addr = trace_e1_ring_rd_rsp ?
        int'(u_dut.g_engine[1].u_engine.ring_rd_word_index) : -1;
      trace_e1_ring_rd_rsp_block = trace_e1_ring_rd_rsp ?
        int'(u_dut.g_engine[1].u_engine.block_id_reg) : -1;
      trace_e1_block = u_dut.g_engine[1].u_engine.block_active_reg ?
                       int'(u_dut.g_engine[1].u_engine.block_id_reg) : -1;

      trace_m_tvalid = out_tvalid;
      trace_m_tready = out_tready;
      trace_m_tdata = out_tvalid ? out_tdata : '0;
      trace_m_tuser = out_tvalid ? out_tuser : '0;
      trace_m_tlast = out_tvalid ? out_tlast : 0;
      if (out_tvalid &&
          !trace_fifo_identity_valid[u_dut.u_output_fifo.rd_ptr_reg]) begin
        $fatal(1, "output trace identity is missing");
      end
      trace_output_owner = out_tvalid ?
        int'(trace_fifo_owner[u_dut.u_output_fifo.rd_ptr_reg]) : -1;
      trace_output_block = out_tvalid ?
        int'(trace_fifo_block[u_dut.u_output_fifo.rd_ptr_reg]) : -1;
      trace_wrapper_error = stat_error;
      trace_e0_error = u_dut.eng_stat_error[0];
      trace_e1_error = u_dut.eng_stat_error[1];

      #1step;
      $display(
        "DIRECT_AXIS_CYCLE cycle=%0d input_fire=%0d input_owner=%0d input_block=%0d e0_prefix_done=%0d e0_k_valid=%0d e0_k=%0d e0_ring_wr=%0d e0_ring_wr_addr=%0d e0_ring_wr_block=%0d e0_ring_rd_req=%0d e0_ring_rd_req_addr=%0d e0_ring_rd_req_block=%0d e0_ring_rd_rsp=%0d e0_ring_rd_rsp_addr=%0d e0_ring_rd_rsp_block=%0d e0_block=%0d e1_prefix_done=%0d e1_k_valid=%0d e1_k=%0d e1_ring_wr=%0d e1_ring_wr_addr=%0d e1_ring_wr_block=%0d e1_ring_rd_req=%0d e1_ring_rd_req_addr=%0d e1_ring_rd_req_block=%0d e1_ring_rd_rsp=%0d e1_ring_rd_rsp_addr=%0d e1_ring_rd_rsp_block=%0d e1_block=%0d m_tvalid=%0d m_tready=%0d m_tdata=%032h m_tuser=%02h m_tlast=%0d output_owner=%0d output_block=%0d wrapper_error=%0d e0_error=%0d e1_error=%0d",
        trace_cycle, trace_input_fire, trace_input_owner, trace_input_block,
        trace_e0_prefix_done, trace_e0_k_valid, trace_e0_k,
        trace_e0_ring_wr, trace_e0_ring_wr_addr, trace_e0_ring_wr_block,
        trace_e0_ring_rd_req, trace_e0_ring_rd_req_addr,
        trace_e0_ring_rd_req_block, trace_e0_ring_rd_rsp,
        trace_e0_ring_rd_rsp_addr, trace_e0_ring_rd_rsp_block, trace_e0_block,
        trace_e1_prefix_done, trace_e1_k_valid, trace_e1_k,
        trace_e1_ring_wr, trace_e1_ring_wr_addr, trace_e1_ring_wr_block,
        trace_e1_ring_rd_req, trace_e1_ring_rd_req_addr,
        trace_e1_ring_rd_req_block, trace_e1_ring_rd_rsp,
        trace_e1_ring_rd_rsp_addr, trace_e1_ring_rd_rsp_block, trace_e1_block,
        trace_m_tvalid, trace_m_tready, trace_m_tdata, trace_m_tuser,
        trace_m_tlast, trace_output_owner, trace_output_block,
        trace_wrapper_error, trace_e0_error, trace_e1_error);
    end
  end
`endif

  function automatic logic [AXIS_DATA_W-1:0] block_word(
    input int block_index,
    input int word_index
  );
    logic [AXIS_DATA_W-1:0] value;
    int sample_index;
    int i_value;
    int q_value;
    begin
      value = '0;
      for (int lane = 0; lane < MRTC_LANES; lane = lane + 1) begin
        sample_index = (word_index * MRTC_LANES) + lane;
        if ((block_index & 1) == 0) begin
          i_value = 0;
          q_value = 0;
        end else begin
          i_value = ((sample_index * 5 + block_index * 3) % 15) - 7;
          q_value = ((sample_index * 7 + block_index) % 13) - 6;
        end
        value[(lane * 32) +: 16] = 16'(i_value);
        value[(lane * 32) + 16 +: 16] = 16'(q_value);
      end
      block_word = value;
    end
  endfunction

  function automatic int signed_to_mapped(input int value);
    signed_to_mapped = (value < 0) ? (((-value) * 2) - 1) : (value * 2);
  endfunction

  function automatic int word_cost(
    input int block_index,
    input int word_index,
    input int k_value
  );
    logic [AXIS_DATA_W-1:0] value;
    int total;
    int i_value;
    int q_value;
    begin
      value = block_word(block_index, word_index);
      total = 0;
      for (int lane = 0; lane < MRTC_LANES; lane = lane + 1) begin
        i_value = $signed(value[(lane * 32) +: 16]);
        q_value = $signed(value[(lane * 32) + 16 +: 16]);
        total = total + (signed_to_mapped(i_value) >> k_value) + 1 + k_value;
        total = total + (signed_to_mapped(q_value) >> k_value) + 1 + k_value;
      end
      word_cost = total;
    end
  endfunction

  function automatic int expected_k(input int block_index);
    int best_k;
    int best_cost;
    int candidate_cost;
    begin
      best_k = 0;
      best_cost = 32'h7fff_ffff;
      for (int k_value = 0; k_value < 16; k_value = k_value + 1) begin
        candidate_cost = 0;
        for (int word_index = 0; word_index < 32; word_index = word_index + 1) begin
          candidate_cost = candidate_cost + word_cost(block_index, word_index, k_value);
        end
        if (candidate_cost < best_cost) begin
          best_cost = candidate_cost;
          best_k = k_value;
        end
      end
      expected_k = best_k;
    end
  endfunction

  function automatic int header_byte(
    input logic [AXIS_DATA_W-1:0] beat_data,
    input int byte_index
  );
    header_byte = beat_data[(byte_index * 8) +: 8];
  endfunction

  task automatic drive_descriptors;
    begin : descriptor_loop
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        @(negedge clk);
        desc_valid = 1'b1;
        desc_block_id = 16'(block_index);
        desc_block_range_start = 16'(16'h4000 + block_index);
        desc_last_block = (block_index == (BLOCK_COUNT - 1));
        do begin
          @(posedge clk);
          if (stat_error != MRTC_ERR_NONE) begin
            if (EXPECT_SCHEDULER_FAILURE &&
                (stat_error == MRTC_ERR_SRAM_WAY_CONFLICT)) begin
              disable descriptor_loop;
            end else begin
              $fatal(1, "descriptor path failed block=%0d error=%0d",
                     block_index, stat_error);
            end
          end
        end while (!desc_ready);
      end
      @(negedge clk);
      desc_valid = 1'b0;
      desc_block_id = '0;
      desc_block_range_start = '0;
      desc_last_block = 1'b0;
    end
  endtask

  task automatic drive_continuous_input;
    begin : input_loop
      wait (descriptor_count >= 2);
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        for (int word_index = 0; word_index < BLOCK_WORDS; word_index = word_index + 1) begin
          @(negedge clk);
          raw_tvalid = 1'b1;
          raw_tdata = block_word(block_index, word_index);
          raw_tlast = (word_index == (BLOCK_WORDS - 1));
          @(posedge clk);
          if (!raw_tready) begin
            if (EXPECT_SCHEDULER_FAILURE &&
                (stat_error == MRTC_ERR_SRAM_WAY_CONFLICT)) begin
              scheduler_failure_seen = 1'b1;
              disable input_loop;
            end else begin
              $fatal(1,
                     "direct input stalled block=%0d word=%0d error=%0d jobs=%0d pending=%0d e0_cap=%0d e0_rd=%0d e0_err=%0d e1_cap=%0d e1_rd=%0d e1_err=%0d",
                     block_index, word_index, stat_error,
                     u_dut.job_count_reg, u_dut.input_pending_count_reg,
                     u_dut.g_engine[0].u_engine.capture_word_count_reg,
                     u_dut.g_engine[0].u_engine.bpack_word_rd_addr,
                     u_dut.g_engine[0].u_engine.stat_error,
                     u_dut.g_engine[1].u_engine.capture_word_count_reg,
                     u_dut.g_engine[1].u_engine.bpack_word_rd_addr,
                     u_dut.g_engine[1].u_engine.stat_error);
            end
          end
          if (u_dut.job_engine_reg[u_dut.input_rd_ptr_reg] !== logic'(block_index & 1)) begin
            $fatal(1, "direct input engine order mismatch block=%0d engine=%0d",
                   block_index, u_dut.job_engine_reg[u_dut.input_rd_ptr_reg]);
          end
        end
      end
      @(negedge clk);
      raw_tvalid = 1'b0;
      raw_tdata = '0;
      raw_tlast = 1'b0;
    end
  endtask

  task automatic replay_packet(input int capture_index, input int block_index);
    integer done_before;
    begin
      done_before = decode_packets_done;
      decode_target_block = block_index;
      decode_word_index = 0;
      decode_active = 1'b1;
      for (int beat_index = 0; beat_index < captured_beats[capture_index];
           beat_index = beat_index + 1) begin
        @(negedge clk);
        dec_in_tdata = captured_data[capture_index][beat_index];
        dec_in_tuser = captured_user[capture_index][beat_index];
        dec_in_tlast = captured_last[capture_index][beat_index];
        dec_in_tvalid = 1'b1;
        do begin
          @(posedge clk);
        end while (!dec_in_tready);
      end
      @(negedge clk);
      dec_in_tvalid = 1'b0;
      dec_in_tdata = '0;
      dec_in_tuser = '0;
      dec_in_tlast = 1'b0;
      wait (decode_packets_done == (done_before + 1));
      decode_active = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    int observed_block;
    int observed_range;
    int observed_flags;
    if (!rst_n) begin
      cycle_count <= 0;
      first_input_cycle <= -1;
      last_output_cycle <= -1;
      descriptor_count <= 0;
      input_block_count <= 0;
      input_word_count <= 0;
      packet_count <= 0;
      packet_beat_index <= 0;
      current_packet_block <= -1;
      current_packet_k <= -1;
      output_hold_checks <= 0;
      output_hold_active <= 1'b0;
      output_hold_data <= '0;
      output_hold_last <= 1'b0;
      output_hold_user <= '0;
      captured_beats[0] <= 0;
      captured_beats[1] <= 0;
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        packets_seen[block_index] <= 0;
      end
      for (int engine = 0; engine < NUM_ENGINES; engine = engine + 1) begin
        engine_blocks[engine] <= 0;
        read_count[engine] <= 0;
        read_last_cycle[engine] <= -1;
        read_sequences[engine] <= 0;
        read_active[engine] <= 1'b0;
      end

      if (u_dut.g_engine[0].u_engine.ring_way_conflict) begin
        $display(
          "DIRECT_AXIS_CONFLICT cycle=%0d engine=0 capture=%0d read=%0d wr_way=%0d rd_way=%0d k_cycle=%0d first_read=%0d",
          cycle_count,
          u_dut.g_engine[0].u_engine.capture_word_count_reg,
          u_dut.g_engine[0].u_engine.bpack_word_rd_addr,
          u_dut.g_engine[0].u_engine.u_way_ring.wr_way_comb,
          u_dut.g_engine[0].u_engine.u_way_ring.rd_way_comb,
          u_dut.g_engine[0].u_engine.dbg_k_valid_cycle,
          u_dut.g_engine[0].u_engine.dbg_first_read_cycle);
      end
      if (u_dut.g_engine[1].u_engine.ring_way_conflict) begin
        $display(
          "DIRECT_AXIS_CONFLICT cycle=%0d engine=1 capture=%0d read=%0d wr_way=%0d rd_way=%0d k_cycle=%0d first_read=%0d",
          cycle_count,
          u_dut.g_engine[1].u_engine.capture_word_count_reg,
          u_dut.g_engine[1].u_engine.bpack_word_rd_addr,
          u_dut.g_engine[1].u_engine.u_way_ring.wr_way_comb,
          u_dut.g_engine[1].u_engine.u_way_ring.rd_way_comb,
          u_dut.g_engine[1].u_engine.dbg_k_valid_cycle,
          u_dut.g_engine[1].u_engine.dbg_first_read_cycle);
      end
    end else begin
      cycle_count <= cycle_count + 1;

      if (desc_valid && desc_ready) begin
        descriptor_count <= descriptor_count + 1;
      end

      if (raw_tvalid && raw_tready) begin
        if (first_input_cycle < 0) begin
          first_input_cycle <= cycle_count;
        end
        if (input_word_count == 0) begin
          if (u_dut.job_engine_reg[u_dut.input_rd_ptr_reg] !== logic'(input_block_count & 1)) begin
            $fatal(1, "input monitor engine order mismatch block=%0d", input_block_count);
          end
          engine_blocks[input_block_count & 1] <= engine_blocks[input_block_count & 1] + 1;
        end
        if (raw_tdata !== block_word(input_block_count, input_word_count)) begin
          $fatal(1, "input data mismatch block=%0d word=%0d",
                 input_block_count, input_word_count);
        end
        if (raw_tlast != (input_word_count == (BLOCK_WORDS - 1))) begin
          $fatal(1, "input tlast mismatch block=%0d word=%0d",
                 input_block_count, input_word_count);
        end
        if (raw_tlast) begin
          input_block_count <= input_block_count + 1;
          input_word_count <= 0;
        end else begin
          input_word_count <= input_word_count + 1;
        end
      end

      for (int engine = 0; engine < NUM_ENGINES; engine = engine + 1) begin
        if (bpack_req[engine]) begin
`ifdef RDTC_DIRECT_PROFILE_TRACE
          $display(
            "DIRECT_AXIS_PROFILE_MEMORY kind=req cycle=%0d engine=%0d addr=%0d",
            cycle_count, engine, bpack_addr[engine]);
`endif
          if (!read_active[engine]) begin
            if (bpack_addr[engine] != 0) begin
              $fatal(1, "engine %0d first read address=%0d", engine, bpack_addr[engine]);
            end
            read_active[engine] <= 1'b1;
            read_count[engine] <= 1;
            $display(
              "DIRECT_AXIS_FIRST_READ cycle=%0d engine=%0d capture=%0d local_cycle=%0d addr=%0d",
              cycle_count, engine,
              (engine == 0) ?
                u_dut.g_engine[0].u_engine.capture_word_count_reg :
                u_dut.g_engine[1].u_engine.capture_word_count_reg,
              (engine == 0) ?
                u_dut.g_engine[0].u_engine.cycle_count_reg :
                u_dut.g_engine[1].u_engine.cycle_count_reg,
              bpack_addr[engine]);
          end else begin
            if (bpack_addr[engine] != read_count[engine][7:0]) begin
              $fatal(1, "engine %0d read address mismatch count=%0d addr=%0d",
                     engine, read_count[engine], bpack_addr[engine]);
            end
            if (cycle_count != (read_last_cycle[engine] + 1)) begin
              $fatal(1, "engine %0d read issue gap count=%0d", engine, read_count[engine]);
            end
            if (read_count[engine] == (BLOCK_WORDS - 1)) begin
              read_active[engine] <= 1'b0;
              read_count[engine] <= 0;
              read_sequences[engine] <= read_sequences[engine] + 1;
            end else begin
              read_count[engine] <= read_count[engine] + 1;
            end
          end
          read_last_cycle[engine] <= cycle_count;
        end else if (read_active[engine] &&
                     (u_dut.eng_stat_error[engine] == MRTC_ERR_NONE)) begin
          $fatal(1, "engine %0d read request cadence broke at count=%0d",
                 engine, read_count[engine]);
        end
`ifdef RDTC_DIRECT_PROFILE_TRACE
        if (ring_rsp_valid[engine]) begin
          $display(
            "DIRECT_AXIS_PROFILE_MEMORY kind=rsp cycle=%0d engine=%0d addr=%0d",
            cycle_count, engine, ring_rsp_addr[engine]);
        end
`endif
      end

      if (output_hold_active) begin
        if (!out_tvalid || (out_tdata !== output_hold_data) ||
            (out_tlast !== output_hold_last) || (out_tuser !== output_hold_user)) begin
          $fatal(1, "output changed under backpressure");
        end
        output_hold_checks <= output_hold_checks + 1;
      end
      output_hold_active <= out_tvalid && !out_tready;
      if (out_tvalid && !out_tready) begin
        output_hold_data <= out_tdata;
        output_hold_last <= out_tlast;
        output_hold_user <= out_tuser;
      end

      if (out_tvalid && out_tready) begin
`ifdef RDTC_DIRECT_PROFILE_TRACE
        $display(
          "DIRECT_AXIS_PROFILE_BEAT packet=%0d beat=%0d data=%032h user=%02h last=%0d",
          packet_count, packet_beat_index, out_tdata, out_tuser, out_tlast);
`endif
        if (packet_beat_index == 0) begin
          observed_block = header_byte(out_tdata, MRTC_HDR_OFF_BLOCK_ID) |
                           (header_byte(out_tdata, MRTC_HDR_OFF_BLOCK_ID + 1) << 8);
          if (observed_block != packet_count) begin
            $fatal(1, "output order mismatch packet=%0d block=%0d",
                   packet_count, observed_block);
          end
          current_packet_block <= observed_block;
          current_packet_k <= -1;
        end
        if (packet_beat_index == 1) begin
          observed_range = header_byte(out_tdata, MRTC_HDR_OFF_BLOCK_RANGE - 16) |
                           (header_byte(out_tdata, MRTC_HDR_OFF_BLOCK_RANGE + 1 - 16) << 8);
          observed_flags = header_byte(out_tdata, MRTC_HDR_OFF_FLAGS - 16) |
                           (header_byte(out_tdata, MRTC_HDR_OFF_FLAGS + 1 - 16) << 8);
          current_packet_k <= header_byte(out_tdata, MRTC_HDR_OFF_RICE_K - 16);
          if (observed_range != (16'h4000 + packet_count)) begin
            $fatal(1, "header range patch mismatch packet=%0d got=%0h",
                   packet_count, observed_range);
          end
          if (((observed_flags & MRTC_FLAG_LAST_BLOCK) != 0) !=
              (packet_count == (BLOCK_COUNT - 1))) begin
            $fatal(1, "header last-block patch mismatch packet=%0d flags=%04x",
                   packet_count, observed_flags);
          end
        end
        if (packet_count < 2) begin
          if (packet_beat_index >= MAX_PACKET_BEATS) begin
            $fatal(1, "captured packet too large packet=%0d", packet_count);
          end
          captured_data[packet_count][packet_beat_index] <= out_tdata;
          captured_user[packet_count][packet_beat_index] <= out_tuser;
          captured_last[packet_count][packet_beat_index] <= out_tlast;
        end
        if (out_tlast) begin
          if (current_packet_block != packet_count) begin
            $fatal(1, "packet identity changed packet=%0d block=%0d",
                   packet_count, current_packet_block);
          end
          if (current_packet_k != expected_k(packet_count)) begin
            $fatal(1, "selected-k mismatch block=%0d expected=%0d got=%0d",
                   packet_count, expected_k(packet_count), current_packet_k);
          end
          if (out_tuser[3:0] > 4'd15) begin
            $fatal(1, "invalid final byte count packet=%0d user=%02x",
                   packet_count, out_tuser);
          end
          packets_seen[packet_count] <= 1;
          if (packet_count < 2) begin
            captured_beats[packet_count] <= packet_beat_index + 1;
          end
          packet_count <= packet_count + 1;
          packet_beat_index <= 0;
          last_output_cycle <= cycle_count;
          $display(
            "DIRECT_AXIS_PACKET_DONE cycle=%0d packet=%0d beats=%0d fifo=%0d",
            cycle_count, packet_count, packet_beat_index + 1, stat_fifo_level);
`ifdef RDTC_DIRECT_PROFILE_TRACE
          $display(
            "DIRECT_AXIS_PROFILE_PACKET packet=%0d selected_k=%0d expected_k=%0d beats=%0d",
            packet_count, current_packet_k, expected_k(packet_count),
            packet_beat_index + 1);
`endif
        end else begin
          packet_beat_index <= packet_beat_index + 1;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      decode_word_index <= 0;
      decode_packets_done <= 0;
    end else if (dec_out_tvalid) begin
      if (!decode_active) begin
        $fatal(1, "decoder produced data outside replay");
      end
      if (dec_out_tdata !== block_word(decode_target_block, decode_word_index)) begin
        $fatal(1, "decoder mismatch block=%0d word=%0d",
               decode_target_block, decode_word_index);
      end
      if (dec_out_tlast != (decode_word_index == (BLOCK_WORDS - 1))) begin
        $fatal(1, "decoder tlast mismatch block=%0d word=%0d",
               decode_target_block, decode_word_index);
      end
      if (dec_out_tlast) begin
        decode_word_index <= 0;
        decode_packets_done <= decode_packets_done + 1;
      end else begin
        decode_word_index <= decode_word_index + 1;
      end
    end
  end

  initial begin
    logic unused_block_count_check;
    unused_block_count_check = BLOCK_COUNT_CHECK[0];
    rst_n = 1'b0;
    clear_status = 1'b0;
    desc_valid = 1'b0;
    desc_block_id = '0;
    desc_block_range_start = '0;
    desc_last_block = 1'b0;
    raw_tdata = '0;
    raw_tvalid = 1'b0;
    raw_tlast = 1'b0;
    dec_in_tdata = '0;
    dec_in_tvalid = 1'b0;
    dec_in_tlast = 1'b0;
    dec_in_tuser = '0;
      decode_target_block = 0;
      decode_active = 1'b0;
      scheduler_failure_seen = 1'b0;
    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    fork
      drive_descriptors();
      drive_continuous_input();
    join

    if (EXPECT_SCHEDULER_FAILURE) begin
      wait (scheduler_failure_seen ||
            (stat_error != MRTC_ERR_NONE));
      repeat (4) @(posedge clk);
      if ((stat_error != MRTC_ERR_SRAM_WAY_CONFLICT) || raw_tready ||
          (packet_count == 0)) begin
        $fatal(1,
               "scheduler failure classification mismatch error=%0d ready=%0d packets=%0d",
               stat_error, raw_tready, packet_count);
      end
      $display(
        "DIRECT_AXIS_SCHEDULER_LIMIT blocks_requested=%0d packets_before_failure=%0d error=%0d e0_first_read=%0d e1_first_read=%0d",
        BLOCK_COUNT, packet_count, stat_error,
        u_dut.g_engine[0].u_engine.dbg_first_read_cycle,
        u_dut.g_engine[1].u_engine.dbg_first_read_cycle);
      $display(
        "PASS tb_mrtc_bounded_axis_multiengine_wrapper EXPECTED_SCHEDULER_FAILURE blocks=%0d",
        BLOCK_COUNT);
      $finish;
    end

    for (int wait_cycle = 0;
         (wait_cycle < 150000) && ((packet_count < BLOCK_COUNT) || stat_busy);
         wait_cycle = wait_cycle + 1) begin
      @(posedge clk);
    end
    repeat (4) @(posedge clk);

    if ((stat_error != MRTC_ERR_NONE) || stat_busy ||
        (descriptor_count != BLOCK_COUNT) ||
        (input_block_count != BLOCK_COUNT) ||
        (packet_count != BLOCK_COUNT) ||
        (stat_num_blocks != BLOCK_COUNT) ||
        (stat_desc_accepted != BLOCK_COUNT) ||
        (stat_input_blocks != BLOCK_COUNT) ||
        (stat_output_packets != BLOCK_COUNT) ||
        (stat_stall_input != 0)) begin
      $fatal(1,
             "direct result failed error=%0d busy=%0d desc=%0d/%0d input=%0d/%0d packet=%0d/%0d stalls=%0d",
             stat_error, stat_busy, descriptor_count, stat_desc_accepted,
             input_block_count, stat_input_blocks, packet_count,
             stat_output_packets, stat_stall_input);
    end
    for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
      if (packets_seen[block_index] != 1) begin
        $fatal(1, "missing or duplicate packet block=%0d seen=%0d",
               block_index, packets_seen[block_index]);
      end
    end
    for (int engine = 0; engine < NUM_ENGINES; engine = engine + 1) begin
      if ((engine_blocks[engine] != (BLOCK_COUNT / 2)) ||
          (read_sequences[engine] != (BLOCK_COUNT / 2)) ||
          (u_dut.eng_stat_error[engine] != MRTC_ERR_NONE)) begin
        $fatal(1,
               "engine coverage failed engine=%0d blocks=%0d reads=%0d error=%0d",
               engine, engine_blocks[engine], read_sequences[engine],
               u_dut.eng_stat_error[engine]);
      end
    end
    if (SHORT_BACKPRESSURE && (output_hold_checks == 0)) begin
      $fatal(1, "short backpressure did not exercise output hold");
    end

    replay_packet(0, 0);
    replay_packet(1, 1);
    if ((dec_error != MRTC_ERR_NONE) || (dec_num_blocks != 2) ||
        (decode_packets_done != 2) || (decode_word_index != 0)) begin
      $fatal(1,
             "decoder replay failed error=%0d blocks=%0d scoreboard_blocks=%0d word=%0d",
             dec_error, dec_num_blocks, decode_packets_done, decode_word_index);
    end
`ifdef RDTC_DIRECT_PROFILE_TRACE
    $display(
      "DIRECT_AXIS_PROFILE_DECODER bit_exact=1 blocks=%0d words=%0d",
      decode_packets_done, decode_packets_done * BLOCK_WORDS);
`endif

    $display(
      "DIRECT_AXIS_STREAM blocks=%0d bp=%0d cycles=%0d cycles_per_block=%.3f fifo_max=%0d hold_checks=%0d k_cycle=%0d/%0d first_read=%0d/%0d",
      BLOCK_COUNT, SHORT_BACKPRESSURE,
      last_output_cycle - first_input_cycle + 1,
      real'(last_output_cycle - first_input_cycle + 1) / real'(BLOCK_COUNT),
      stat_fifo_max_level, output_hold_checks,
      u_dut.g_engine[0].u_engine.dbg_k_valid_cycle,
      u_dut.g_engine[1].u_engine.dbg_k_valid_cycle,
      u_dut.g_engine[0].u_engine.dbg_first_read_cycle,
      u_dut.g_engine[1].u_engine.dbg_first_read_cycle);
    $display("PASS tb_mrtc_bounded_axis_multiengine_wrapper blocks=%0d bp=%0d",
             BLOCK_COUNT, SHORT_BACKPRESSURE);
    $finish;
  end

  initial begin
    repeat (500000) @(posedge clk);
    $fatal(1,
           "TIMEOUT tb_mrtc_bounded_axis_multiengine_wrapper blocks=%0d desc=%0d input=%0d packets=%0d error=%0d",
           BLOCK_COUNT, descriptor_count, input_block_count, packet_count, stat_error);
  end

  mrtc_rdtc_bounded_axis_multiengine_wrapper u_dut (
    .clk,
    .rst_n,
    .i_clear_status              (clear_status),
    .s_desc_valid                (desc_valid),
    .s_desc_ready                (desc_ready),
    .s_desc_block_id             (desc_block_id),
    .s_desc_block_range_start    (desc_block_range_start),
    .s_desc_frame_id             (16'hda01),
    .s_desc_codec_mode           (MRTC_CODEC_ZERO_RICE),
    .s_desc_rice_mode            (MRTC_RICE_BLOCK_ADAPTIVE_K),
    .s_desc_fixed_k              (4'd0),
    .s_desc_tensor_spatial_size  (16'd1),
    .s_desc_tensor_doppler_size  (16'd64),
    .s_desc_tensor_range_size    (16'd16),
    .s_desc_last_block           (desc_last_block),
    .s_axis_raw_tdata            (raw_tdata),
    .s_axis_raw_tvalid           (raw_tvalid),
    .s_axis_raw_tready           (raw_tready),
    .s_axis_raw_tlast            (raw_tlast),
    .m_axis_comp_tdata           (out_tdata),
    .m_axis_comp_tvalid          (out_tvalid),
    .m_axis_comp_tready          (out_tready),
    .m_axis_comp_tlast           (out_tlast),
    .m_axis_comp_tuser           (out_tuser),
    .stat_busy,
    .stat_done,
    .stat_num_blocks,
    .stat_raw_bytes,
    .stat_comp_bytes,
    .stat_error,
    .stat_stall_input_cycles     (stat_stall_input),
    .stat_stall_output_cycles    (stat_stall_output),
    .stat_desc_accepted,
    .stat_input_blocks,
    .stat_output_packets,
    .stat_output_fifo_level      (stat_fifo_level),
    .stat_output_fifo_max_level  (stat_fifo_max_level)
  );

  mrtc_rdtc_decoder_top u_decoder (
    .clk,
    .rst_n,
    .i_clear_status             (clear_status),
    .s_axis_comp_tdata          (dec_in_tdata),
    .s_axis_comp_tvalid         (dec_in_tvalid),
    .s_axis_comp_tready         (dec_in_tready),
    .s_axis_comp_tlast          (dec_in_tlast),
    .s_axis_comp_tuser          (dec_in_tuser),
    .m_axis_raw_tdata           (dec_out_tdata),
    .m_axis_raw_tvalid          (dec_out_tvalid),
    .m_axis_raw_tready          (1'b1),
    .m_axis_raw_tlast           (dec_out_tlast),
    .m_axis_raw_tuser           (dec_out_tuser),
    .stat_busy                  (dec_busy),
    .stat_done                  (dec_done),
    .stat_comp_bytes            (),
    .stat_raw_bytes             (),
    .stat_num_blocks            (dec_num_blocks),
    .stat_error                 (dec_error),
    .stat_error_blocks          (),
    .stat_stall_input_cycles    (),
    .stat_stall_output_cycles   ()
  );
endmodule
