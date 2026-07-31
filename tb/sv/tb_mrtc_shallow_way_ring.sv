`timescale 1ns/1ps

module tb_mrtc_shallow_way_ring #(
  parameter int WAY_COUNT = 3
);
  localparam int AXIS_DATA_W = 128;
  localparam int WAY_DEPTH_WORDS = 32;
  localparam int BLOCK_WORDS = 256;
  localparam int GLOBAL_INDEX_W = $clog2(BLOCK_WORDS);

  logic clk;
  logic rst_n;
  logic i_abort;
  logic i_wr_en;
  logic [GLOBAL_INDEX_W-1:0] i_wr_word_index;
  logic [AXIS_DATA_W-1:0] i_wr_data;
  logic i_rd_req;
  logic [GLOBAL_INDEX_W-1:0] i_rd_word_index;
  logic o_rd_valid;
  logic [GLOBAL_INDEX_W-1:0] o_rd_word_index;
  logic [AXIS_DATA_W-1:0] o_rd_data;
  logic o_way_conflict;
  logic o_ring_error;

  bit stream_monitor_enable;
  bit stream_started;
  int stream_response_count;

  mrtc_shallow_way_ring_slice #(
    .AXIS_DATA_W     (AXIS_DATA_W),
    .WAY_DEPTH_WORDS (WAY_DEPTH_WORDS),
    .WAY_COUNT       (WAY_COUNT),
    .BLOCK_WORDS     (BLOCK_WORDS)
  ) u_dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .i_abort         (i_abort),
    .i_wr_en         (i_wr_en),
    .i_wr_word_index (i_wr_word_index),
    .i_wr_data       (i_wr_data),
    .i_rd_req        (i_rd_req),
    .i_rd_word_index (i_rd_word_index),
    .o_rd_valid      (o_rd_valid),
    .o_rd_word_index (o_rd_word_index),
    .o_rd_data       (o_rd_data),
    .o_way_conflict  (o_way_conflict),
    .o_ring_error    (o_ring_error)
  );

  function automatic logic [AXIS_DATA_W-1:0] word_pattern(input int word_index);
    logic [AXIS_DATA_W-1:0] result;
    begin
      result = '0;
      for (int lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
        result[(lane_idx*32) +: 32] =
          32'h51A7_0000 ^ (word_index * 32'h0001_0201) ^ lane_idx;
      end
      word_pattern = result;
    end
  endfunction

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic drive_idle;
    begin
      i_wr_en         = 1'b0;
      i_wr_word_index = '0;
      i_wr_data       = '0;
      i_rd_req        = 1'b0;
      i_rd_word_index = '0;
    end
  endtask

  task automatic reset_dut;
    begin
      @(negedge clk);
      rst_n   = 1'b0;
      i_abort = 1'b0;
      drive_idle();
      repeat (3) @(posedge clk);
      @(negedge clk);
      rst_n = 1'b1;
      @(posedge clk);
      #1;
      if (o_rd_valid || o_way_conflict || o_ring_error) begin
        $fatal(1, "reset did not clear ring control state WAY_COUNT=%0d", WAY_COUNT);
      end
    end
  endtask

  task automatic write_ok(
    input int word_index,
    input logic [AXIS_DATA_W-1:0] word_data
  );
    begin
      @(negedge clk);
      i_wr_en         = 1'b1;
      i_wr_word_index = GLOBAL_INDEX_W'(word_index);
      i_wr_data       = word_data;
      @(posedge clk);
      #1;
      if (o_way_conflict || o_ring_error) begin
        $fatal(1, "legal write raised an error idx=%0d", word_index);
      end
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1;
      if (o_way_conflict || o_ring_error) begin
        $fatal(1, "write error pulse stretched idx=%0d", word_index);
      end
    end
  endtask

  task automatic write_overwrite_expect(
    input int word_index,
    input logic [AXIS_DATA_W-1:0] word_data
  );
    begin
      @(negedge clk);
      i_wr_en         = 1'b1;
      i_wr_word_index = GLOBAL_INDEX_W'(word_index);
      i_wr_data       = word_data;
      @(posedge clk);
      #1;
      if (!o_ring_error || o_way_conflict || o_rd_valid) begin
        $fatal(1, "overwrite was not rejected idx=%0d", word_index);
      end
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1;
      if (o_ring_error || o_way_conflict) begin
        $fatal(1, "overwrite error pulse stretched idx=%0d", word_index);
      end
    end
  endtask

  task automatic read_ok(
    input int word_index,
    input logic [AXIS_DATA_W-1:0] expected_data
  );
    begin
      @(negedge clk);
      i_rd_req        = 1'b1;
      i_rd_word_index = GLOBAL_INDEX_W'(word_index);
      @(posedge clk);
      #1;
      if (o_rd_valid || o_way_conflict || o_ring_error) begin
        $fatal(1, "read request failed or returned too early idx=%0d", word_index);
      end
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1;
      if (!o_rd_valid) begin
        $fatal(1, "two-cycle response missing idx=%0d", word_index);
      end
      if ((o_rd_word_index !== GLOBAL_INDEX_W'(word_index)) ||
          (o_rd_data !== expected_data)) begin
        $fatal(1, "read response mismatch idx=%0d response_idx=%0d",
               word_index, o_rd_word_index);
      end
      @(posedge clk);
      #1;
      if (o_rd_valid) begin
        $fatal(1, "read response valid stretched idx=%0d", word_index);
      end
    end
  endtask

  task automatic read_underflow_expect(input int word_index);
    begin
      @(negedge clk);
      i_rd_req        = 1'b1;
      i_rd_word_index = GLOBAL_INDEX_W'(word_index);
      @(posedge clk);
      #1;
      if (!o_ring_error || o_way_conflict || o_rd_valid) begin
        $fatal(1, "underflow was not rejected idx=%0d", word_index);
      end
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1;
      if (o_ring_error || o_way_conflict || o_rd_valid) begin
        $fatal(1, "underflow generated a response or stretched error idx=%0d", word_index);
      end
    end
  endtask

  task automatic conflict_expect(
    input int write_index,
    input int read_index
  );
    begin
      @(negedge clk);
      i_wr_en         = 1'b1;
      i_wr_word_index = GLOBAL_INDEX_W'(write_index);
      i_wr_data       = word_pattern(write_index);
      i_rd_req        = 1'b1;
      i_rd_word_index = GLOBAL_INDEX_W'(read_index);
      @(posedge clk);
      #1;
      if (!o_way_conflict || o_ring_error || o_rd_valid) begin
        $fatal(1, "same-way conflict did not cancel both commands wr=%0d rd=%0d",
               write_index, read_index);
      end
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1;
      if (o_way_conflict || o_ring_error || o_rd_valid) begin
        $fatal(1, "conflict generated a response or stretched error");
      end
    end
  endtask

  always @(posedge clk) begin
    #2;
    if (stream_monitor_enable && rst_n) begin
      if (o_ring_error || o_way_conflict) begin
        $fatal(1, "streaming wrap test observed a ring error WAY_COUNT=%0d", WAY_COUNT);
      end
      if (o_rd_valid) begin
        if (o_rd_word_index !== GLOBAL_INDEX_W'(stream_response_count)) begin
          $fatal(1, "response reordered expected=%0d actual=%0d WAY_COUNT=%0d",
                 stream_response_count, o_rd_word_index, WAY_COUNT);
        end
        if (o_rd_data !== word_pattern(stream_response_count)) begin
          $fatal(1, "response data mismatch idx=%0d WAY_COUNT=%0d",
                 stream_response_count, WAY_COUNT);
        end
        stream_started = 1'b1;
        stream_response_count = stream_response_count + 1;
      end else if (stream_started && (stream_response_count < BLOCK_WORDS)) begin
        $fatal(1, "response gap after stream start idx=%0d WAY_COUNT=%0d",
               stream_response_count, WAY_COUNT);
      end
    end
  end

  initial begin
    int word_index;

    rst_n = 1'b0;
    i_abort = 1'b0;
    drive_idle();
    stream_monitor_enable = 1'b0;
    stream_started = 1'b0;
    stream_response_count = 0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    read_underflow_expect(0);

    write_ok(0, word_pattern(0));
    read_ok(0, word_pattern(0));

    write_ok(1, word_pattern(1));
    write_overwrite_expect(1, ~word_pattern(1));
    read_ok(1, word_pattern(1));

    write_ok(2, word_pattern(2));
    conflict_expect(3, 2);
    read_underflow_expect(3);
    read_ok(2, word_pattern(2));

    // Abort clears old validity and the pending response while admitting the
    // next block's first write on that same edge.
    write_ok(4, word_pattern(4));
    write_ok(5, word_pattern(5));
    @(negedge clk);
    i_rd_req        = 1'b1;
    i_rd_word_index = GLOBAL_INDEX_W'(4);
    @(posedge clk);
    #1;
    if (o_rd_valid || o_ring_error || o_way_conflict) begin
      $fatal(1, "abort test read request was not accepted cleanly");
    end
    @(negedge clk);
    drive_idle();
    i_abort         = 1'b1;
    i_wr_en         = 1'b1;
    i_wr_word_index = GLOBAL_INDEX_W'(0);
    i_wr_data       = word_pattern(0);
    @(posedge clk);
    #1;
    if (o_rd_valid || o_ring_error || o_way_conflict) begin
      $fatal(1, "abort edge did not flush response or admit clean first write");
    end
    @(negedge clk);
    i_abort = 1'b0;
    drive_idle();
    @(posedge clk);
    #1;
    read_underflow_expect(5);
    read_ok(0, word_pattern(0));

    write_ok(8, word_pattern(8));
    write_ok(9, word_pattern(9));
    @(negedge clk);
    i_rd_req        = 1'b1;
    i_rd_word_index = GLOBAL_INDEX_W'(8);
    @(posedge clk);
    #1;
    if (o_rd_valid || o_ring_error || o_way_conflict) begin
      $fatal(1, "reset test read request was not accepted cleanly");
    end
    @(negedge clk);
    drive_idle();
    rst_n = 1'b0;
    #1;
    if (o_rd_valid || o_ring_error || o_way_conflict) begin
      $fatal(1, "reset did not asynchronously flush pending state");
    end
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    #1;
    read_underflow_expect(9);

    reset_dut();
    stream_monitor_enable = 1'b1;
    stream_started = 1'b0;
    stream_response_count = 0;

    for (word_index = 0; word_index < WAY_DEPTH_WORDS; word_index = word_index + 1) begin
      @(negedge clk);
      i_wr_en         = 1'b1;
      i_wr_word_index = GLOBAL_INDEX_W'(word_index);
      i_wr_data       = word_pattern(word_index);
      i_rd_req        = 1'b0;
    end

    for (word_index = WAY_DEPTH_WORDS; word_index < BLOCK_WORDS; word_index = word_index + 1) begin
      @(negedge clk);
      i_wr_en         = 1'b1;
      i_wr_word_index = GLOBAL_INDEX_W'(word_index);
      i_wr_data       = word_pattern(word_index);
      i_rd_req        = 1'b1;
      i_rd_word_index = GLOBAL_INDEX_W'(word_index - WAY_DEPTH_WORDS);
    end

    for (word_index = BLOCK_WORDS - WAY_DEPTH_WORDS;
         word_index < BLOCK_WORDS;
         word_index = word_index + 1) begin
      @(negedge clk);
      i_wr_en         = 1'b0;
      i_wr_word_index = '0;
      i_wr_data       = '0;
      i_rd_req        = 1'b1;
      i_rd_word_index = GLOBAL_INDEX_W'(word_index);
    end

    @(negedge clk);
    drive_idle();
    wait (stream_response_count == BLOCK_WORDS);
    @(posedge clk);
    #3;
    stream_monitor_enable = 1'b0;

    if ((stream_response_count != BLOCK_WORDS) || o_rd_valid) begin
      $fatal(1, "stream summary mismatch ways=%0d responses=%0d",
             WAY_COUNT, stream_response_count);
    end
    read_underflow_expect(0);

    $display("PASS tb_mrtc_shallow_way_ring WAY_COUNT=%0d", WAY_COUNT);
    $finish;
  end

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "TIMEOUT tb_mrtc_shallow_way_ring WAY_COUNT=%0d", WAY_COUNT);
  end
endmodule
