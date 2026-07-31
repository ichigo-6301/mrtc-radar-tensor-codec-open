`timescale 1ns/1ps

module tb_mrtc_axis_width_packer_case #(
  parameter int AXIS_DATA_W = 128,
  parameter int FRAG_W = 32,
  parameter bit DRAIN_APPEND_LOOKAHEAD = 1'b0,
  parameter bit REGISTERED_INPUT_QUEUE = 1'b0,
  parameter bit ALWAYS_READY = 1'b0
) (
  output logic o_done
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int VALID_BYTE_COUNT_W = $clog2(AXIS_BYTES + 1);

  logic clk;
  logic rst_n;
  logic s_frag_valid;
  logic s_frag_ready;
  logic [FRAG_W-1:0] s_frag_data;
  logic [$clog2(FRAG_W+1)-1:0] s_frag_bits;
  logic s_frag_last;
  logic [AXIS_DATA_W-1:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] m_axis_tvalid_bytes_minus1;
  logic o_busy_int;
  logic o_done_int;
  logic o_overflow;

  byte expected_bytes [0:1023];
  byte actual_bytes [0:1023];
  int expected_bits;
  int expected_byte_count;
  int expected_beat_count;
  int actual_byte_count;
  int actual_beat_count;
  int actual_last_count;
  int actual_final_valid_bytes;
  logic hold_active;
  logic [AXIS_DATA_W-1:0] hold_tdata;
  logic hold_tlast;
  logic [VALID_BYTE_COUNT_W-1:0] hold_valid_bytes;
  logic force_output_stall;
  int unsigned ready_state;
  integer queue_max_count;
  integer queue_push_pop_count;
  integer byte_idx;
  integer bit_idx;
  integer target_bit;
  integer valid_bytes;

  mrtc_axis_width_packer #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .FRAG_W(FRAG_W),
    .DRAIN_APPEND_LOOKAHEAD(DRAIN_APPEND_LOOKAHEAD),
    .REGISTERED_INPUT_QUEUE(REGISTERED_INPUT_QUEUE)
  ) u_dut (
    .clk(clk),
    .rst_n(rst_n),
    .s_frag_valid(s_frag_valid),
    .s_frag_ready(s_frag_ready),
    .s_frag_data(s_frag_data),
    .s_frag_bits(s_frag_bits),
    .s_frag_last(s_frag_last),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid_bytes_minus1(m_axis_tvalid_bytes_minus1),
    .o_busy(o_busy_int),
    .o_done(o_done_int),
    .o_overflow(o_overflow)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ready_state <= (32'h1ACE_0001 ^ AXIS_DATA_W);
      m_axis_tready <= 1'b0;
    end else begin
      ready_state <= (ready_state * 32'd1664525) + 32'd1013904223;
      if (force_output_stall) begin
        m_axis_tready <= 1'b0;
      end else if (ALWAYS_READY) begin
        m_axis_tready <= 1'b1;
      end else begin
        m_axis_tready <= ready_state[0] | ready_state[2] | ready_state[5];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      queue_max_count <= 0;
      queue_push_pop_count <= 0;
    end else if (REGISTERED_INPUT_QUEUE) begin
      if (u_dut.input_queue_count_reg > queue_max_count) begin
        queue_max_count <= u_dut.input_queue_count_reg;
      end
      if (u_dut.input_queue_push && u_dut.input_queue_pop) begin
        queue_push_pop_count <= queue_push_pop_count + 1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      actual_byte_count <= 0;
      actual_beat_count <= 0;
      actual_last_count <= 0;
      actual_final_valid_bytes <= 0;
      hold_active <= 1'b0;
      hold_tdata <= '0;
      hold_tlast <= 1'b0;
      hold_valid_bytes <= '0;
    end else begin
      if (m_axis_tvalid && !m_axis_tready) begin
        if (!hold_active) begin
          hold_active <= 1'b1;
          hold_tdata <= m_axis_tdata;
          hold_tlast <= m_axis_tlast;
          hold_valid_bytes <= m_axis_tvalid_bytes_minus1;
        end else begin
          if (m_axis_tdata !== hold_tdata) begin
            $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d tdata changed while stalled", AXIS_DATA_W);
          end
          if (m_axis_tlast !== hold_tlast) begin
            $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d tlast changed while stalled", AXIS_DATA_W);
          end
          if (m_axis_tvalid_bytes_minus1 !== hold_valid_bytes) begin
            $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d valid_bytes changed while stalled", AXIS_DATA_W);
          end
        end
      end else begin
        hold_active <= 1'b0;
      end

      if (m_axis_tvalid && m_axis_tready) begin
        valid_bytes = m_axis_tlast ? (m_axis_tvalid_bytes_minus1 + 1) : AXIS_BYTES;
        if (valid_bytes < 1 || valid_bytes > AXIS_BYTES) begin
          $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d valid_bytes=%0d", AXIS_DATA_W, valid_bytes);
        end
        if (!m_axis_tlast && (valid_bytes != AXIS_BYTES)) begin
          $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d short non-last beat", AXIS_DATA_W);
        end
        for (byte_idx = 0; byte_idx < valid_bytes; byte_idx = byte_idx + 1) begin
          actual_bytes[actual_byte_count + byte_idx] <= m_axis_tdata[(byte_idx*8) +: 8];
        end
        actual_byte_count <= actual_byte_count + valid_bytes;
        actual_beat_count <= actual_beat_count + 1;
        if (m_axis_tlast) begin
          actual_last_count <= actual_last_count + 1;
          actual_final_valid_bytes <= valid_bytes;
        end
      end
    end
  end

  task automatic clear_expected;
    begin
      expected_bits = 0;
      expected_byte_count = 0;
      expected_beat_count = 0;
      for (byte_idx = 0; byte_idx < 1024; byte_idx = byte_idx + 1) begin
        expected_bytes[byte_idx] = 8'h00;
        actual_bytes[byte_idx] = 8'h00;
      end
      actual_byte_count = 0;
      actual_beat_count = 0;
      actual_last_count = 0;
      actual_final_valid_bytes = 0;
    end
  endtask

  task automatic append_expected(
    input int frag_bits,
    input logic [FRAG_W-1:0] frag_data
  );
    begin
      for (bit_idx = 0; bit_idx < frag_bits; bit_idx = bit_idx + 1) begin
        target_bit = expected_bits + bit_idx;
        expected_bytes[target_bit / 8][7 - (target_bit % 8)] = frag_data[frag_bits - 1 - bit_idx];
      end
      expected_bits = expected_bits + frag_bits;
      expected_byte_count = (expected_bits + 7) / 8;
      expected_beat_count = (expected_byte_count + AXIS_BYTES - 1) / AXIS_BYTES;
    end
  endtask

  task automatic send_fragment(
    input int frag_bits,
    input logic [FRAG_W-1:0] frag_data,
    input logic frag_last
  );
    begin
      if (frag_bits > 0) begin
        append_expected(frag_bits, frag_data);
      end
      @(negedge clk);
      s_frag_valid = 1'b1;
      s_frag_bits = frag_bits;
      s_frag_data = frag_data;
      s_frag_last = frag_last;
      while (!s_frag_ready) begin
        @(negedge clk);
      end
      @(negedge clk);
      s_frag_valid = 1'b0;
      s_frag_bits = '0;
      s_frag_data = '0;
      s_frag_last = 1'b0;
    end
  endtask

  task automatic check_packet(input string pkt_name);
    begin
      wait (o_done_int);
      @(posedge clk);
      if (o_overflow !== 1'b0) begin
        $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d overflow pkt=%s", AXIS_DATA_W, pkt_name);
      end
      if (actual_byte_count != expected_byte_count) begin
        $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d byte_count pkt=%s exp=%0d got=%0d",
               AXIS_DATA_W, pkt_name, expected_byte_count, actual_byte_count);
      end
      if (actual_beat_count != expected_beat_count) begin
        $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d beat_count pkt=%s exp=%0d got=%0d",
               AXIS_DATA_W, pkt_name, expected_beat_count, actual_beat_count);
      end
      if (actual_last_count != 1) begin
        $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d last_count pkt=%s got=%0d",
               AXIS_DATA_W, pkt_name, actual_last_count);
      end
      if (actual_final_valid_bytes != ((expected_byte_count == 0) ? 0 :
          (expected_byte_count - ((expected_beat_count - 1) * AXIS_BYTES)))) begin
        $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d final_valid_bytes pkt=%s exp=%0d got=%0d",
               AXIS_DATA_W, pkt_name,
               (expected_byte_count == 0) ? 0 : (expected_byte_count - ((expected_beat_count - 1) * AXIS_BYTES)),
               actual_final_valid_bytes);
      end
      for (byte_idx = 0; byte_idx < expected_byte_count; byte_idx = byte_idx + 1) begin
        if (actual_bytes[byte_idx] !== expected_bytes[byte_idx]) begin
          $fatal(1, "FAIL tb_mrtc_axis_width_packer AXIS_DATA_W=%0d data pkt=%s byte=%0d exp=%02x got=%02x",
                 AXIS_DATA_W, pkt_name, byte_idx, expected_bytes[byte_idx], actual_bytes[byte_idx]);
        end
      end
      wait (!o_busy_int);
    end
  endtask

  task automatic run_exact_aligned_packet;
    int frag_idx;
    logic [FRAG_W-1:0] frag_word;
    begin
      clear_expected();
      for (frag_idx = 0; frag_idx < (AXIS_BYTES / 4); frag_idx = frag_idx + 1) begin
        frag_word = 32'hA500_0000 ^ (AXIS_DATA_W << 8) ^ frag_idx;
        send_fragment(32, frag_word, (frag_idx == ((AXIS_BYTES / 4) - 1)));
      end
      check_packet("aligned");
    end
  endtask

  task automatic run_misaligned_packet;
    begin
      clear_expected();
      send_fragment(1,  32'b1, 1'b0);
      send_fragment(7,  32'h0000_0055, 1'b0);
      send_fragment(8,  32'h0000_00D2, 1'b0);
      send_fragment(9,  32'h0000_01A5, 1'b0);
      send_fragment(16, 32'h0000_BEEF, 1'b0);
      send_fragment(31, 32'h4ABC_DEF0, 1'b0);
      send_fragment(32, 32'h1357_9BDF, 1'b1);
      check_packet("misaligned");
    end
  endtask

  task automatic run_small_followup_packet;
    begin
      clear_expected();
      send_fragment(9, 32'h0000_0137, 1'b0);
      send_fragment(7, 32'h0000_005B, 1'b1);
      check_packet("followup");
    end
  endtask

  task automatic run_fragment_boundary_packet;
    logic [FRAG_W-1:0] frag_word;
    begin
      clear_expected();
      for (int idx = 0; idx < FRAG_W; idx = idx + 1) begin
        frag_word[idx] = ((idx * 7) + 3) & 1;
      end
      send_fragment(1, frag_word, 1'b0);
      send_fragment(127, frag_word, 1'b0);
      send_fragment(128, frag_word, 1'b0);
      send_fragment(129, frag_word, 1'b0);
      send_fragment(255, frag_word, 1'b0);
      send_fragment(256, frag_word, 1'b1);
      check_packet("frag_boundaries");
    end
  endtask

  task automatic run_zero_length_error;
    begin
      @(negedge clk);
      s_frag_valid = 1'b1;
      s_frag_bits = '0;
      s_frag_data = '0;
      s_frag_last = 1'b0;
      while (!s_frag_ready) begin
        @(negedge clk);
      end
      @(negedge clk);
      s_frag_valid = 1'b0;
      repeat (3) @(posedge clk);
      if (!o_overflow) begin
        $fatal(1, "FAIL tb_mrtc_axis_width_packer FRAG_W=%0d zero-length error not detected", FRAG_W);
      end
    end
  endtask

  task automatic run_consecutive_full_fragments;
    logic [FRAG_W-1:0] frag_word;
    begin
      clear_expected();
      @(negedge clk);
      s_frag_valid = 1'b1;
      for (int frag_idx = 0; frag_idx < 4; frag_idx = frag_idx + 1) begin
        frag_word = '0;
        for (int frag_bit = 0; frag_bit < FRAG_W; frag_bit = frag_bit + 1) begin
          frag_word[frag_bit] = ((frag_idx * 11) + (frag_bit * 7) + 1) & 1;
        end
        s_frag_bits = FRAG_W;
        s_frag_data = frag_word;
        s_frag_last = (frag_idx == 3);
        append_expected(FRAG_W, frag_word);
        #1;
        if (!s_frag_ready) begin
          $fatal(1,
                 "FAIL tb_mrtc_axis_width_packer consecutive fragment stalled index=%0d",
                 frag_idx);
        end
        @(negedge clk);
      end
      s_frag_valid = 1'b0;
      s_frag_bits = '0;
      s_frag_data = '0;
      s_frag_last = 1'b0;
      check_packet("consecutive_128");
      $display("PASS width_packer consecutive_128_fragments");
    end
  endtask

  task automatic run_registered_queue_pressure;
    logic [FRAG_W-1:0] frag_word;
    integer accepted_fragments;
    integer wait_cycles;
    begin
      clear_expected();
      accepted_fragments = 0;
      wait_cycles = 0;
      @(negedge clk);
      force_output_stall = 1'b1;
      s_frag_valid = 1'b1;

      while ((u_dut.input_queue_count_reg != 2) && (wait_cycles < 32)) begin
        frag_word = FRAG_W'(128'h8100_0000_0000_0000_0000_0000_0000_0000 ^
                            accepted_fragments);
        s_frag_bits = FRAG_W;
        s_frag_data = frag_word;
        s_frag_last = 1'b0;
        #1;
        if (s_frag_ready) begin
          append_expected(FRAG_W, frag_word);
          accepted_fragments = accepted_fragments + 1;
        end
        wait_cycles = wait_cycles + 1;
        @(negedge clk);
      end

      if ((u_dut.input_queue_count_reg != 2) || s_frag_ready) begin
        $fatal(1,
               "FAIL registered input queue did not reach full count=%0d ready=%0d accepted=%0d",
               u_dut.input_queue_count_reg, s_frag_ready, accepted_fragments);
      end

      force_output_stall = 1'b0;
      while ((accepted_fragments < 8) && (wait_cycles < 96)) begin
        frag_word = FRAG_W'(128'h8100_0000_0000_0000_0000_0000_0000_0000 ^
                            accepted_fragments);
        s_frag_bits = FRAG_W;
        s_frag_data = frag_word;
        s_frag_last = (accepted_fragments == 7);
        #1;
        if (s_frag_ready) begin
          append_expected(FRAG_W, frag_word);
          accepted_fragments = accepted_fragments + 1;
        end
        wait_cycles = wait_cycles + 1;
        @(negedge clk);
      end
      s_frag_valid = 1'b0;
      s_frag_bits = '0;
      s_frag_data = '0;
      s_frag_last = 1'b0;

      if (accepted_fragments != 8) begin
        $fatal(1, "FAIL registered input queue did not drain accepted=%0d",
               accepted_fragments);
      end
      check_packet("registered_queue_pressure");
      if ((queue_max_count != 2) || (queue_push_pop_count == 0)) begin
        $fatal(1,
               "FAIL registered input queue coverage max=%0d push_pop=%0d",
               queue_max_count, queue_push_pop_count);
      end
      $display("PASS width_packer registered_queue max=%0d push_pop=%0d",
               queue_max_count, queue_push_pop_count);
    end
  endtask

  initial begin
    rst_n = 1'b0;
    s_frag_valid = 1'b0;
    s_frag_data = '0;
    s_frag_bits = '0;
    s_frag_last = 1'b0;
    force_output_stall = 1'b0;
    o_done = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    run_exact_aligned_packet();
    run_misaligned_packet();
    run_small_followup_packet();
    if (DRAIN_APPEND_LOOKAHEAD && (AXIS_DATA_W == 128) && (FRAG_W == 128)) begin
      run_consecutive_full_fragments();
    end
    if (REGISTERED_INPUT_QUEUE && (AXIS_DATA_W == 128) && (FRAG_W == 128)) begin
      run_registered_queue_pressure();
    end
    if (FRAG_W >= 256) begin
      run_fragment_boundary_packet();
      run_zero_length_error();
    end

    o_done = 1'b1;
  end

  initial begin
    repeat (50000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_axis_width_packer AXIS_DATA_W=%0d", AXIS_DATA_W);
  end
endmodule

module tb_mrtc_axis_width_packer;
  logic done_32;
  logic done_64;
  logic done_128;
  logic done_256;
  logic done_128_frag256;
  logic done_128_frag128_lookahead;
  logic done_128_frag128_queue;

  tb_mrtc_axis_width_packer_case #(.AXIS_DATA_W(32)) u_case_32 (.o_done(done_32));
  tb_mrtc_axis_width_packer_case #(.AXIS_DATA_W(64)) u_case_64 (.o_done(done_64));
  tb_mrtc_axis_width_packer_case #(.AXIS_DATA_W(128)) u_case_128 (.o_done(done_128));
  tb_mrtc_axis_width_packer_case #(.AXIS_DATA_W(256)) u_case_256 (.o_done(done_256));
  tb_mrtc_axis_width_packer_case #(
    .AXIS_DATA_W(128),
    .FRAG_W(256)
  ) u_case_128_frag256 (.o_done(done_128_frag256));
  tb_mrtc_axis_width_packer_case #(
    .AXIS_DATA_W(128),
    .FRAG_W(128),
    .DRAIN_APPEND_LOOKAHEAD(1'b1),
    .ALWAYS_READY(1'b1)
  ) u_case_128_frag128_lookahead (.o_done(done_128_frag128_lookahead));
  tb_mrtc_axis_width_packer_case #(
    .AXIS_DATA_W(128),
    .FRAG_W(128),
    .DRAIN_APPEND_LOOKAHEAD(1'b1),
    .REGISTERED_INPUT_QUEUE(1'b1),
    .ALWAYS_READY(1'b1)
  ) u_case_128_frag128_queue (.o_done(done_128_frag128_queue));

  initial begin
    wait (done_32 && done_64 && done_128 && done_256 && done_128_frag256 &&
          done_128_frag128_lookahead && done_128_frag128_queue);
    $display("PASS tb_mrtc_axis_width_packer");
    $finish;
  end
endmodule
