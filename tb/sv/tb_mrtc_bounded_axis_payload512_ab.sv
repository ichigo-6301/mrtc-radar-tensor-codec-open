`timescale 1ns/1ps

module tb_mrtc_bounded_axis_payload512_ab;
  import mrtc_pkg::*;

  localparam int AXIS_DATA_W = 128;
  localparam int NUM_ENGINES = 2;
  localparam int BLOCK_COUNT = 2;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;
  localparam int MEM_WORDS = BLOCK_COUNT * BLOCK_WORDS;
  localparam int MAX_PACKET_BEATS = MRTC_MAX_OUTPUT_BYTES / (AXIS_DATA_W / 8);

  logic clk;
  logic rst_n;
  logic clear_status;

  logic direct_desc_valid;
  logic direct_desc_ready;
  logic base_desc_valid;
  logic base_desc_ready;
  logic [15:0] direct_desc_block_id;
  logic [15:0] direct_desc_range;
  logic direct_desc_last;
  logic [15:0] base_desc_block_id;
  logic [15:0] base_desc_range;
  logic base_desc_last;

  logic [127:0] raw_tdata;
  logic raw_tvalid;
  logic raw_tready;
  logic raw_tlast;

  logic [127:0] direct_tdata;
  logic direct_tvalid;
  logic direct_tlast;
  logic [7:0] direct_tuser;
  logic [31:0] direct_error;

  logic [127:0] base_tdata;
  logic base_tvalid;
  logic base_tlast;
  logic [7:0] base_tuser;
  logic [31:0] base_error;

  logic [NUM_ENGINES-1:0] mem_rd_req;
  logic [NUM_ENGINES-1:0][63:0] mem_rd_addr;
  logic [NUM_ENGINES-1:0][15:0] mem_rd_len;
  logic [NUM_ENGINES-1:0] mem_rd_ready;
  logic [NUM_ENGINES-1:0] mem_rd_data_valid;
  logic [NUM_ENGINES-1:0][127:0] mem_rd_data;
  logic [NUM_ENGINES-1:0] mem_rd_last;

  logic [127:0] direct_packet [0:BLOCK_COUNT-1][0:MAX_PACKET_BEATS-1];
  logic [7:0] direct_user [0:BLOCK_COUNT-1][0:MAX_PACKET_BEATS-1];
  logic direct_last [0:BLOCK_COUNT-1][0:MAX_PACKET_BEATS-1];
  integer direct_beats [0:BLOCK_COUNT-1];
  integer direct_packet_count;
  integer direct_beat_index;

  logic [127:0] base_packet [0:BLOCK_COUNT-1][0:MAX_PACKET_BEATS-1];
  logic [7:0] base_user [0:BLOCK_COUNT-1][0:MAX_PACKET_BEATS-1];
  logic base_last [0:BLOCK_COUNT-1][0:MAX_PACKET_BEATS-1];
  integer base_beats [0:BLOCK_COUNT-1];
  integer base_packet_count;
  integer base_beat_index;

  initial clk = 1'b0;
  always #2.5 clk = ~clk;

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
        if (block_index == 0) begin
          i_value = 0;
          q_value = 0;
        end else begin
          i_value = ((sample_index * 5 + 3) % 15) - 7;
          q_value = ((sample_index * 7 + 1) % 13) - 6;
        end
        value[(lane * 32) +: 16] = 16'(i_value);
        value[(lane * 32) + 16 +: 16] = 16'(q_value);
      end
      block_word = value;
    end
  endfunction

  task automatic load_memory;
    begin
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        for (int word_index = 0; word_index < BLOCK_WORDS; word_index = word_index + 1) begin
          u_memory.load_word((block_index * BLOCK_WORDS) + word_index,
                             block_word(block_index, word_index));
        end
      end
    end
  endtask

  task automatic drive_direct_descriptors;
    begin
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        @(negedge clk);
        direct_desc_block_id = 16'(block_index);
        direct_desc_range = 16'(16'h5000 + block_index);
        direct_desc_last = (block_index == (BLOCK_COUNT - 1));
        direct_desc_valid = 1'b1;
        do begin
          @(posedge clk);
        end while (!direct_desc_ready);
      end
      @(negedge clk);
      direct_desc_valid = 1'b0;
    end
  endtask

  task automatic drive_base_descriptors;
    begin
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        @(negedge clk);
        base_desc_block_id = 16'(block_index);
        base_desc_range = 16'(16'h5000 + block_index);
        base_desc_last = (block_index == (BLOCK_COUNT - 1));
        base_desc_valid = 1'b1;
        do begin
          @(posedge clk);
        end while (!base_desc_ready);
      end
      @(negedge clk);
      base_desc_valid = 1'b0;
    end
  endtask

  task automatic drive_direct_input;
    begin
      wait (u_direct.stat_desc_accepted >= 2);
      for (int block_index = 0; block_index < BLOCK_COUNT; block_index = block_index + 1) begin
        for (int word_index = 0; word_index < BLOCK_WORDS; word_index = word_index + 1) begin
          @(negedge clk);
          raw_tdata = block_word(block_index, word_index);
          raw_tvalid = 1'b1;
          raw_tlast = (word_index == (BLOCK_WORDS - 1));
          @(posedge clk);
          if (!raw_tready) begin
            $fatal(1, "A/B direct input stalled block=%0d word=%0d error=%0d",
                   block_index, word_index, direct_error);
          end
        end
      end
      @(negedge clk);
      raw_tdata = '0;
      raw_tvalid = 1'b0;
      raw_tlast = 1'b0;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      direct_packet_count <= 0;
      direct_beat_index <= 0;
      base_packet_count <= 0;
      base_beat_index <= 0;
      for (int packet = 0; packet < BLOCK_COUNT; packet = packet + 1) begin
        direct_beats[packet] <= 0;
        base_beats[packet] <= 0;
      end
    end else begin
      if (direct_tvalid) begin
        direct_packet[direct_packet_count][direct_beat_index] <= direct_tdata;
        direct_user[direct_packet_count][direct_beat_index] <= direct_tuser;
        direct_last[direct_packet_count][direct_beat_index] <= direct_tlast;
        if (direct_tlast) begin
          direct_beats[direct_packet_count] <= direct_beat_index + 1;
          direct_packet_count <= direct_packet_count + 1;
          direct_beat_index <= 0;
        end else begin
          direct_beat_index <= direct_beat_index + 1;
        end
      end
      if (base_tvalid) begin
        base_packet[base_packet_count][base_beat_index] <= base_tdata;
        base_user[base_packet_count][base_beat_index] <= base_tuser;
        base_last[base_packet_count][base_beat_index] <= base_tlast;
        if (base_tlast) begin
          base_beats[base_packet_count] <= base_beat_index + 1;
          base_packet_count <= base_packet_count + 1;
          base_beat_index <= 0;
        end else begin
          base_beat_index <= base_beat_index + 1;
        end
      end
    end
  end

  initial begin
    rst_n = 1'b0;
    clear_status = 1'b0;
    direct_desc_valid = 1'b0;
    base_desc_valid = 1'b0;
    direct_desc_block_id = '0;
    direct_desc_range = '0;
    direct_desc_last = 1'b0;
    base_desc_block_id = '0;
    base_desc_range = '0;
    base_desc_last = 1'b0;
    raw_tdata = '0;
    raw_tvalid = 1'b0;
    raw_tlast = 1'b0;
    load_memory();
    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    fork
      drive_direct_descriptors();
      drive_base_descriptors();
      drive_direct_input();
    join

    for (int wait_cycle = 0;
         (wait_cycle < 100000) &&
         ((direct_packet_count < BLOCK_COUNT) || (base_packet_count < BLOCK_COUNT));
         wait_cycle = wait_cycle + 1) begin
      @(posedge clk);
    end
    repeat (4) @(posedge clk);

    if ((direct_error != MRTC_ERR_NONE) || (base_error != MRTC_ERR_NONE) ||
        (direct_packet_count != BLOCK_COUNT) ||
        (base_packet_count != BLOCK_COUNT)) begin
      $fatal(1,
             "A/B completion failed direct_error=%0d base_error=%0d packets=%0d/%0d",
             direct_error, base_error, direct_packet_count, base_packet_count);
    end
    for (int packet = 0; packet < BLOCK_COUNT; packet = packet + 1) begin
      if (direct_beats[packet] != base_beats[packet]) begin
        $fatal(1, "A/B beat count mismatch packet=%0d direct=%0d base=%0d",
               packet, direct_beats[packet], base_beats[packet]);
      end
      for (int beat = 0; beat < direct_beats[packet]; beat = beat + 1) begin
        if ((direct_packet[packet][beat] !== base_packet[packet][beat]) ||
            (direct_user[packet][beat] !== base_user[packet][beat]) ||
            (direct_last[packet][beat] !== base_last[packet][beat])) begin
          $fatal(1,
                 "A/B packet mismatch packet=%0d beat=%0d direct=%032x/%02x/%0d base=%032x/%02x/%0d",
                 packet, beat,
                 direct_packet[packet][beat], direct_user[packet][beat],
                 direct_last[packet][beat], base_packet[packet][beat],
                 base_user[packet][beat], base_last[packet][beat]);
        end
      end
      $display("PASS direct_payload512_ab packet=%0d beats=%0d",
               packet, direct_beats[packet]);
    end

    $display("PASS tb_mrtc_bounded_axis_payload512_ab");
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1,
           "TIMEOUT tb_mrtc_bounded_axis_payload512_ab direct=%0d base=%0d errors=%0d/%0d",
           direct_packet_count, base_packet_count, direct_error, base_error);
  end

  mrtc_rdtc_bounded_axis_multiengine_wrapper u_direct (
    .clk,
    .rst_n,
    .i_clear_status              (clear_status),
    .s_desc_valid                (direct_desc_valid),
    .s_desc_ready                (direct_desc_ready),
    .s_desc_block_id             (direct_desc_block_id),
    .s_desc_block_range_start    (direct_desc_range),
    .s_desc_frame_id             (16'hab01),
    .s_desc_codec_mode           (MRTC_CODEC_ZERO_RICE),
    .s_desc_rice_mode            (MRTC_RICE_BLOCK_ADAPTIVE_K),
    .s_desc_fixed_k              (4'd0),
    .s_desc_tensor_spatial_size  (16'd1),
    .s_desc_tensor_doppler_size  (16'd64),
    .s_desc_tensor_range_size    (16'd16),
    .s_desc_last_block           (direct_desc_last),
    .s_axis_raw_tdata            (raw_tdata),
    .s_axis_raw_tvalid           (raw_tvalid),
    .s_axis_raw_tready           (raw_tready),
    .s_axis_raw_tlast            (raw_tlast),
    .m_axis_comp_tdata           (direct_tdata),
    .m_axis_comp_tvalid          (direct_tvalid),
    .m_axis_comp_tready          (1'b1),
    .m_axis_comp_tlast           (direct_tlast),
    .m_axis_comp_tuser           (direct_tuser),
    .stat_busy                   (),
    .stat_done                   (),
    .stat_num_blocks             (),
    .stat_raw_bytes              (),
    .stat_comp_bytes             (),
    .stat_error                  (direct_error),
    .stat_stall_input_cycles     (),
    .stat_stall_output_cycles    (),
    .stat_desc_accepted          (),
    .stat_input_blocks           (),
    .stat_output_packets         (),
    .stat_output_fifo_level      (),
    .stat_output_fifo_max_level  ()
  );

  mrtc_rdtc_ddr_multiengine_wrapper #(
    .AXIS_DATA_W                 (AXIS_DATA_W),
    .NUM_ENGINES                 (NUM_ENGINES),
    .ENGINE_BOUNDED_WAY_COUNT    (4),
    .ENGINE_BOUNDED_PAYLOAD_DEPTH(512),
    .DDR_READ_LATENCY            (4),
    .DDR_BURST_BEATS             (256),
    .MAX_OUTSTANDING             (1),
    .FEED_GAP_CYCLES             (0),
    .OUTPUT_IN_ORDER             (1'b1),
    .PREFIX_SAMPLES              (128)
  ) u_baseline (
    .clk,
    .rst_n,
    .i_clear_status             (clear_status),
    .s_desc_valid               (base_desc_valid),
    .s_desc_ready               (base_desc_ready),
    .s_desc_raw_addr            (64'(base_desc_block_id * MRTC_RAW_BYTES)),
    .s_desc_block_id            (base_desc_block_id),
    .s_desc_block_range_start   (base_desc_range),
    .s_desc_frame_id            (16'hab01),
    .s_desc_codec_mode          (MRTC_CODEC_ZERO_RICE),
    .s_desc_rice_mode           (MRTC_RICE_BLOCK_ADAPTIVE_K),
    .s_desc_fixed_k             (4'd0),
    .s_desc_tensor_spatial_size (16'd1),
    .s_desc_tensor_doppler_size (16'd64),
    .s_desc_tensor_range_size   (16'd16),
    .s_desc_last_block          (base_desc_last),
    .o_mem_rd_req               (mem_rd_req),
    .o_mem_rd_addr              (mem_rd_addr),
    .o_mem_rd_len               (mem_rd_len),
    .i_mem_rd_ready             (mem_rd_ready),
    .i_mem_rd_data_valid        (mem_rd_data_valid),
    .i_mem_rd_data              (mem_rd_data),
    .i_mem_rd_last              (mem_rd_last),
    .m_axis_comp_tdata          (base_tdata),
    .m_axis_comp_tvalid         (base_tvalid),
    .m_axis_comp_tready         (1'b1),
    .m_axis_comp_tlast          (base_tlast),
    .m_axis_comp_tuser          (base_tuser),
    .stat_busy                  (),
    .stat_done                  (),
    .stat_num_blocks            (),
    .stat_raw_bytes             (),
    .stat_comp_bytes            (),
    .stat_error                 (base_error),
    .stat_stall_input_cycles    (),
    .stat_stall_output_cycles   ()
  );

  mrtc_ddr_raw_block_memory_model #(
    .AXIS_DATA_W                    (AXIS_DATA_W),
    .NUM_PORTS                      (NUM_ENGINES),
    .MEM_WORDS                      (MEM_WORDS),
    .ADDR_W                         (64),
    .READ_LATENCY                   (4),
    .BURST_BEATS                    (256),
    .MAX_OUTSTANDING                (1),
    .BANDWIDTH_LIMIT_BEATS_PER_CYCLE(0)
  ) u_memory (
    .clk,
    .rst_n,
    .s_rd_req        (mem_rd_req),
    .s_rd_addr       (mem_rd_addr),
    .s_rd_len        (mem_rd_len),
    .s_rd_ready      (mem_rd_ready),
    .m_rd_data_valid (mem_rd_data_valid),
    .m_rd_data       (mem_rd_data),
    .m_rd_last       (mem_rd_last)
  );
endmodule
