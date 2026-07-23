module mrtc_rdtc_ddr_multiengine_wrapper #(
  parameter int AXIS_DATA_W = 128,
  parameter int NUM_ENGINES = 2,
  parameter int ENGINE_K_POLICY_ARCH = mrtc_pkg::MRTC_K_POLICY_PREFIX_FAST,
  parameter int ENGINE_BPACK_ARCH = mrtc_pkg::MRTC_BPACK_ARCH_LANE_WORD,
  parameter int ENGINE_PACKER_LANE_MODE = 4,
  parameter bit PREFIX_DURING_CAPTURE = 1'b1,
  parameter bit PREFIX_STREAM_LENGTH_BY_TLAST = 1'b1,
  parameter int DDR_ADDR_W = 64,
  parameter int DDR_READ_LATENCY = 32,
  parameter int DDR_BURST_BEATS = 16,
  parameter int MAX_OUTSTANDING = 4,
  parameter int FEED_GAP_CYCLES = 0,
  parameter bit OUTPUT_IN_ORDER = 1'b0,
  parameter int PREFIX_SAMPLES = 256
) (
  input  logic                                clk,
  input  logic                                rst_n,
  input  logic                                i_clear_status,

  input  logic                                s_desc_valid,
  output logic                                s_desc_ready,
  input  logic [DDR_ADDR_W-1:0]               s_desc_raw_addr,
  input  logic [15:0]                         s_desc_block_id,
  input  logic [15:0]                         s_desc_block_range_start,
  input  logic [15:0]                         s_desc_frame_id,
  input  logic [7:0]                          s_desc_codec_mode,
  input  logic [7:0]                          s_desc_rice_mode,
  input  logic [3:0]                          s_desc_fixed_k,
  input  logic [15:0]                         s_desc_tensor_spatial_size,
  input  logic [15:0]                         s_desc_tensor_doppler_size,
  input  logic [15:0]                         s_desc_tensor_range_size,
  input  logic                                s_desc_last_block,

  output logic [NUM_ENGINES-1:0]              o_mem_rd_req,
  output logic [NUM_ENGINES-1:0][DDR_ADDR_W-1:0] o_mem_rd_addr,
  output logic [NUM_ENGINES-1:0][15:0]        o_mem_rd_len,
  input  logic [NUM_ENGINES-1:0]              i_mem_rd_ready,
  input  logic [NUM_ENGINES-1:0]              i_mem_rd_data_valid,
  input  wire [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] i_mem_rd_data,
  input  logic [NUM_ENGINES-1:0]              i_mem_rd_last,

  output logic [AXIS_DATA_W-1:0]              m_axis_comp_tdata,
  output logic                                m_axis_comp_tvalid,
  input  logic                                m_axis_comp_tready,
  output logic                                m_axis_comp_tlast,
  output logic [7:0]                          m_axis_comp_tuser,

  output logic                                stat_busy,
  output logic                                stat_done,
  output logic [31:0]                         stat_num_blocks,
  output logic [31:0]                         stat_raw_bytes,
  output logic [31:0]                         stat_comp_bytes,
  output logic [31:0]                         stat_error,
  output logic [31:0]                         stat_stall_input_cycles,
  output logic [31:0]                         stat_stall_output_cycles
);
  import mrtc_pkg::*;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int ENGINE_IDX_W = (NUM_ENGINES <= 1) ? 1 : $clog2(NUM_ENGINES);
  localparam int MAX_PACKET_BEATS = (MRTC_MAX_OUTPUT_BYTES + AXIS_BYTES - 1) / AXIS_BYTES;
  localparam int PACKET_BEAT_IDX_W = $clog2(MAX_PACKET_BEATS + 1);
  localparam int PACKET_BUFFER_DEPTH = 2;
  localparam int PKTBUF_OCC_W = $clog2(PACKET_BUFFER_DEPTH + 1);
  localparam int META_FIFO_DEPTH = 8;
  localparam int META_PTR_W = (META_FIFO_DEPTH <= 1) ? 1 : $clog2(META_FIFO_DEPTH);
  localparam int META_COUNT_W = $clog2(META_FIFO_DEPTH + 1);

  generate
    if (OUTPUT_IN_ORDER) begin : g_unsupported_output_in_order
      initial $fatal(
        1,
        "mrtc_rdtc_ddr_multiengine_wrapper: OUTPUT_IN_ORDER is not implemented; use packet metadata for software reassembly"
      );
    end
  endgenerate

  logic [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] feeder_axis_raw_tdata;
  logic [NUM_ENGINES-1:0]                  feeder_axis_raw_tvalid;
  logic [NUM_ENGINES-1:0]                  feeder_axis_raw_tready;
  logic [NUM_ENGINES-1:0]                  feeder_axis_raw_tlast;
  logic [NUM_ENGINES-1:0][7:0]             feeder_axis_raw_tuser;

  logic [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] eng_axis_comp_tdata;
  logic [NUM_ENGINES-1:0]                  eng_axis_comp_tvalid;
  logic [NUM_ENGINES-1:0]                  eng_axis_comp_tready;
  logic [NUM_ENGINES-1:0]                  eng_axis_comp_tlast;
  logic [NUM_ENGINES-1:0][7:0]             eng_axis_comp_tuser;

  logic [NUM_ENGINES-1:0]                  pktbuf_packet_valid;
  logic [NUM_ENGINES-1:0]                  pktbuf_packet_start;
  logic [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] pktbuf_axis_tdata;
  logic [NUM_ENGINES-1:0]                  pktbuf_axis_tvalid;
  logic [NUM_ENGINES-1:0]                  pktbuf_axis_tready;
  logic [NUM_ENGINES-1:0]                  pktbuf_axis_tlast;
  logic [NUM_ENGINES-1:0][7:0]             pktbuf_axis_tuser;
  logic [NUM_ENGINES-1:0]                  pktbuf_busy;
  logic [NUM_ENGINES-1:0]                  pktbuf_full;
  logic [NUM_ENGINES-1:0]                  pktbuf_overflow;
  logic [NUM_ENGINES-1:0][31:0]            pktbuf_packets_written_sig;
  logic [NUM_ENGINES-1:0][31:0]            pktbuf_packets_read_sig;
  logic [NUM_ENGINES-1:0][31:0]            pktbuf_write_stall_cycles_sig;
  logic [NUM_ENGINES-1:0][31:0]            pktbuf_read_stall_cycles_sig;
  logic [NUM_ENGINES-1:0][PKTBUF_OCC_W-1:0] pktbuf_max_occupancy_sig;

  logic [NUM_ENGINES-1:0]                  eng_stat_busy;
  logic [NUM_ENGINES-1:0]                  eng_stat_done;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_raw_bytes;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_comp_bytes;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_num_blocks;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_error;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_stall_input_cycles;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_stall_output_cycles;

  logic [NUM_ENGINES-1:0]                  feeder_desc_valid;
  logic [NUM_ENGINES-1:0]                  feeder_desc_ready;
  logic [NUM_ENGINES-1:0][DDR_ADDR_W-1:0]  feeder_desc_raw_addr;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_block_id;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_block_range_start;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_frame_id;
  logic [NUM_ENGINES-1:0][7:0]             feeder_desc_codec_mode;
  logic [NUM_ENGINES-1:0][7:0]             feeder_desc_rice_mode;
  logic [NUM_ENGINES-1:0][3:0]             feeder_desc_fixed_k;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_tensor_spatial_size;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_tensor_doppler_size;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_tensor_range_size;
  logic [NUM_ENGINES-1:0]                  feeder_desc_last_block;

  logic [NUM_ENGINES-1:0]                  feeder_busy;
  logic [NUM_ENGINES-1:0]                  feeder_done;
  logic [NUM_ENGINES-1:0]                  feeder_feed_active;
  logic [NUM_ENGINES-1:0][31:0]            feeder_mem_wait_cycles_sig;
  logic [NUM_ENGINES-1:0][31:0]            feeder_axis_stall_cycles_sig;
  logic [NUM_ENGINES-1:0][31:0]            feeder_blocks_fed_sig;
  logic [NUM_ENGINES-1:0][31:0]            feeder_bursts_issued_sig;
  logic [NUM_ENGINES-1:0][31:0]            feeder_beats_streamed_sig;
  logic [NUM_ENGINES-1:0][31:0]            feeder_desc_block_id_sig;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_block_range_start_sig;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_frame_id_sig;
  logic [NUM_ENGINES-1:0][7:0]             feeder_desc_codec_mode_sig;
  logic [NUM_ENGINES-1:0][7:0]             feeder_desc_rice_mode_sig;
  logic [NUM_ENGINES-1:0][3:0]             feeder_desc_fixed_k_sig;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_tensor_spatial_size_sig;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_tensor_doppler_size_sig;
  logic [NUM_ENGINES-1:0][15:0]            feeder_desc_tensor_range_size_sig;
  logic [NUM_ENGINES-1:0]                  feeder_desc_last_block_sig;

  logic [15:0] meta_block_id_reg [0:NUM_ENGINES-1][0:META_FIFO_DEPTH-1];
  logic [15:0] meta_block_range_start_reg [0:NUM_ENGINES-1][0:META_FIFO_DEPTH-1];
  logic        meta_last_block_reg [0:NUM_ENGINES-1][0:META_FIFO_DEPTH-1];
  logic [META_PTR_W-1:0] meta_wr_ptr_reg [0:NUM_ENGINES-1];
  logic [META_PTR_W-1:0] meta_rd_ptr_reg [0:NUM_ENGINES-1];
  logic [META_COUNT_W-1:0] meta_count_reg [0:NUM_ENGINES-1];

  logic [ENGINE_IDX_W-1:0] desc_rr_ptr_reg;
  logic                    desc_candidate_valid;
  logic [ENGINE_IDX_W-1:0] desc_candidate_engine;

  logic                    packet_active_reg;
  logic [ENGINE_IDX_W-1:0] packet_engine_reg;
  logic [15:0]             packet_block_id_reg;
  logic [15:0]             packet_block_range_start_reg;
  logic                    packet_last_block_reg;
  logic [ENGINE_IDX_W-1:0] output_rr_ptr_reg;
  logic [PACKET_BEAT_IDX_W-1:0] packet_beat_idx_reg;
  logic [31:0]             packet_byte_count_reg;
  logic                    packet_candidate_valid;
  logic [ENGINE_IDX_W-1:0] packet_candidate_engine;
  logic [15:0]             packet_candidate_block_id;
  logic [15:0]             packet_candidate_block_range_start;
  logic                    packet_candidate_last_block;
  logic                    selected_packet_valid;
  logic [ENGINE_IDX_W-1:0] selected_packet_engine;
  logic [15:0]             selected_packet_block_id;
  logic [15:0]             selected_packet_block_range_start;
  logic                    selected_packet_last_block;

  logic [AXIS_DATA_W-1:0] selected_packet_tdata;
  logic                   selected_packet_tvalid;
  logic                   selected_packet_tlast;
  logic [7:0]             selected_packet_tuser;
  logic [AXIS_DATA_W-1:0] patched_packet_tdata;
  logic                   packet_select_fire;
  logic                   packet_handshake;

  logic [31:0] desc_dispatched_total_reg;
  logic [31:0] desc_per_engine_reg [0:NUM_ENGINES-1];
  logic [31:0] desc_stall_cycles_reg;
  logic [31:0] output_packets_total_reg;
  logic [31:0] output_packets_per_engine_reg [0:NUM_ENGINES-1];
  logic [31:0] output_arb_stall_cycles_reg;
  logic [31:0] output_backpressure_cycles_reg;
  logic [31:0] arbiter_idle_cycles_reg;
  logic [31:0] arbiter_active_cycles_reg;
  logic [31:0] engine_busy_cycles_reg [0:NUM_ENGINES-1];
  logic [31:0] feeder_busy_cycles_reg [0:NUM_ENGINES-1];
  logic [31:0] feeder_mem_wait_cycles_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] feeder_axis_stall_cycles_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] feeder_bursts_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] feeder_beats_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] pktbuf_packets_written_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] pktbuf_packets_read_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] pktbuf_write_stall_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] pktbuf_read_stall_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] pktbuf_full_cycles_reg [0:NUM_ENGINES-1];
  logic [31:0] completed_packet_wait_cycles_reg [0:NUM_ENGINES-1];
  logic [PKTBUF_OCC_W-1:0] pktbuf_max_occupancy_shadow_reg [0:NUM_ENGINES-1];
  logic [31:0] stat_error_reg;

  function automatic int axis_valid_bytes(
    input logic last,
    input logic [7:0] user
  );
    begin
      if (last) begin
        axis_valid_bytes = int'(user[3:0]) + 1;
      end else begin
        axis_valid_bytes = AXIS_BYTES;
      end
    end
  endfunction

  function automatic logic [AXIS_DATA_W-1:0] patch_header_words(
    input logic [AXIS_DATA_W-1:0] in_data,
    input logic [PACKET_BEAT_IDX_W-1:0] beat_idx,
    input logic [15:0]            block_id,
    input logic [15:0]            block_range_start,
    input logic                   last_block
  );
    logic [AXIS_DATA_W-1:0] patched;
    logic [15:0] patched_flags;
    begin
      patched = in_data;
      if (beat_idx == 0) begin
        patched[(MRTC_HDR_OFF_BLOCK_ID*8) +: 8] = block_id[7:0];
        patched[((MRTC_HDR_OFF_BLOCK_ID + 1)*8) +: 8] = block_id[15:8];
      end
      if (beat_idx == 1) begin
        patched[((MRTC_HDR_OFF_BLOCK_RANGE - AXIS_BYTES)*8) +: 8] = block_range_start[7:0];
        patched[(((MRTC_HDR_OFF_BLOCK_RANGE + 1) - AXIS_BYTES)*8) +: 8] = block_range_start[15:8];
        patched_flags = {
          patched[(((MRTC_HDR_OFF_FLAGS + 1) - AXIS_BYTES)*8) +: 8],
          patched[((MRTC_HDR_OFF_FLAGS - AXIS_BYTES)*8) +: 8]
        };
        if (last_block) begin
          patched_flags = patched_flags | MRTC_FLAG_LAST_BLOCK;
        end else begin
          patched_flags = patched_flags & ~MRTC_FLAG_LAST_BLOCK;
        end
        patched[((MRTC_HDR_OFF_FLAGS - AXIS_BYTES)*8) +: 8] = patched_flags[7:0];
        patched[(((MRTC_HDR_OFF_FLAGS + 1) - AXIS_BYTES)*8) +: 8] = patched_flags[15:8];
      end
      patch_header_words = patched;
    end
  endfunction

  genvar gi;
  generate
    for (gi = 0; gi < NUM_ENGINES; gi = gi + 1) begin : g_engine
      mrtc_rdtc_ddr_feeder_engine #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .RAW_BYTES(MRTC_RAW_BYTES),
        .RAW_BEATS(MRTC_RAW_BYTES / (AXIS_DATA_W / 8)),
        .DDR_ADDR_W(DDR_ADDR_W),
        .DDR_READ_LATENCY(DDR_READ_LATENCY),
        .DDR_BURST_BEATS(DDR_BURST_BEATS),
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .FEED_GAP_CYCLES(FEED_GAP_CYCLES)
      ) u_feeder (
        .clk(clk),
        .rst_n(rst_n),
        .i_clear_status(i_clear_status),
        .i_desc_valid(feeder_desc_valid[gi]),
        .o_desc_ready(feeder_desc_ready[gi]),
        .i_desc_raw_addr(feeder_desc_raw_addr[gi]),
        .i_desc_block_id(feeder_desc_block_id[gi]),
        .i_desc_block_range_start(feeder_desc_block_range_start[gi]),
        .i_desc_frame_id(feeder_desc_frame_id[gi]),
        .i_desc_codec_mode(feeder_desc_codec_mode[gi]),
        .i_desc_rice_mode(feeder_desc_rice_mode[gi]),
        .i_desc_fixed_k(feeder_desc_fixed_k[gi]),
        .i_desc_tensor_spatial_size(feeder_desc_tensor_spatial_size[gi]),
        .i_desc_tensor_doppler_size(feeder_desc_tensor_doppler_size[gi]),
        .i_desc_tensor_range_size(feeder_desc_tensor_range_size[gi]),
        .i_desc_last_block(feeder_desc_last_block[gi]),
        .o_mem_rd_req(o_mem_rd_req[gi]),
        .o_mem_rd_addr(o_mem_rd_addr[gi]),
        .o_mem_rd_len(o_mem_rd_len[gi]),
        .i_mem_rd_ready(i_mem_rd_ready[gi]),
        .i_mem_rd_data_valid(i_mem_rd_data_valid[gi]),
        .i_mem_rd_data(i_mem_rd_data[gi]),
        .i_mem_rd_last(i_mem_rd_last[gi]),
        .m_axis_raw_tdata(feeder_axis_raw_tdata[gi]),
        .m_axis_raw_tvalid(feeder_axis_raw_tvalid[gi]),
        .m_axis_raw_tready(feeder_axis_raw_tready[gi]),
        .m_axis_raw_tlast(feeder_axis_raw_tlast[gi]),
        .m_axis_raw_tuser(feeder_axis_raw_tuser[gi]),
        .o_busy(feeder_busy[gi]),
        .o_done(feeder_done[gi]),
        .o_feed_active(feeder_feed_active[gi]),
        .o_mem_wait_cycles(feeder_mem_wait_cycles_sig[gi]),
        .o_axis_stall_cycles(feeder_axis_stall_cycles_sig[gi]),
        .o_blocks_fed(feeder_blocks_fed_sig[gi]),
        .o_bursts_issued(feeder_bursts_issued_sig[gi]),
        .o_beats_streamed(feeder_beats_streamed_sig[gi]),
        .o_desc_block_id(feeder_desc_block_id_sig[gi]),
        .o_desc_block_range_start(feeder_desc_block_range_start_sig[gi]),
        .o_desc_frame_id(feeder_desc_frame_id_sig[gi]),
        .o_desc_codec_mode(feeder_desc_codec_mode_sig[gi]),
        .o_desc_rice_mode(feeder_desc_rice_mode_sig[gi]),
        .o_desc_fixed_k(feeder_desc_fixed_k_sig[gi]),
        .o_desc_tensor_spatial_size(feeder_desc_tensor_spatial_size_sig[gi]),
        .o_desc_tensor_doppler_size(feeder_desc_tensor_doppler_size_sig[gi]),
        .o_desc_tensor_range_size(feeder_desc_tensor_range_size_sig[gi]),
        .o_desc_last_block(feeder_desc_last_block_sig[gi])
      );

      mrtc_rdtc_encoder_top #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .MRTC_K_POLICY_ARCH(ENGINE_K_POLICY_ARCH),
        .MRTC_BPACK_ARCH(ENGINE_BPACK_ARCH),
        .PACKER_LANE_MODE(ENGINE_PACKER_LANE_MODE),
        .PREFIX_DURING_CAPTURE(PREFIX_DURING_CAPTURE),
        .PREFIX_STREAM_LENGTH_BY_TLAST(PREFIX_STREAM_LENGTH_BY_TLAST),
        .PREFIX_SAMPLES(PREFIX_SAMPLES)
      ) u_engine (
        .clk(clk),
        .rst_n(rst_n),
        .i_clear_status(i_clear_status),
        .s_axis_raw_tdata(feeder_axis_raw_tdata[gi]),
        .s_axis_raw_tvalid(feeder_axis_raw_tvalid[gi]),
        .s_axis_raw_tready(feeder_axis_raw_tready[gi]),
        .s_axis_raw_tlast(feeder_axis_raw_tlast[gi]),
        .s_axis_raw_tuser(feeder_axis_raw_tuser[gi]),
        .m_axis_comp_tdata(eng_axis_comp_tdata[gi]),
        .m_axis_comp_tvalid(eng_axis_comp_tvalid[gi]),
        .m_axis_comp_tready(eng_axis_comp_tready[gi]),
        .m_axis_comp_tlast(eng_axis_comp_tlast[gi]),
        .m_axis_comp_tuser(eng_axis_comp_tuser[gi]),
        .cfg_codec_mode(feeder_desc_codec_mode_sig[gi]),
        .cfg_rice_mode(feeder_desc_rice_mode_sig[gi]),
        .cfg_fixed_k(feeder_desc_fixed_k_sig[gi]),
        .cfg_frame_id(feeder_desc_frame_id_sig[gi]),
        .cfg_block_id_base(feeder_desc_block_id_sig[gi][15:0]),
        .cfg_tensor_spatial_size(feeder_desc_tensor_spatial_size_sig[gi]),
        .cfg_tensor_doppler_size(feeder_desc_tensor_doppler_size_sig[gi]),
        .cfg_tensor_range_size(feeder_desc_tensor_range_size_sig[gi]),
        .stat_busy(eng_stat_busy[gi]),
        .stat_done(eng_stat_done[gi]),
        .stat_raw_bytes(eng_stat_raw_bytes[gi]),
        .stat_comp_bytes(eng_stat_comp_bytes[gi]),
        .stat_num_blocks(eng_stat_num_blocks[gi]),
        .stat_error(eng_stat_error[gi]),
        .stat_raw_bypass_blocks(),
        .stat_stall_input_cycles(eng_stat_stall_input_cycles[gi]),
        .stat_stall_output_cycles(eng_stat_stall_output_cycles[gi])
      );

      mrtc_axis_packet_buffer #(
        .AXIS_DATA_W(AXIS_DATA_W),
        .TUSER_W(8),
        .MAX_PACKET_BYTES(MRTC_MAX_OUTPUT_BYTES),
        .MAX_PACKET_BEATS(MAX_PACKET_BEATS),
        .PACKET_DEPTH(PACKET_BUFFER_DEPTH)
      ) u_pktbuf (
        .clk(clk),
        .rst_n(rst_n),
        .i_clear_status(i_clear_status),
        .s_axis_tdata(eng_axis_comp_tdata[gi]),
        .s_axis_tvalid(eng_axis_comp_tvalid[gi]),
        .s_axis_tready(eng_axis_comp_tready[gi]),
        .s_axis_tlast(eng_axis_comp_tlast[gi]),
        .s_axis_tuser(eng_axis_comp_tuser[gi]),
        .o_packet_valid(pktbuf_packet_valid[gi]),
        .i_packet_start(pktbuf_packet_start[gi]),
        .m_axis_tdata(pktbuf_axis_tdata[gi]),
        .m_axis_tvalid(pktbuf_axis_tvalid[gi]),
        .m_axis_tready(pktbuf_axis_tready[gi]),
        .m_axis_tlast(pktbuf_axis_tlast[gi]),
        .m_axis_tuser(pktbuf_axis_tuser[gi]),
        .o_busy(pktbuf_busy[gi]),
        .o_full(pktbuf_full[gi]),
        .o_overflow(pktbuf_overflow[gi]),
        .o_packets_written(pktbuf_packets_written_sig[gi]),
        .o_packets_read(pktbuf_packets_read_sig[gi]),
        .o_write_stall_cycles(pktbuf_write_stall_cycles_sig[gi]),
        .o_read_stall_cycles(pktbuf_read_stall_cycles_sig[gi]),
        .o_max_occupancy(pktbuf_max_occupancy_sig[gi])
      );
    end
  endgenerate

  always_comb begin
    integer eng_idx;
    integer scan_idx;
    integer cand_idx;

    for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
      feeder_desc_valid[eng_idx] = 1'b0;
      feeder_desc_raw_addr[eng_idx] = s_desc_raw_addr;
      feeder_desc_block_id[eng_idx] = s_desc_block_id;
      feeder_desc_block_range_start[eng_idx] = s_desc_block_range_start;
      feeder_desc_frame_id[eng_idx] = s_desc_frame_id;
      feeder_desc_codec_mode[eng_idx] = s_desc_codec_mode;
      feeder_desc_rice_mode[eng_idx] = s_desc_rice_mode;
      feeder_desc_fixed_k[eng_idx] = s_desc_fixed_k;
      feeder_desc_tensor_spatial_size[eng_idx] = s_desc_tensor_spatial_size;
      feeder_desc_tensor_doppler_size[eng_idx] = s_desc_tensor_doppler_size;
      feeder_desc_tensor_range_size[eng_idx] = s_desc_tensor_range_size;
      feeder_desc_last_block[eng_idx] = s_desc_last_block;
    end

    desc_candidate_valid = 1'b0;
    desc_candidate_engine = '0;
    for (scan_idx = 0; scan_idx < NUM_ENGINES; scan_idx = scan_idx + 1) begin
      cand_idx = desc_rr_ptr_reg + scan_idx;
      if (cand_idx >= NUM_ENGINES) begin
        cand_idx = cand_idx - NUM_ENGINES;
      end
      if (!desc_candidate_valid && feeder_desc_ready[cand_idx] &&
          (meta_count_reg[cand_idx] != META_FIFO_DEPTH) &&
          !pktbuf_full[cand_idx]) begin
        desc_candidate_valid = 1'b1;
        desc_candidate_engine = ENGINE_IDX_W'(cand_idx);
      end
    end

    s_desc_ready = desc_candidate_valid;
    if (s_desc_valid && desc_candidate_valid) begin
      feeder_desc_valid[desc_candidate_engine] = 1'b1;
    end
  end

  always_comb begin
    integer scan_idx;
    integer cand_idx;
    integer front_idx;
    packet_candidate_valid = 1'b0;
    packet_candidate_engine = '0;
    packet_candidate_block_id = 16'd0;
    packet_candidate_block_range_start = 16'd0;
    packet_candidate_last_block = 1'b0;
    if (!packet_active_reg) begin
      for (scan_idx = 0; scan_idx < NUM_ENGINES; scan_idx = scan_idx + 1) begin
        cand_idx = output_rr_ptr_reg + scan_idx;
        if (cand_idx >= NUM_ENGINES) begin
          cand_idx = cand_idx - NUM_ENGINES;
        end
        front_idx = meta_rd_ptr_reg[cand_idx];
        if (!packet_candidate_valid &&
            pktbuf_packet_valid[cand_idx] &&
            (meta_count_reg[cand_idx] != META_COUNT_W'(0))) begin
          packet_candidate_valid = 1'b1;
          packet_candidate_engine = ENGINE_IDX_W'(cand_idx);
          packet_candidate_block_id = meta_block_id_reg[cand_idx][front_idx];
          packet_candidate_block_range_start = meta_block_range_start_reg[cand_idx][front_idx];
          packet_candidate_last_block = meta_last_block_reg[cand_idx][front_idx];
        end
      end
    end
  end

  assign selected_packet_valid = packet_active_reg || packet_candidate_valid;
  assign selected_packet_engine =
    packet_active_reg ? packet_engine_reg : packet_candidate_engine;
  assign selected_packet_block_id =
    packet_active_reg ? packet_block_id_reg : packet_candidate_block_id;
  assign selected_packet_block_range_start =
    packet_active_reg ? packet_block_range_start_reg : packet_candidate_block_range_start;
  assign selected_packet_last_block =
    packet_active_reg ? packet_last_block_reg : packet_candidate_last_block;

  always_comb begin
    integer eng_idx;
    for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
      pktbuf_packet_start[eng_idx] = 1'b0;
      pktbuf_axis_tready[eng_idx] = 1'b0;
    end
    selected_packet_tdata = '0;
    selected_packet_tvalid = 1'b0;
    selected_packet_tlast = 1'b0;
    selected_packet_tuser = '0;
    for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
      if (selected_packet_valid && (selected_packet_engine == ENGINE_IDX_W'(eng_idx))) begin
        pktbuf_packet_start[eng_idx] = !packet_active_reg && packet_candidate_valid;
        pktbuf_axis_tready[eng_idx] = m_axis_comp_tready;
        selected_packet_tdata = pktbuf_axis_tdata[eng_idx];
        selected_packet_tvalid = pktbuf_axis_tvalid[eng_idx];
        selected_packet_tlast = pktbuf_axis_tlast[eng_idx];
        selected_packet_tuser = pktbuf_axis_tuser[eng_idx];
      end
    end
  end

  assign patched_packet_tdata =
    patch_header_words(
      selected_packet_tdata,
      packet_active_reg ? packet_beat_idx_reg : PACKET_BEAT_IDX_W'(0),
      selected_packet_block_id,
      selected_packet_block_range_start,
      selected_packet_last_block
    );

  assign m_axis_comp_tdata = patched_packet_tdata;
  assign m_axis_comp_tvalid = selected_packet_valid && selected_packet_tvalid;
  assign m_axis_comp_tlast = selected_packet_tlast;
  assign m_axis_comp_tuser = selected_packet_tuser;
  assign packet_select_fire = !packet_active_reg && packet_candidate_valid;
  assign packet_handshake = m_axis_comp_tvalid && m_axis_comp_tready;

  always_ff @(posedge clk or negedge rst_n) begin
    integer eng_idx;
    integer next_ptr;
    integer beat_bytes;
    logic any_busy_local;
    logic desc_fire;
    logic meta_pop_fire;
    if (!rst_n) begin
      desc_rr_ptr_reg <= '0;
      packet_active_reg <= 1'b0;
      packet_engine_reg <= '0;
      packet_block_id_reg <= 16'd0;
      packet_block_range_start_reg <= 16'd0;
      packet_last_block_reg <= 1'b0;
      output_rr_ptr_reg <= '0;
      packet_beat_idx_reg <= '0;
      packet_byte_count_reg <= 32'd0;
      stat_busy <= 1'b0;
      stat_done <= 1'b0;
      stat_num_blocks <= 32'd0;
      stat_raw_bytes <= 32'd0;
      stat_comp_bytes <= 32'd0;
      stat_stall_input_cycles <= 32'd0;
      stat_stall_output_cycles <= 32'd0;
      stat_error <= MRTC_ERR_NONE;
      stat_error_reg <= MRTC_ERR_NONE;
      desc_dispatched_total_reg <= 32'd0;
      desc_stall_cycles_reg <= 32'd0;
      output_packets_total_reg <= 32'd0;
      output_arb_stall_cycles_reg <= 32'd0;
      output_backpressure_cycles_reg <= 32'd0;
      arbiter_idle_cycles_reg <= 32'd0;
      arbiter_active_cycles_reg <= 32'd0;
      for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
        meta_wr_ptr_reg[eng_idx] <= '0;
        meta_rd_ptr_reg[eng_idx] <= '0;
        meta_count_reg[eng_idx] <= '0;
        desc_per_engine_reg[eng_idx] <= 32'd0;
        output_packets_per_engine_reg[eng_idx] <= 32'd0;
        engine_busy_cycles_reg[eng_idx] <= 32'd0;
        feeder_busy_cycles_reg[eng_idx] <= 32'd0;
        feeder_mem_wait_cycles_shadow_reg[eng_idx] <= 32'd0;
        feeder_axis_stall_cycles_shadow_reg[eng_idx] <= 32'd0;
        feeder_bursts_shadow_reg[eng_idx] <= 32'd0;
        feeder_beats_shadow_reg[eng_idx] <= 32'd0;
        pktbuf_packets_written_shadow_reg[eng_idx] <= 32'd0;
        pktbuf_packets_read_shadow_reg[eng_idx] <= 32'd0;
        pktbuf_write_stall_shadow_reg[eng_idx] <= 32'd0;
        pktbuf_read_stall_shadow_reg[eng_idx] <= 32'd0;
        pktbuf_full_cycles_reg[eng_idx] <= 32'd0;
        completed_packet_wait_cycles_reg[eng_idx] <= 32'd0;
        pktbuf_max_occupancy_shadow_reg[eng_idx] <= '0;
      end
    end else begin
      desc_fire = s_desc_valid && s_desc_ready;
      meta_pop_fire = packet_handshake && selected_packet_tlast &&
                      (meta_count_reg[selected_packet_engine] != META_COUNT_W'(0));
      stat_done <= 1'b0;
      if (i_clear_status) begin
        stat_num_blocks <= 32'd0;
        stat_raw_bytes <= 32'd0;
        stat_comp_bytes <= 32'd0;
        stat_stall_input_cycles <= 32'd0;
        stat_stall_output_cycles <= 32'd0;
        stat_error_reg <= MRTC_ERR_NONE;
        desc_dispatched_total_reg <= 32'd0;
        desc_stall_cycles_reg <= 32'd0;
        output_packets_total_reg <= 32'd0;
        output_arb_stall_cycles_reg <= 32'd0;
        output_backpressure_cycles_reg <= 32'd0;
        arbiter_idle_cycles_reg <= 32'd0;
        arbiter_active_cycles_reg <= 32'd0;
        for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
          desc_per_engine_reg[eng_idx] <= 32'd0;
          output_packets_per_engine_reg[eng_idx] <= 32'd0;
          engine_busy_cycles_reg[eng_idx] <= 32'd0;
          feeder_busy_cycles_reg[eng_idx] <= 32'd0;
          feeder_mem_wait_cycles_shadow_reg[eng_idx] <= 32'd0;
          feeder_axis_stall_cycles_shadow_reg[eng_idx] <= 32'd0;
          feeder_bursts_shadow_reg[eng_idx] <= 32'd0;
          feeder_beats_shadow_reg[eng_idx] <= 32'd0;
          pktbuf_packets_written_shadow_reg[eng_idx] <= 32'd0;
          pktbuf_packets_read_shadow_reg[eng_idx] <= 32'd0;
          pktbuf_write_stall_shadow_reg[eng_idx] <= 32'd0;
          pktbuf_read_stall_shadow_reg[eng_idx] <= 32'd0;
          pktbuf_full_cycles_reg[eng_idx] <= 32'd0;
          completed_packet_wait_cycles_reg[eng_idx] <= 32'd0;
          pktbuf_max_occupancy_shadow_reg[eng_idx] <= '0;
        end
      end

      if (!i_clear_status) begin
        if (s_desc_valid && !s_desc_ready) begin
          stat_stall_input_cycles <= stat_stall_input_cycles + 32'd1;
          desc_stall_cycles_reg <= desc_stall_cycles_reg + 32'd1;
        end
        if (m_axis_comp_tvalid && !m_axis_comp_tready) begin
          stat_stall_output_cycles <= stat_stall_output_cycles + 32'd1;
          output_backpressure_cycles_reg <= output_backpressure_cycles_reg + 32'd1;
        end
        if (!packet_active_reg && packet_candidate_valid && !selected_packet_tvalid) begin
          output_arb_stall_cycles_reg <= output_arb_stall_cycles_reg + 32'd1;
        end
        if (packet_active_reg) begin
          arbiter_active_cycles_reg <= arbiter_active_cycles_reg + 32'd1;
        end else if (!packet_candidate_valid) begin
          arbiter_idle_cycles_reg <= arbiter_idle_cycles_reg + 32'd1;
        end

        for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
          if (eng_stat_busy[eng_idx]) begin
            engine_busy_cycles_reg[eng_idx] <= engine_busy_cycles_reg[eng_idx] + 32'd1;
          end
          if (feeder_busy[eng_idx]) begin
            feeder_busy_cycles_reg[eng_idx] <= feeder_busy_cycles_reg[eng_idx] + 32'd1;
          end
          feeder_mem_wait_cycles_shadow_reg[eng_idx] <= feeder_mem_wait_cycles_sig[eng_idx];
          feeder_axis_stall_cycles_shadow_reg[eng_idx] <= feeder_axis_stall_cycles_sig[eng_idx];
          feeder_bursts_shadow_reg[eng_idx] <= feeder_bursts_issued_sig[eng_idx];
          feeder_beats_shadow_reg[eng_idx] <= feeder_beats_streamed_sig[eng_idx];
          pktbuf_packets_written_shadow_reg[eng_idx] <= pktbuf_packets_written_sig[eng_idx];
          pktbuf_packets_read_shadow_reg[eng_idx] <= pktbuf_packets_read_sig[eng_idx];
          pktbuf_write_stall_shadow_reg[eng_idx] <= pktbuf_write_stall_cycles_sig[eng_idx];
          pktbuf_read_stall_shadow_reg[eng_idx] <= pktbuf_read_stall_cycles_sig[eng_idx];
          pktbuf_max_occupancy_shadow_reg[eng_idx] <= pktbuf_max_occupancy_sig[eng_idx];
          if (pktbuf_full[eng_idx]) begin
            pktbuf_full_cycles_reg[eng_idx] <= pktbuf_full_cycles_reg[eng_idx] + 32'd1;
          end
          if (pktbuf_packet_valid[eng_idx] &&
              (!packet_active_reg || (packet_engine_reg != ENGINE_IDX_W'(eng_idx)))) begin
            completed_packet_wait_cycles_reg[eng_idx] <=
              completed_packet_wait_cycles_reg[eng_idx] + 32'd1;
          end

          if ((stat_error_reg == MRTC_ERR_NONE) && (eng_stat_error[eng_idx] != MRTC_ERR_NONE)) begin
            stat_error_reg <= eng_stat_error[eng_idx];
          end
          if ((stat_error_reg == MRTC_ERR_NONE) && pktbuf_overflow[eng_idx]) begin
            stat_error_reg <= MRTC_ERR_PAYLOAD_TOO_LONG;
          end
        end
      end

      if (desc_fire) begin
        meta_block_id_reg[desc_candidate_engine][meta_wr_ptr_reg[desc_candidate_engine]] <= s_desc_block_id;
        meta_block_range_start_reg[desc_candidate_engine][meta_wr_ptr_reg[desc_candidate_engine]] <=
          s_desc_block_range_start;
        meta_last_block_reg[desc_candidate_engine][meta_wr_ptr_reg[desc_candidate_engine]] <= s_desc_last_block;
        next_ptr = meta_wr_ptr_reg[desc_candidate_engine] + 1;
        if (next_ptr >= META_FIFO_DEPTH) begin
          next_ptr = 0;
        end
        meta_wr_ptr_reg[desc_candidate_engine] <= META_PTR_W'(next_ptr);
        if (!i_clear_status) begin
          desc_dispatched_total_reg <= desc_dispatched_total_reg + 32'd1;
          desc_per_engine_reg[desc_candidate_engine] <=
            desc_per_engine_reg[desc_candidate_engine] + 32'd1;
        end
        desc_rr_ptr_reg <= (desc_candidate_engine == ENGINE_IDX_W'(NUM_ENGINES - 1)) ?
                           '0 : (desc_candidate_engine + ENGINE_IDX_W'(1));
      end

      if (packet_select_fire) begin
        packet_active_reg <= 1'b1;
        packet_engine_reg <= packet_candidate_engine;
        packet_block_id_reg <= packet_candidate_block_id;
        packet_block_range_start_reg <= packet_candidate_block_range_start;
        packet_last_block_reg <= packet_candidate_last_block;
        packet_beat_idx_reg <= '0;
        packet_byte_count_reg <= 32'd0;
        output_rr_ptr_reg <= (packet_candidate_engine == ENGINE_IDX_W'(NUM_ENGINES - 1)) ?
                             '0 : (packet_candidate_engine + ENGINE_IDX_W'(1));
      end

      if (packet_handshake) begin
        beat_bytes = axis_valid_bytes(selected_packet_tlast, selected_packet_tuser);
        if (selected_packet_tlast) begin
          if (meta_count_reg[selected_packet_engine] == META_COUNT_W'(0)) begin
            if (!i_clear_status) begin
              stat_error_reg <= MRTC_ERR_INTERNAL_STATE;
            end
          end else begin
            next_ptr = meta_rd_ptr_reg[selected_packet_engine] + 1;
            if (next_ptr >= META_FIFO_DEPTH) begin
              next_ptr = 0;
            end
            meta_rd_ptr_reg[selected_packet_engine] <= META_PTR_W'(next_ptr);
          end
          if (!i_clear_status) begin
            stat_done <= 1'b1;
            stat_num_blocks <= stat_num_blocks + 32'd1;
            stat_raw_bytes <= stat_raw_bytes + MRTC_RAW_BYTES;
            stat_comp_bytes <= stat_comp_bytes + packet_byte_count_reg + beat_bytes;
            output_packets_total_reg <= output_packets_total_reg + 32'd1;
            output_packets_per_engine_reg[selected_packet_engine] <=
              output_packets_per_engine_reg[selected_packet_engine] + 32'd1;
          end
          packet_active_reg <= 1'b0;
          packet_beat_idx_reg <= '0;
          packet_byte_count_reg <= 32'd0;
          packet_last_block_reg <= 1'b0;
        end else begin
          packet_active_reg <= 1'b1;
          packet_beat_idx_reg <= packet_beat_idx_reg + PACKET_BEAT_IDX_W'(1);
          packet_byte_count_reg <= packet_byte_count_reg + beat_bytes;
        end
      end

      for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
        if (desc_fire && (desc_candidate_engine == ENGINE_IDX_W'(eng_idx)) &&
            !(meta_pop_fire && (selected_packet_engine == ENGINE_IDX_W'(eng_idx)))) begin
          meta_count_reg[eng_idx] <= meta_count_reg[eng_idx] + META_COUNT_W'(1);
        end else if (meta_pop_fire && (selected_packet_engine == ENGINE_IDX_W'(eng_idx)) &&
                     !(desc_fire && (desc_candidate_engine == ENGINE_IDX_W'(eng_idx)))) begin
          meta_count_reg[eng_idx] <= meta_count_reg[eng_idx] - META_COUNT_W'(1);
        end
      end

      any_busy_local = packet_active_reg || (s_desc_valid && !s_desc_ready);
      for (eng_idx = 0; eng_idx < NUM_ENGINES; eng_idx = eng_idx + 1) begin
        any_busy_local = any_busy_local || feeder_busy[eng_idx] || eng_stat_busy[eng_idx] ||
                         (meta_count_reg[eng_idx] != META_COUNT_W'(0)) || pktbuf_busy[eng_idx];
      end
      stat_busy <= any_busy_local;
      stat_error <= i_clear_status ? MRTC_ERR_NONE : stat_error_reg;
    end
  end
endmodule
