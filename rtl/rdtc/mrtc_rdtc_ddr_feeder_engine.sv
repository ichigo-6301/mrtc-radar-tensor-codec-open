module mrtc_rdtc_ddr_feeder_engine #(
  parameter int AXIS_DATA_W = 128,
  parameter int RAW_BYTES = 4096,
  parameter int RAW_BEATS = 256,
  parameter int DDR_ADDR_W = 64,
  parameter int DDR_READ_LATENCY = 32,
  parameter int DDR_BURST_BEATS = 16,
  parameter int MAX_OUTSTANDING = 4,
  parameter int FEED_GAP_CYCLES = 0
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,

  input  logic                   i_desc_valid,
  output logic                   o_desc_ready,
  input  logic [DDR_ADDR_W-1:0]  i_desc_raw_addr,
  input  logic [15:0]            i_desc_block_id,
  input  logic [15:0]            i_desc_block_range_start,
  input  logic [15:0]            i_desc_frame_id,
  input  logic [7:0]             i_desc_codec_mode,
  input  logic [7:0]             i_desc_rice_mode,
  input  logic [3:0]             i_desc_fixed_k,
  input  logic [15:0]            i_desc_tensor_spatial_size,
  input  logic [15:0]            i_desc_tensor_doppler_size,
  input  logic [15:0]            i_desc_tensor_range_size,
  input  logic                   i_desc_last_block,

  output logic                   o_mem_rd_req,
  output logic [DDR_ADDR_W-1:0]  o_mem_rd_addr,
  output logic [15:0]            o_mem_rd_len,
  input  logic                   i_mem_rd_ready,
  input  logic                   i_mem_rd_data_valid,
  input  logic [AXIS_DATA_W-1:0] i_mem_rd_data,
  input  logic                   i_mem_rd_last,

  output logic [AXIS_DATA_W-1:0] m_axis_raw_tdata,
  output logic                   m_axis_raw_tvalid,
  input  logic                   m_axis_raw_tready,
  output logic                   m_axis_raw_tlast,
  output logic [7:0]             m_axis_raw_tuser,

  output logic                   o_busy,
  output logic                   o_done,
  output logic                   o_feed_active,
  output logic [31:0]            o_mem_wait_cycles,
  output logic [31:0]            o_axis_stall_cycles,
  output logic [31:0]            o_blocks_fed,
  output logic [31:0]            o_bursts_issued,
  output logic [31:0]            o_beats_streamed,
  output logic [31:0]            o_desc_block_id,
  output logic [15:0]            o_desc_block_range_start,
  output logic [15:0]            o_desc_frame_id,
  output logic [7:0]             o_desc_codec_mode,
  output logic [7:0]             o_desc_rice_mode,
  output logic [3:0]             o_desc_fixed_k,
  output logic [15:0]            o_desc_tensor_spatial_size,
  output logic [15:0]            o_desc_tensor_doppler_size,
  output logic [15:0]            o_desc_tensor_range_size,
  output logic                   o_desc_last_block
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int FIFO_DEPTH = RAW_BEATS;
  localparam int FIFO_IDX_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
  localparam int COUNT_W = $clog2(FIFO_DEPTH + 1);
  localparam int BEAT_COUNT_W = (RAW_BEATS <= 1) ? 1 : $clog2(RAW_BEATS + 1);
  localparam int BURST_COUNT_W =
    (DDR_BURST_BEATS <= 1) ? 1 : $clog2(DDR_BURST_BEATS + 1);
  localparam int OUTSTANDING_COUNT_W =
    (MAX_OUTSTANDING <= 1) ? 1 : $clog2(MAX_OUTSTANDING + 1);
  localparam int GAP_COUNT_W =
    (FEED_GAP_CYCLES <= 0) ? 1 : $clog2(FEED_GAP_CYCLES + 1);

  typedef enum logic [0:0] {
    ST_IDLE,
    ST_ACTIVE
  } state_t;

  state_t state_reg;

  logic [AXIS_DATA_W-1:0] fifo_data [0:FIFO_DEPTH-1];
  logic [FIFO_IDX_W-1:0]  fifo_wr_ptr_reg;
  logic [FIFO_IDX_W-1:0]  fifo_rd_ptr_reg;
  logic [COUNT_W-1:0]     fifo_count_reg;

  logic [DDR_ADDR_W-1:0] raw_addr_reg;
  logic [15:0]           block_id_reg;
  logic [15:0]           block_range_start_reg;
  logic [15:0]           frame_id_reg;
  logic [7:0]            codec_mode_reg;
  logic [7:0]            rice_mode_reg;
  logic [3:0]            fixed_k_reg;
  logic [15:0]           tensor_spatial_size_reg;
  logic [15:0]           tensor_doppler_size_reg;
  logic [15:0]           tensor_range_size_reg;
  logic                  last_block_reg;

  logic [OUTSTANDING_COUNT_W-1:0] outstanding_reads_reg;
  logic [BEAT_COUNT_W-1:0]       issue_addr_word_reg;
  logic [BEAT_COUNT_W-1:0]       beats_requested_reg;
  logic [BEAT_COUNT_W-1:0]       beats_received_reg;
  logic [BEAT_COUNT_W-1:0]       beats_sent_reg;
  logic [GAP_COUNT_W-1:0]        gap_count_reg;
  logic [BEAT_COUNT_W-1:0]       remaining_beats;
  logic [BURST_COUNT_W-1:0]      burst_len_words;
  logic [COUNT_W-1:0]            fifo_space_now;

  assign o_desc_ready = (state_reg == ST_IDLE);
  assign o_busy = (state_reg != ST_IDLE);
  assign o_feed_active = (state_reg == ST_ACTIVE);
  assign o_desc_block_id = {16'd0, block_id_reg};
  assign o_desc_block_range_start = block_range_start_reg;
  assign o_desc_frame_id = frame_id_reg;
  assign o_desc_codec_mode = codec_mode_reg;
  assign o_desc_rice_mode = rice_mode_reg;
  assign o_desc_fixed_k = fixed_k_reg;
  assign o_desc_tensor_spatial_size = tensor_spatial_size_reg;
  assign o_desc_tensor_doppler_size = tensor_doppler_size_reg;
  assign o_desc_tensor_range_size = tensor_range_size_reg;
  assign o_desc_last_block = last_block_reg;

  assign m_axis_raw_tvalid =
    (fifo_count_reg != COUNT_W'(0)) &&
    (state_reg == ST_ACTIVE) &&
    (gap_count_reg == GAP_COUNT_W'(0));
  assign m_axis_raw_tdata = fifo_data[fifo_rd_ptr_reg];
  assign m_axis_raw_tlast =
    (beats_sent_reg == BEAT_COUNT_W'(RAW_BEATS - 1)) &&
    (fifo_count_reg != COUNT_W'(0));
  assign m_axis_raw_tuser = {
    4'd0,
    last_block_reg,
    codec_mode_reg[1:0],
    1'b0
  };

  always_comb begin
    remaining_beats = BEAT_COUNT_W'(RAW_BEATS) - issue_addr_word_reg;
    burst_len_words = BURST_COUNT_W'(DDR_BURST_BEATS);
    if (remaining_beats < BEAT_COUNT_W'(DDR_BURST_BEATS)) begin
      burst_len_words = BURST_COUNT_W'(remaining_beats);
    end
    fifo_space_now = COUNT_W'(FIFO_DEPTH) - fifo_count_reg;
    o_mem_rd_req = 1'b0;
    o_mem_rd_addr = raw_addr_reg + DDR_ADDR_W'(issue_addr_word_reg * AXIS_BYTES);
    o_mem_rd_len = 16'(burst_len_words);
    if ((state_reg == ST_ACTIVE) &&
        (issue_addr_word_reg < BEAT_COUNT_W'(RAW_BEATS)) &&
        (outstanding_reads_reg < OUTSTANDING_COUNT_W'(MAX_OUTSTANDING)) &&
        (fifo_space_now >= COUNT_W'(burst_len_words))) begin
      o_mem_rd_req = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    logic do_pop;
    logic do_push;
    logic issue_fire;
    logic burst_complete;
    logic final_pop;
    logic mem_wait_this_cycle;
    if (!rst_n) begin
      state_reg <= ST_IDLE;
      raw_addr_reg <= '0;
      block_id_reg <= '0;
      block_range_start_reg <= '0;
      frame_id_reg <= '0;
      codec_mode_reg <= '0;
      rice_mode_reg <= '0;
      fixed_k_reg <= '0;
      tensor_spatial_size_reg <= '0;
      tensor_doppler_size_reg <= '0;
      tensor_range_size_reg <= '0;
      last_block_reg <= 1'b0;
      fifo_wr_ptr_reg <= '0;
      fifo_rd_ptr_reg <= '0;
      fifo_count_reg <= '0;
      outstanding_reads_reg <= 0;
      issue_addr_word_reg <= 0;
      beats_requested_reg <= 0;
      beats_received_reg <= 0;
      beats_sent_reg <= 0;
      gap_count_reg <= 0;
      o_done <= 1'b0;
      o_mem_wait_cycles <= 32'd0;
      o_axis_stall_cycles <= 32'd0;
      o_blocks_fed <= 32'd0;
      o_bursts_issued <= 32'd0;
      o_beats_streamed <= 32'd0;
    end else begin
      o_done <= 1'b0;
      do_push = i_mem_rd_data_valid;
      do_pop = m_axis_raw_tvalid && m_axis_raw_tready;
      issue_fire = (state_reg == ST_ACTIVE) && o_mem_rd_req && i_mem_rd_ready;
      burst_complete = do_push && i_mem_rd_last;
      final_pop = do_pop && (beats_sent_reg == BEAT_COUNT_W'(RAW_BEATS - 1));

      if (i_clear_status) begin
        o_mem_wait_cycles <= 32'd0;
        o_axis_stall_cycles <= 32'd0;
        o_blocks_fed <= 32'd0;
        o_bursts_issued <= 32'd0;
        o_beats_streamed <= 32'd0;
      end

      // The memory response itself owns the wide data-register write enable.
      // Pointer and occupancy ownership remain guarded by ST_ACTIVE below.
      if (do_push) begin
        fifo_data[fifo_wr_ptr_reg] <= i_mem_rd_data;
      end

      case (state_reg)
        ST_IDLE: begin
          fifo_wr_ptr_reg <= '0;
          fifo_rd_ptr_reg <= '0;
          fifo_count_reg <= '0;
          outstanding_reads_reg <= 0;
          issue_addr_word_reg <= 0;
          beats_requested_reg <= 0;
          beats_received_reg <= 0;
          beats_sent_reg <= 0;
          gap_count_reg <= 0;
          if (i_desc_valid) begin
            raw_addr_reg <= i_desc_raw_addr;
            block_id_reg <= i_desc_block_id;
            block_range_start_reg <= i_desc_block_range_start;
            frame_id_reg <= i_desc_frame_id;
            codec_mode_reg <= i_desc_codec_mode;
            rice_mode_reg <= i_desc_rice_mode;
            fixed_k_reg <= i_desc_fixed_k;
            tensor_spatial_size_reg <= i_desc_tensor_spatial_size;
            tensor_doppler_size_reg <= i_desc_tensor_doppler_size;
            tensor_range_size_reg <= i_desc_tensor_range_size;
            last_block_reg <= i_desc_last_block;
            state_reg <= ST_ACTIVE;
          end
        end

        ST_ACTIVE: begin
          if (do_push && !do_pop) begin
            fifo_count_reg <= fifo_count_reg + COUNT_W'(1);
          end else if (!do_push && do_pop) begin
            fifo_count_reg <= fifo_count_reg - COUNT_W'(1);
          end

          if (do_push) begin
            if (fifo_wr_ptr_reg == FIFO_IDX_W'(FIFO_DEPTH - 1)) begin
              fifo_wr_ptr_reg <= '0;
            end else begin
              fifo_wr_ptr_reg <= fifo_wr_ptr_reg + FIFO_IDX_W'(1);
            end
            beats_received_reg <= beats_received_reg + BEAT_COUNT_W'(1);
          end

          if (!i_clear_status && m_axis_raw_tvalid && !m_axis_raw_tready) begin
            o_axis_stall_cycles <= o_axis_stall_cycles + 32'd1;
          end

          if (do_pop) begin
            if (fifo_rd_ptr_reg == FIFO_IDX_W'(FIFO_DEPTH - 1)) begin
              fifo_rd_ptr_reg <= '0;
            end else begin
              fifo_rd_ptr_reg <= fifo_rd_ptr_reg + FIFO_IDX_W'(1);
            end
            beats_sent_reg <= beats_sent_reg + BEAT_COUNT_W'(1);
            if (!i_clear_status) begin
              o_beats_streamed <= o_beats_streamed + 32'd1;
            end
            if (final_pop) begin
              gap_count_reg <= '0;
            end else if (FEED_GAP_CYCLES > 0) begin
              gap_count_reg <= GAP_COUNT_W'(FEED_GAP_CYCLES);
            end else begin
              gap_count_reg <= '0;
            end
          end else if (gap_count_reg != GAP_COUNT_W'(0)) begin
            gap_count_reg <= gap_count_reg - GAP_COUNT_W'(1);
          end

          if (issue_fire) begin
            issue_addr_word_reg <=
              issue_addr_word_reg + BEAT_COUNT_W'(burst_len_words);
            beats_requested_reg <=
              beats_requested_reg + BEAT_COUNT_W'(burst_len_words);
            if (!i_clear_status) begin
              o_bursts_issued <= o_bursts_issued + 32'd1;
            end
          end

          case ({issue_fire, burst_complete})
            2'b10: begin
              outstanding_reads_reg <=
                outstanding_reads_reg + OUTSTANDING_COUNT_W'(1);
            end
            2'b01: begin
              if (outstanding_reads_reg != OUTSTANDING_COUNT_W'(0)) begin
                outstanding_reads_reg <=
                  outstanding_reads_reg - OUTSTANDING_COUNT_W'(1);
              end
            end
            default: begin
            end
          endcase

          mem_wait_this_cycle = 1'b0;
          if ((issue_addr_word_reg < BEAT_COUNT_W'(RAW_BEATS)) && !issue_fire) begin
            if ((outstanding_reads_reg >= OUTSTANDING_COUNT_W'(MAX_OUTSTANDING)) ||
                (o_mem_rd_req && !i_mem_rd_ready) ||
                (!o_mem_rd_req && (fifo_space_now < COUNT_W'(burst_len_words)))) begin
              mem_wait_this_cycle = 1'b1;
            end
          end
          if ((beats_received_reg < BEAT_COUNT_W'(RAW_BEATS)) &&
              !do_push &&
              (fifo_count_reg == COUNT_W'(0))) begin
            mem_wait_this_cycle = 1'b1;
          end
          if (!i_clear_status && mem_wait_this_cycle) begin
            o_mem_wait_cycles <= o_mem_wait_cycles + 32'd1;
          end

          if (final_pop) begin
            state_reg <= ST_IDLE;
            o_done <= 1'b1;
            if (!i_clear_status) begin
              o_blocks_fed <= o_blocks_fed + 32'd1;
            end
          end
        end

        default: begin
          state_reg <= ST_IDLE;
        end
      endcase

`ifndef SYNTHESIS
      if ((state_reg == ST_IDLE) && i_mem_rd_data_valid) begin
        $fatal(1, "DDR feeder received a memory response while idle");
      end
`endif
    end
  end

  initial begin
    if ((AXIS_DATA_W <= 0) || ((AXIS_DATA_W % 8) != 0) ||
        (RAW_BEATS <= 0) || (DDR_BURST_BEATS <= 0) ||
        (DDR_BURST_BEATS > RAW_BEATS) || (DDR_BURST_BEATS > 16'hffff) ||
        (MAX_OUTSTANDING <= 0) ||
        ((MAX_OUTSTANDING * DDR_BURST_BEATS) > FIFO_DEPTH)) begin
      $fatal(1, "mrtc_rdtc_ddr_feeder_engine has an unsupported parameter combination");
    end
  end
endmodule
