module mrtc_rdtc_ddr_feeder_engine_sync64 #(
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
  localparam int FIFO_DEPTH = 64;
  localparam int FIFO_IDX_W = $clog2(FIFO_DEPTH);
  localparam int FIFO_COUNT_W = $clog2(FIFO_DEPTH + 1);
  localparam int OUTPUT_DEPTH = 2;
  localparam int OUTPUT_COUNT_W = $clog2(OUTPUT_DEPTH + 1);
  localparam int BEAT_COUNT_W = $clog2(RAW_BEATS + 1);
  localparam int BURST_COUNT_W = $clog2(DDR_BURST_BEATS + 1);
  localparam int OUTSTANDING_COUNT_W = $clog2(MAX_OUTSTANDING + 1);
  localparam int GAP_COUNT_W =
    (FEED_GAP_CYCLES <= 0) ? 1 : $clog2(FEED_GAP_CYCLES + 1);

  typedef enum logic [0:0] {
    ST_IDLE,
    ST_ACTIVE
  } state_t;

  state_t state_reg;

  logic [FIFO_IDX_W-1:0] fifo_wr_ptr_reg;
  logic [FIFO_IDX_W-1:0] fifo_rd_ptr_reg;
  logic [FIFO_COUNT_W-1:0] fifo_storage_count_reg;
  logic [AXIS_DATA_W-1:0] fifo_rd_data;
  logic fifo_rd_pending_reg;

  logic [AXIS_DATA_W-1:0] output_data_0_reg;
  logic [AXIS_DATA_W-1:0] output_data_1_reg;
  logic [OUTPUT_COUNT_W-1:0] output_count_reg;

  logic [DDR_ADDR_W-1:0] raw_addr_reg;
  logic [15:0] block_id_reg;
  logic [15:0] block_range_start_reg;
  logic [15:0] frame_id_reg;
  logic [7:0] codec_mode_reg;
  logic [7:0] rice_mode_reg;
  logic [3:0] fixed_k_reg;
  logic [15:0] tensor_spatial_size_reg;
  logic [15:0] tensor_doppler_size_reg;
  logic [15:0] tensor_range_size_reg;
  logic last_block_reg;

  logic [OUTSTANDING_COUNT_W-1:0] outstanding_reads_reg;
  logic [BEAT_COUNT_W-1:0] beats_requested_reg;
  logic [BEAT_COUNT_W-1:0] beats_received_reg;
  logic [BEAT_COUNT_W-1:0] beats_sent_reg;
  logic [GAP_COUNT_W-1:0] gap_count_reg;

  logic [BEAT_COUNT_W-1:0] remaining_beats;
  logic [BURST_COUNT_W-1:0] burst_len_words;
  logic issue_fire;
  logic burst_complete;
  logic fifo_write_fire;
  logic fifo_read_issue;
  logic output_push;
  logic output_pop;
  logic final_pop;
  logic same_address_collision;
  integer reserved_beats_comb;
  integer output_slots_reserved_comb;

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

  assign m_axis_raw_tvalid = (state_reg == ST_ACTIVE) &&
                             (output_count_reg != OUTPUT_COUNT_W'(0)) &&
                             (gap_count_reg == GAP_COUNT_W'(0));
  assign m_axis_raw_tdata = output_data_0_reg;
  assign m_axis_raw_tlast = m_axis_raw_tvalid &&
                            (beats_sent_reg == BEAT_COUNT_W'(RAW_BEATS - 1));
  assign m_axis_raw_tuser = {
    4'd0,
    last_block_reg,
    codec_mode_reg[1:0],
    1'b0
  };

  assign fifo_write_fire = (state_reg == ST_ACTIVE) && i_mem_rd_data_valid;
  assign output_pop = m_axis_raw_tvalid && m_axis_raw_tready;
  assign output_push = fifo_rd_pending_reg;
  assign final_pop = output_pop &&
                     (beats_sent_reg == BEAT_COUNT_W'(RAW_BEATS - 1));
  assign issue_fire = o_mem_rd_req && i_mem_rd_ready;
  assign burst_complete = fifo_write_fire && i_mem_rd_last;
  assign same_address_collision = fifo_write_fire && fifo_read_issue &&
                                  (fifo_wr_ptr_reg == fifo_rd_ptr_reg);

  always_comb begin
    remaining_beats = BEAT_COUNT_W'(RAW_BEATS) - beats_requested_reg;
    burst_len_words = BURST_COUNT_W'(DDR_BURST_BEATS);
    if (DDR_BURST_BEATS > FIFO_DEPTH) begin
      burst_len_words = BURST_COUNT_W'(FIFO_DEPTH);
    end
    if (remaining_beats < BEAT_COUNT_W'(burst_len_words)) begin
      burst_len_words = BURST_COUNT_W'(remaining_beats);
    end

    reserved_beats_comb = int'(beats_requested_reg) - int'(beats_sent_reg);
    o_mem_rd_req = 1'b0;
    o_mem_rd_addr = raw_addr_reg +
                    DDR_ADDR_W'(int'(beats_requested_reg) * AXIS_BYTES);
    o_mem_rd_len = 16'(burst_len_words);
    if ((state_reg == ST_ACTIVE) &&
        (beats_requested_reg < BEAT_COUNT_W'(RAW_BEATS)) &&
        (outstanding_reads_reg < OUTSTANDING_COUNT_W'(MAX_OUTSTANDING)) &&
        ((reserved_beats_comb + int'(burst_len_words)) <= FIFO_DEPTH)) begin
      o_mem_rd_req = 1'b1;
    end

    output_slots_reserved_comb = int'(output_count_reg) +
                                 (fifo_rd_pending_reg ? 1 : 0) -
                                 (output_pop ? 1 : 0);
    fifo_read_issue = (state_reg == ST_ACTIVE) &&
                      (fifo_storage_count_reg != FIFO_COUNT_W'(0)) &&
                      (output_slots_reserved_comb < OUTPUT_DEPTH);
  end

  mrtc_bounded_feeder_fifo_mem #(
    .DATA_W (AXIS_DATA_W),
    .DEPTH  (FIFO_DEPTH)
  ) u_fifo_mem (
    .clk       (clk),
    .i_wr_en   (fifo_write_fire && !same_address_collision),
    .i_wr_addr (fifo_wr_ptr_reg),
    .i_wr_data (i_mem_rd_data),
    .i_rd_en   (fifo_read_issue && !same_address_collision),
    .i_rd_addr (fifo_rd_ptr_reg),
    .o_rd_data (fifo_rd_data)
  );

  always_ff @(posedge clk or negedge rst_n) begin
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
      fifo_storage_count_reg <= '0;
      fifo_rd_pending_reg <= 1'b0;
      output_data_0_reg <= '0;
      output_data_1_reg <= '0;
      output_count_reg <= '0;
      outstanding_reads_reg <= '0;
      beats_requested_reg <= '0;
      beats_received_reg <= '0;
      beats_sent_reg <= '0;
      gap_count_reg <= '0;
      o_done <= 1'b0;
      o_mem_wait_cycles <= 32'd0;
      o_axis_stall_cycles <= 32'd0;
      o_blocks_fed <= 32'd0;
      o_bursts_issued <= 32'd0;
      o_beats_streamed <= 32'd0;
    end else begin
      o_done <= 1'b0;
      fifo_rd_pending_reg <= fifo_read_issue && !same_address_collision;

      if (i_clear_status) begin
        o_mem_wait_cycles <= 32'd0;
        o_axis_stall_cycles <= 32'd0;
        o_blocks_fed <= 32'd0;
        o_bursts_issued <= 32'd0;
        o_beats_streamed <= 32'd0;
      end

      case ({output_push, output_pop})
        2'b10: begin
          if (output_count_reg == OUTPUT_COUNT_W'(0)) begin
            output_data_0_reg <= fifo_rd_data;
          end else begin
            output_data_1_reg <= fifo_rd_data;
          end
          output_count_reg <= output_count_reg + OUTPUT_COUNT_W'(1);
        end
        2'b01: begin
          if (output_count_reg == OUTPUT_COUNT_W'(2)) begin
            output_data_0_reg <= output_data_1_reg;
          end
          output_count_reg <= output_count_reg - OUTPUT_COUNT_W'(1);
        end
        2'b11: begin
          if (output_count_reg == OUTPUT_COUNT_W'(1)) begin
            output_data_0_reg <= fifo_rd_data;
          end else begin
            output_data_0_reg <= output_data_1_reg;
            output_data_1_reg <= fifo_rd_data;
          end
        end
        default: begin
        end
      endcase

      case (state_reg)
        ST_IDLE: begin
          fifo_wr_ptr_reg <= '0;
          fifo_rd_ptr_reg <= '0;
          fifo_storage_count_reg <= '0;
          fifo_rd_pending_reg <= 1'b0;
          output_count_reg <= '0;
          outstanding_reads_reg <= '0;
          beats_requested_reg <= '0;
          beats_received_reg <= '0;
          beats_sent_reg <= '0;
          gap_count_reg <= '0;
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
          case ({fifo_write_fire, fifo_read_issue})
            2'b10: fifo_storage_count_reg <=
                      fifo_storage_count_reg + FIFO_COUNT_W'(1);
            2'b01: fifo_storage_count_reg <=
                      fifo_storage_count_reg - FIFO_COUNT_W'(1);
            default: begin
            end
          endcase

          if (fifo_write_fire) begin
            fifo_wr_ptr_reg <= fifo_wr_ptr_reg + FIFO_IDX_W'(1);
            beats_received_reg <= beats_received_reg + BEAT_COUNT_W'(1);
          end
          if (fifo_read_issue) begin
            fifo_rd_ptr_reg <= fifo_rd_ptr_reg + FIFO_IDX_W'(1);
          end

          if (m_axis_raw_tvalid && !m_axis_raw_tready) begin
            o_axis_stall_cycles <= o_axis_stall_cycles + 32'd1;
          end
          if (output_pop) begin
            beats_sent_reg <= beats_sent_reg + BEAT_COUNT_W'(1);
            o_beats_streamed <= o_beats_streamed + 32'd1;
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
            beats_requested_reg <=
              beats_requested_reg + BEAT_COUNT_W'(burst_len_words);
            o_bursts_issued <= o_bursts_issued + 32'd1;
          end

          case ({issue_fire, burst_complete})
            2'b10: outstanding_reads_reg <=
                      outstanding_reads_reg + OUTSTANDING_COUNT_W'(1);
            2'b01: outstanding_reads_reg <=
                      outstanding_reads_reg - OUTSTANDING_COUNT_W'(1);
            default: begin
            end
          endcase

          mem_wait_this_cycle = 1'b0;
          if ((beats_requested_reg < BEAT_COUNT_W'(RAW_BEATS)) && !issue_fire) begin
            if ((outstanding_reads_reg >= OUTSTANDING_COUNT_W'(MAX_OUTSTANDING)) ||
                (o_mem_rd_req && !i_mem_rd_ready) ||
                ((reserved_beats_comb + int'(burst_len_words)) > FIFO_DEPTH)) begin
              mem_wait_this_cycle = 1'b1;
            end
          end
          if ((beats_received_reg < BEAT_COUNT_W'(RAW_BEATS)) &&
              (output_count_reg == OUTPUT_COUNT_W'(0)) &&
              !fifo_rd_pending_reg &&
              (fifo_storage_count_reg == FIFO_COUNT_W'(0))) begin
            mem_wait_this_cycle = 1'b1;
          end
          if (mem_wait_this_cycle) begin
            o_mem_wait_cycles <= o_mem_wait_cycles + 32'd1;
          end

          if (final_pop) begin
            state_reg <= ST_IDLE;
            o_done <= 1'b1;
            o_blocks_fed <= o_blocks_fed + 32'd1;
          end
        end

        default: state_reg <= ST_IDLE;
      endcase

`ifndef SYNTHESIS
      if ((state_reg == ST_IDLE) && i_mem_rd_data_valid) begin
        $fatal(1, "DDR sync feeder received a memory response while idle");
      end
      if (fifo_write_fire &&
          (fifo_storage_count_reg == FIFO_COUNT_W'(FIFO_DEPTH)) &&
          !fifo_read_issue) begin
        $fatal(1, "DDR sync feeder FIFO overflow");
      end
      if (fifo_read_issue &&
          (fifo_storage_count_reg == FIFO_COUNT_W'(0))) begin
        $fatal(1, "DDR sync feeder FIFO underflow");
      end
      if (output_push && !output_pop &&
          (output_count_reg == OUTPUT_COUNT_W'(OUTPUT_DEPTH))) begin
        $fatal(1, "DDR sync feeder output queue overflow");
      end
      if (same_address_collision) begin
        $fatal(1, "DDR sync feeder forbids same-address read/write");
      end
      if (i_mem_rd_last && !fifo_write_fire) begin
        $fatal(1, "DDR sync feeder observed last without valid data");
      end
      if (burst_complete &&
          (outstanding_reads_reg == OUTSTANDING_COUNT_W'(0)) &&
          !issue_fire) begin
        $fatal(1, "DDR sync feeder completed an unissued burst");
      end
      if (final_pop &&
          ((beats_received_reg != BEAT_COUNT_W'(RAW_BEATS)) ||
           (outstanding_reads_reg != OUTSTANDING_COUNT_W'(0)) ||
           (fifo_storage_count_reg != FIFO_COUNT_W'(0)) ||
           fifo_rd_pending_reg ||
           (output_count_reg != OUTPUT_COUNT_W'(1)))) begin
        $fatal(1, "DDR sync feeder completed with pending data");
      end
`endif
    end
  end

  initial begin
    if ((AXIS_DATA_W != 128) || (RAW_BEATS != 256) ||
        (DDR_BURST_BEATS <= 0) || (DDR_BURST_BEATS > RAW_BEATS) ||
        (MAX_OUTSTANDING <= 0)) begin
      $fatal(1, "mrtc_rdtc_ddr_feeder_engine_sync64 has an unsupported parameter combination");
    end
  end

  logic unused_ddr_read_latency;
  assign unused_ddr_read_latency = (DDR_READ_LATENCY == 0);
endmodule
