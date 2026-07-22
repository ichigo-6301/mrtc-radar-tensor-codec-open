module mrtc_rdtc_axis2eng_wrapper_nlane #(
  parameter int NUM_LANES = 2,
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = mrtc_pkg::MRTC_COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int TUSER_W = 8,
  parameter int COMP_BLOCK_BYTES = mrtc_pkg::MRTC_COMP_BLOCK_BYTES,
  parameter bit ENABLE_ENGINE_OUT_FIFO = 1'b1,
  parameter int ENGINE_OUT_FIFO_DEPTH_BEATS = 256,
  parameter int ENGINE_OUT_FIFO_IMPL = 0,
`ifdef RDTC_ICARUS
  parameter ENGINE_OUT_FIFO_RAM_STYLE = "block",
`else
  parameter string ENGINE_OUT_FIFO_RAM_STYLE = "block",
`endif
  parameter bit ENABLE_INPUT_CAPTURE_DECOUPLING = 1'b1,
  parameter int CAPTURE_SLOTS_PER_ENGINE = 2,
  parameter int FIFO_LEVEL_W =
    (ENGINE_OUT_FIFO_DEPTH_BEATS <= 1) ? 1 : $clog2(ENGINE_OUT_FIFO_DEPTH_BEATS + 1),
  parameter int LANE_W = (NUM_LANES <= 1) ? 1 : $clog2(NUM_LANES)
) (
  input  logic                                clk,
  input  logic                                rst_n,
  input  logic                                i_clear_status,

  input  logic [NUM_LANES*AXIS_DATA_W-1:0]   s_axis_tdata_flat,
  input  logic [NUM_LANES-1:0]               s_axis_tvalid,
  output logic [NUM_LANES-1:0]               s_axis_tready,
  input  logic [NUM_LANES-1:0]               s_axis_tlast,
  input  logic [NUM_LANES*TUSER_W-1:0]       s_axis_tuser_flat,

  output logic [AXIS_DATA_W-1:0]             m_axis_tdata,
  output logic                               m_axis_tvalid,
  input  logic                               m_axis_tready,
  output logic                               m_axis_tlast,
  output logic [TUSER_W-1:0]                 m_axis_tuser,

  input  logic [7:0]                         cfg_codec_mode,
  input  logic [7:0]                         cfg_rice_mode,
  input  logic [3:0]                         cfg_fixed_k,
  input  logic [15:0]                        cfg_frame_id,
  input  logic [15:0]                        cfg_block_id_base,
  input  logic [15:0]                        cfg_tensor_spatial_size,
  input  logic [15:0]                        cfg_tensor_doppler_size,
  input  logic [15:0]                        cfg_tensor_range_size,

  output logic [NUM_LANES-1:0]               lane_busy,
  output logic [NUM_LANES*32-1:0]            lane_packet_count_flat,
  output logic [NUM_LANES*32-1:0]            lane_error_flat,
  output logic [NUM_LANES*32-1:0]            lane_input_stall_cycles_flat,
  output logic [NUM_LANES*32-1:0]            lane_output_stall_cycles_flat,

  output logic [31:0]                        arbiter_packet_count,
  output logic [LANE_W-1:0]                  arbiter_active_lane,
  output logic                               arbiter_active_valid,
  output logic [31:0]                        arbiter_idle_cycles,
  output logic [31:0]                        arbiter_backpressure_cycles,
  output logic [31:0]                        arbiter_error_flags,

  output logic [NUM_LANES*FIFO_LEVEL_W-1:0]  fifo_level_flat,
  output logic [NUM_LANES-1:0]               fifo_full,
  output logic [NUM_LANES*FIFO_LEVEL_W-1:0]  fifo_max_level_flat,
  output logic [NUM_LANES*32-1:0]            fifo_full_cycles_flat,
  output logic [NUM_LANES-1:0]               fifo_overflow_error,
  output logic [NUM_LANES-1:0]               fifo_underflow_error,

  output logic [NUM_LANES*32-1:0]            capture_accepted_blocks_flat,
  output logic [NUM_LANES*32-1:0]            capture_replayed_blocks_flat,
  output logic [NUM_LANES*32-1:0]            capture_slot_full_cycles_flat,
  output logic [NUM_LANES*32-1:0]            capture_active_input_bubble_cycles_flat,
  output logic [NUM_LANES*32-1:0]            capture_metadata_mismatch_count_flat,
  output logic [NUM_LANES*32-1:0]            capture_error_flags_flat,
  output logic [NUM_LANES*4-1:0]             capture_occupancy_slots_flat,
  output logic [NUM_LANES*4-1:0]             capture_max_occupancy_slots_flat,
  output logic [NUM_LANES*2-1:0]             capture_slot0_state_flat,
  output logic [NUM_LANES*2-1:0]             capture_slot1_state_flat,

  output logic [NUM_LANES*AXIS_DATA_W-1:0]   debug_engine_tdata_flat,
  output logic [NUM_LANES-1:0]               debug_engine_tvalid,
  output logic [NUM_LANES-1:0]               debug_engine_tready,
  output logic [NUM_LANES-1:0]               debug_engine_tlast,
  output logic [NUM_LANES*TUSER_W-1:0]       debug_engine_tuser_flat,
  output logic [NUM_LANES*AXIS_DATA_W-1:0]   debug_arb_tdata_flat,
  output logic [NUM_LANES-1:0]               debug_arb_tvalid,
  output logic [NUM_LANES-1:0]               debug_arb_tready,
  output logic [NUM_LANES-1:0]               debug_arb_tlast,
  output logic [NUM_LANES*TUSER_W-1:0]       debug_arb_tuser_flat
);
  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int BLOCK_BEATS = COMP_BLOCK_BYTES / AXIS_BYTES;
  localparam int NUM_LANES_CHECK =
    1 / (((NUM_LANES == 2) || (NUM_LANES == 4)) ? 1 : 0);
  localparam int PHASE_CHECK = 1 / ((PHASES_PER_BEAT == 4) ? 1 : 0);
  localparam int AXIS_CHECK =
    1 / ((AXIS_DATA_W == (mrtc_pkg::MRTC_COMPLEX_SAMPLE_W * PHASES_PER_BEAT)) ? 1 : 0);
  localparam int TUSER_CHECK = 1 / ((TUSER_W == 8) ? 1 : 0);
  localparam int COMP_BLOCK_BYTES_CHECK = 1 / ((COMP_BLOCK_BYTES == 4096) ? 1 : 0);
  localparam int BLOCK_ALIGN_CHECK = 1 / (((COMP_BLOCK_BYTES % AXIS_BYTES) == 0) ? 1 : 0);

  logic [AXIS_DATA_W-1:0] s_lane_tdata [0:NUM_LANES-1];
  logic [TUSER_W-1:0] s_lane_tuser [0:NUM_LANES-1];

  logic [AXIS_DATA_W-1:0] raw_tdata [0:NUM_LANES-1];
  logic raw_tvalid [0:NUM_LANES-1];
  logic raw_tready [0:NUM_LANES-1];
  logic raw_tlast [0:NUM_LANES-1];
  logic [TUSER_W-1:0] raw_tuser [0:NUM_LANES-1];

  logic [AXIS_DATA_W-1:0] engine_tdata [0:NUM_LANES-1];
  logic engine_tvalid [0:NUM_LANES-1];
  logic engine_tready [0:NUM_LANES-1];
  logic engine_tlast [0:NUM_LANES-1];
  logic [TUSER_W-1:0] engine_tuser [0:NUM_LANES-1];

  logic [AXIS_DATA_W-1:0] arb_lane_tdata [0:NUM_LANES-1];
  logic [NUM_LANES*AXIS_DATA_W-1:0] arb_tdata_flat;
  logic [NUM_LANES-1:0] arb_tvalid;
  logic [NUM_LANES-1:0] arb_tready;
  logic [NUM_LANES-1:0] arb_tlast;
  logic [TUSER_W-1:0] arb_lane_tuser [0:NUM_LANES-1];
  logic [NUM_LANES*TUSER_W-1:0] arb_tuser_flat;

  logic [31:0] lane_packet_count [0:NUM_LANES-1];
  logic [31:0] lane_error [0:NUM_LANES-1];
  logic [31:0] lane_input_stall_cycles [0:NUM_LANES-1];
  logic [31:0] lane_output_stall_cycles [0:NUM_LANES-1];

  logic [FIFO_LEVEL_W-1:0] fifo_level [0:NUM_LANES-1];
  logic [FIFO_LEVEL_W-1:0] fifo_max_level [0:NUM_LANES-1];
  logic [31:0] fifo_full_cycles [0:NUM_LANES-1];

  logic [31:0] capture_accepted_blocks [0:NUM_LANES-1];
  logic [31:0] capture_replay_started_blocks [0:NUM_LANES-1];
  logic [31:0] capture_replayed_blocks [0:NUM_LANES-1];
  logic [31:0] capture_slot_full_cycles [0:NUM_LANES-1];
  logic [31:0] capture_active_input_bubble_cycles [0:NUM_LANES-1];
  logic [31:0] capture_metadata_mismatch_count [0:NUM_LANES-1];
  logic [31:0] capture_error_flags [0:NUM_LANES-1];
  logic [3:0] capture_occupancy_slots [0:NUM_LANES-1];
  logic [3:0] capture_max_occupancy_slots [0:NUM_LANES-1];
  logic [1:0] capture_slot0_state [0:NUM_LANES-1];
  logic [1:0] capture_slot1_state [0:NUM_LANES-1];

  logic unused_done [0:NUM_LANES-1];
  logic [31:0] unused_raw_bytes [0:NUM_LANES-1];
  logic [31:0] unused_comp_bytes [0:NUM_LANES-1];
  logic [31:0] unused_raw_bypass_blocks [0:NUM_LANES-1];

  generate
    genvar lane_idx;
    for (lane_idx = 0; lane_idx < NUM_LANES; lane_idx = lane_idx + 1) begin : g_lane
      localparam logic [15:0] LANE_BLOCK_ID_OFFSET = 16'(lane_idx);
      logic fifo_empty_unused;

      assign s_lane_tdata[lane_idx] =
        s_axis_tdata_flat[(lane_idx * AXIS_DATA_W) +: AXIS_DATA_W];
      assign s_lane_tuser[lane_idx] =
        s_axis_tuser_flat[(lane_idx * TUSER_W) +: TUSER_W];

      if (ENABLE_INPUT_CAPTURE_DECOUPLING) begin : g_input_capture_decoupling
        mrtc_axis_raw_block_capture_replay #(
          .AXIS_DATA_W             (AXIS_DATA_W),
          .TUSER_W                 (TUSER_W),
          .BLOCK_BEATS             (BLOCK_BEATS),
          .CAPTURE_SLOTS_PER_ENGINE(CAPTURE_SLOTS_PER_ENGINE)
        ) u_capture (
          .clk                             (clk),
          .rst_n                           (rst_n),
          .i_clear_status                  (i_clear_status),
          .i_replay_start_ready            (!lane_busy[lane_idx]),
          .s_axis_tdata                    (s_lane_tdata[lane_idx]),
          .s_axis_tvalid                   (s_axis_tvalid[lane_idx]),
          .s_axis_tready                   (s_axis_tready[lane_idx]),
          .s_axis_tlast                    (s_axis_tlast[lane_idx]),
          .s_axis_tuser                    (s_lane_tuser[lane_idx]),
          .m_axis_tdata                    (raw_tdata[lane_idx]),
          .m_axis_tvalid                   (raw_tvalid[lane_idx]),
          .m_axis_tready                   (raw_tready[lane_idx]),
          .m_axis_tlast                    (raw_tlast[lane_idx]),
          .m_axis_tuser                    (raw_tuser[lane_idx]),
          .stat_capture_accepted_blocks    (capture_accepted_blocks[lane_idx]),
          .stat_replay_started_blocks      (capture_replay_started_blocks[lane_idx]),
          .stat_replay_completed_blocks    (capture_replayed_blocks[lane_idx]),
          .stat_slot_full_cycles           (capture_slot_full_cycles[lane_idx]),
          .stat_active_input_bubble_cycles (capture_active_input_bubble_cycles[lane_idx]),
          .stat_metadata_mismatch_count    (capture_metadata_mismatch_count[lane_idx]),
          .stat_error_flags                (capture_error_flags[lane_idx]),
          .stat_current_occupancy_slots    (capture_occupancy_slots[lane_idx]),
          .stat_max_occupancy_slots        (capture_max_occupancy_slots[lane_idx]),
          .stat_slot0_state                (capture_slot0_state[lane_idx]),
          .stat_slot1_state                (capture_slot1_state[lane_idx])
        );
      end else begin : g_direct_engine_input
        assign raw_tdata[lane_idx] = s_lane_tdata[lane_idx];
        assign raw_tvalid[lane_idx] = s_axis_tvalid[lane_idx];
        assign s_axis_tready[lane_idx] = raw_tready[lane_idx];
        assign raw_tlast[lane_idx] = s_axis_tlast[lane_idx];
        assign raw_tuser[lane_idx] = s_lane_tuser[lane_idx];
        assign capture_accepted_blocks[lane_idx] = 32'd0;
        assign capture_replay_started_blocks[lane_idx] = 32'd0;
        assign capture_replayed_blocks[lane_idx] = 32'd0;
        assign capture_slot_full_cycles[lane_idx] = 32'd0;
        assign capture_active_input_bubble_cycles[lane_idx] = 32'd0;
        assign capture_metadata_mismatch_count[lane_idx] = 32'd0;
        assign capture_error_flags[lane_idx] = 32'd0;
        assign capture_occupancy_slots[lane_idx] = 4'd0;
        assign capture_max_occupancy_slots[lane_idx] = 4'd0;
        assign capture_slot0_state[lane_idx] = 2'd0;
        assign capture_slot1_state[lane_idx] = 2'd0;
      end

      mrtc_rdtc_engine_lane #(
        .PHASES_PER_BEAT           (PHASES_PER_BEAT),
        .AXIS_DATA_W               (AXIS_DATA_W),
        .COMP_BLOCK_BYTES          (COMP_BLOCK_BYTES),
        .PREFIX_COMPLEX_SAMPLES    (mrtc_pkg::MRTC_PREFIX_COMPLEX_SAMPLES)
      ) u_engine (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .i_soft_reset            (1'b0),
        .i_clear_status          (i_clear_status),
        .s_axis_raw_tdata        (raw_tdata[lane_idx]),
        .s_axis_raw_tvalid       (raw_tvalid[lane_idx]),
        .s_axis_raw_tready       (raw_tready[lane_idx]),
        .s_axis_raw_tlast        (raw_tlast[lane_idx]),
        .s_axis_raw_tuser        (raw_tuser[lane_idx]),
        .m_axis_comp_tdata       (engine_tdata[lane_idx]),
        .m_axis_comp_tvalid      (engine_tvalid[lane_idx]),
        .m_axis_comp_tready      (engine_tready[lane_idx]),
        .m_axis_comp_tlast       (engine_tlast[lane_idx]),
        .m_axis_comp_tuser       (engine_tuser[lane_idx]),
        .cfg_codec_mode          (cfg_codec_mode),
        .cfg_rice_mode           (cfg_rice_mode),
        .cfg_fixed_k             (cfg_fixed_k),
        .cfg_frame_id            (cfg_frame_id),
        .cfg_block_id            (cfg_block_id_base + LANE_BLOCK_ID_OFFSET),
        .cfg_tensor_spatial_size (cfg_tensor_spatial_size),
        .cfg_tensor_doppler_size (cfg_tensor_doppler_size),
        .cfg_tensor_range_size   (cfg_tensor_range_size),
        .stat_busy               (lane_busy[lane_idx]),
        .stat_done               (unused_done[lane_idx]),
        .stat_raw_bytes          (unused_raw_bytes[lane_idx]),
        .stat_comp_bytes         (unused_comp_bytes[lane_idx]),
        .stat_num_blocks         (lane_packet_count[lane_idx]),
        .stat_error              (lane_error[lane_idx]),
        .stat_raw_bypass_blocks  (unused_raw_bypass_blocks[lane_idx]),
        .stat_stall_input_cycles (lane_input_stall_cycles[lane_idx]),
        .stat_stall_output_cycles(lane_output_stall_cycles[lane_idx])
      );

      if (ENABLE_ENGINE_OUT_FIFO && (ENGINE_OUT_FIFO_DEPTH_BEATS > 0)) begin : g_engine_out_fifo
        mrtc_axis_fifo_wrapper #(
          .AXIS_DATA_W    (AXIS_DATA_W),
          .TUSER_W        (TUSER_W),
          .DEPTH_BEATS    (ENGINE_OUT_FIFO_DEPTH_BEATS),
          .FIFO_IMPL      (ENGINE_OUT_FIFO_IMPL),
`ifdef RDTC_ICARUS
          .FPGA_RAM_STYLE ("block"),
`else
          .FPGA_RAM_STYLE (ENGINE_OUT_FIFO_RAM_STYLE),
`endif
          .LEVEL_W        (FIFO_LEVEL_W)
        ) u_fifo (
          .clk              (clk),
          .rst_n            (rst_n),
          .i_clear_status   (i_clear_status),
          .s_axis_tdata     (engine_tdata[lane_idx]),
          .s_axis_tvalid    (engine_tvalid[lane_idx]),
          .s_axis_tready    (engine_tready[lane_idx]),
          .s_axis_tlast     (engine_tlast[lane_idx]),
          .s_axis_tuser     (engine_tuser[lane_idx]),
          .m_axis_tdata     (arb_lane_tdata[lane_idx]),
          .m_axis_tvalid    (arb_tvalid[lane_idx]),
          .m_axis_tready    (arb_tready[lane_idx]),
          .m_axis_tlast     (arb_tlast[lane_idx]),
          .m_axis_tuser     (arb_lane_tuser[lane_idx]),
          .o_level          (fifo_level[lane_idx]),
          .o_full           (fifo_full[lane_idx]),
          .o_empty          (fifo_empty_unused),
          .o_overflow_error (fifo_overflow_error[lane_idx]),
          .o_underflow_error(fifo_underflow_error[lane_idx]),
          .o_max_level      (fifo_max_level[lane_idx]),
          .o_full_cycles    (fifo_full_cycles[lane_idx])
        );
      end else begin : g_no_engine_out_fifo
        assign arb_lane_tdata[lane_idx] = engine_tdata[lane_idx];
        assign arb_tvalid[lane_idx] = engine_tvalid[lane_idx];
        assign engine_tready[lane_idx] = arb_tready[lane_idx];
        assign arb_tlast[lane_idx] = engine_tlast[lane_idx];
        assign arb_lane_tuser[lane_idx] = engine_tuser[lane_idx];
        assign fifo_level[lane_idx] = '0;
        assign fifo_full[lane_idx] = 1'b0;
        assign fifo_max_level[lane_idx] = '0;
        assign fifo_full_cycles[lane_idx] = 32'd0;
        assign fifo_overflow_error[lane_idx] = 1'b0;
        assign fifo_underflow_error[lane_idx] = 1'b0;
      end

      assign arb_tdata_flat[(lane_idx * AXIS_DATA_W) +: AXIS_DATA_W] =
        arb_lane_tdata[lane_idx];
      assign arb_tuser_flat[(lane_idx * TUSER_W) +: TUSER_W] =
        arb_lane_tuser[lane_idx];
      assign debug_engine_tdata_flat[(lane_idx * AXIS_DATA_W) +: AXIS_DATA_W] =
        engine_tdata[lane_idx];
      assign debug_engine_tvalid[lane_idx] = engine_tvalid[lane_idx];
      assign debug_engine_tready[lane_idx] = engine_tready[lane_idx];
      assign debug_engine_tlast[lane_idx] = engine_tlast[lane_idx];
      assign debug_engine_tuser_flat[(lane_idx * TUSER_W) +: TUSER_W] =
        engine_tuser[lane_idx];
      assign debug_arb_tdata_flat[(lane_idx * AXIS_DATA_W) +: AXIS_DATA_W] =
        arb_lane_tdata[lane_idx];
      assign debug_arb_tvalid[lane_idx] = arb_tvalid[lane_idx];
      assign debug_arb_tready[lane_idx] = arb_tready[lane_idx];
      assign debug_arb_tlast[lane_idx] = arb_tlast[lane_idx];
      assign debug_arb_tuser_flat[(lane_idx * TUSER_W) +: TUSER_W] =
        arb_lane_tuser[lane_idx];

      assign lane_packet_count_flat[(lane_idx * 32) +: 32] =
        lane_packet_count[lane_idx];
      assign lane_error_flat[(lane_idx * 32) +: 32] =
        lane_error[lane_idx];
      assign lane_input_stall_cycles_flat[(lane_idx * 32) +: 32] =
        lane_input_stall_cycles[lane_idx];
      assign lane_output_stall_cycles_flat[(lane_idx * 32) +: 32] =
        lane_output_stall_cycles[lane_idx];
      assign fifo_level_flat[(lane_idx * FIFO_LEVEL_W) +: FIFO_LEVEL_W] =
        fifo_level[lane_idx];
      assign fifo_max_level_flat[(lane_idx * FIFO_LEVEL_W) +: FIFO_LEVEL_W] =
        fifo_max_level[lane_idx];
      assign fifo_full_cycles_flat[(lane_idx * 32) +: 32] =
        fifo_full_cycles[lane_idx];
      assign capture_accepted_blocks_flat[(lane_idx * 32) +: 32] =
        capture_accepted_blocks[lane_idx];
      assign capture_replayed_blocks_flat[(lane_idx * 32) +: 32] =
        capture_replayed_blocks[lane_idx];
      assign capture_slot_full_cycles_flat[(lane_idx * 32) +: 32] =
        capture_slot_full_cycles[lane_idx];
      assign capture_active_input_bubble_cycles_flat[(lane_idx * 32) +: 32] =
        capture_active_input_bubble_cycles[lane_idx];
      assign capture_metadata_mismatch_count_flat[(lane_idx * 32) +: 32] =
        capture_metadata_mismatch_count[lane_idx];
      assign capture_error_flags_flat[(lane_idx * 32) +: 32] =
        capture_error_flags[lane_idx];
      assign capture_occupancy_slots_flat[(lane_idx * 4) +: 4] =
        capture_occupancy_slots[lane_idx];
      assign capture_max_occupancy_slots_flat[(lane_idx * 4) +: 4] =
        capture_max_occupancy_slots[lane_idx];
      assign capture_slot0_state_flat[(lane_idx * 2) +: 2] =
        capture_slot0_state[lane_idx];
      assign capture_slot1_state_flat[(lane_idx * 2) +: 2] =
        capture_slot1_state[lane_idx];
    end
  endgenerate

  mrtc_axis_packet_arbiter_nlane #(
    .NUM_LANES  (NUM_LANES),
    .AXIS_DATA_W(AXIS_DATA_W),
    .TUSER_W    (TUSER_W),
    .LANE_W     (LANE_W)
  ) u_packet_arbiter (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .s_axis_tdata_flat         (arb_tdata_flat),
    .s_axis_tvalid             (arb_tvalid),
    .s_axis_tready             (arb_tready),
    .s_axis_tlast              (arb_tlast),
    .s_axis_tuser_flat         (arb_tuser_flat),
    .m_axis_tdata              (m_axis_tdata),
    .m_axis_tvalid             (m_axis_tvalid),
    .m_axis_tready             (m_axis_tready),
    .m_axis_tlast              (m_axis_tlast),
    .m_axis_tuser              (m_axis_tuser),
    .o_active_lane             (arbiter_active_lane),
    .o_active_valid            (arbiter_active_valid),
    .o_packet_count            (arbiter_packet_count),
    .o_idle_cycles             (arbiter_idle_cycles),
    .o_backpressure_cycles     (arbiter_backpressure_cycles),
    .o_error_flags             (arbiter_error_flags)
  );

  logic unused_static_checks;
  assign unused_static_checks = ^{1'b0, NUM_LANES_CHECK[0], PHASE_CHECK[0], AXIS_CHECK[0],
                                  TUSER_CHECK[0], COMP_BLOCK_BYTES_CHECK[0],
                                  BLOCK_ALIGN_CHECK[0]};
endmodule
