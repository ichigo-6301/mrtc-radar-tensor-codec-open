module mrtc_rdtc_axis2eng_wrapper #(
  parameter int NUM_LANES = 2,
  parameter int PHASES_PER_BEAT = mrtc_pkg::MRTC_PHASES_PER_BEAT,
  parameter int AXIS_DATA_W = mrtc_pkg::MRTC_COMPLEX_SAMPLE_W * PHASES_PER_BEAT,
  parameter int TUSER_W     = 8,
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
    (ENGINE_OUT_FIFO_DEPTH_BEATS <= 1) ? 1 : $clog2(ENGINE_OUT_FIFO_DEPTH_BEATS + 1)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   i_clear_status,
  input  logic [AXIS_DATA_W-1:0] s0_axis_tdata,
  input  logic                   s0_axis_tvalid,
  output logic                   s0_axis_tready,
  input  logic                   s0_axis_tlast,
  input  logic [TUSER_W-1:0]     s0_axis_tuser,
  input  logic [AXIS_DATA_W-1:0] s1_axis_tdata,
  input  logic                   s1_axis_tvalid,
  output logic                   s1_axis_tready,
  input  logic                   s1_axis_tlast,
  input  logic [TUSER_W-1:0]     s1_axis_tuser,
  output logic [AXIS_DATA_W-1:0] m_axis_tdata,
  output logic                   m_axis_tvalid,
  input  logic                   m_axis_tready,
  output logic                   m_axis_tlast,
  output logic [TUSER_W-1:0]     m_axis_tuser,
  input  logic [7:0]             cfg_codec_mode,
  input  logic [7:0]             cfg_rice_mode,
  input  logic [3:0]             cfg_fixed_k,
  input  logic [15:0]            cfg_frame_id,
  input  logic [15:0]            cfg_block_id_base,
  input  logic [15:0]            cfg_tensor_spatial_size,
  input  logic [15:0]            cfg_tensor_doppler_size,
  input  logic [15:0]            cfg_tensor_range_size,
  output logic                   engine0_busy,
  output logic                   engine1_busy,
  output logic [31:0]            engine0_packet_count,
  output logic [31:0]            engine1_packet_count,
  output logic [31:0]            engine0_error,
  output logic [31:0]            engine1_error,
  output logic [31:0]            engine0_input_stall_cycles,
  output logic [31:0]            engine1_input_stall_cycles,
  output logic [31:0]            engine0_output_stall_cycles,
  output logic [31:0]            engine1_output_stall_cycles,
  output logic [31:0]            arbiter_packet_count,
  output logic                   arbiter_active_engine,
  output logic                   arbiter_active_valid,
  output logic [31:0]            arbiter_idle_cycles,
  output logic [31:0]            arbiter_backpressure_cycles,
  output logic [31:0]            arbiter_error_flags,
  output logic [FIFO_LEVEL_W-1:0] fifo0_level,
  output logic [FIFO_LEVEL_W-1:0] fifo1_level,
  output logic                   fifo0_full,
  output logic                   fifo1_full,
  output logic [FIFO_LEVEL_W-1:0] fifo0_max_level,
  output logic [FIFO_LEVEL_W-1:0] fifo1_max_level,
  output logic [31:0]            fifo0_full_cycles,
  output logic [31:0]            fifo1_full_cycles,
  output logic                   fifo0_overflow_error,
  output logic                   fifo1_overflow_error,
  output logic                   fifo0_underflow_error,
  output logic                   fifo1_underflow_error,
  output logic [31:0]            capture0_accepted_blocks,
  output logic [31:0]            capture1_accepted_blocks,
  output logic [31:0]            capture0_replayed_blocks,
  output logic [31:0]            capture1_replayed_blocks,
  output logic [31:0]            capture0_slot_full_cycles,
  output logic [31:0]            capture1_slot_full_cycles,
  output logic [31:0]            capture0_active_input_bubble_cycles,
  output logic [31:0]            capture1_active_input_bubble_cycles,
  output logic [31:0]            capture0_metadata_mismatch_count,
  output logic [31:0]            capture1_metadata_mismatch_count,
  output logic [31:0]            capture0_error_flags,
  output logic [31:0]            capture1_error_flags,
  output logic [3:0]             capture0_occupancy_slots,
  output logic [3:0]             capture1_occupancy_slots,
  output logic [3:0]             capture0_max_occupancy_slots,
  output logic [3:0]             capture1_max_occupancy_slots,
  output logic [1:0]             capture0_slot0_state,
  output logic [1:0]             capture0_slot1_state,
  output logic [1:0]             capture1_slot0_state,
  output logic [1:0]             capture1_slot1_state
);
  localparam int NUM_LANES_CHECK = 1 / ((NUM_LANES == 2) ? 1 : 0);
  localparam int LANE_W = (NUM_LANES <= 1) ? 1 : $clog2(NUM_LANES);

  logic [NUM_LANES*AXIS_DATA_W-1:0] s_axis_tdata_flat;
  logic [NUM_LANES-1:0] s_axis_tvalid;
  logic [NUM_LANES-1:0] s_axis_tready;
  logic [NUM_LANES-1:0] s_axis_tlast;
  logic [NUM_LANES*TUSER_W-1:0] s_axis_tuser_flat;

  logic [NUM_LANES-1:0] lane_busy;
  logic [NUM_LANES*32-1:0] lane_packet_count_flat;
  logic [NUM_LANES*32-1:0] lane_error_flat;
  logic [NUM_LANES*32-1:0] lane_input_stall_cycles_flat;
  logic [NUM_LANES*32-1:0] lane_output_stall_cycles_flat;
  logic [LANE_W-1:0] arbiter_active_lane;
  logic [NUM_LANES*FIFO_LEVEL_W-1:0] fifo_level_flat;
  logic [NUM_LANES-1:0] fifo_full;
  logic [NUM_LANES*FIFO_LEVEL_W-1:0] fifo_max_level_flat;
  logic [NUM_LANES*32-1:0] fifo_full_cycles_flat;
  logic [NUM_LANES-1:0] fifo_overflow_error;
  logic [NUM_LANES-1:0] fifo_underflow_error;
  logic [NUM_LANES*32-1:0] capture_accepted_blocks_flat;
  logic [NUM_LANES*32-1:0] capture_replayed_blocks_flat;
  logic [NUM_LANES*32-1:0] capture_slot_full_cycles_flat;
  logic [NUM_LANES*32-1:0] capture_active_input_bubble_cycles_flat;
  logic [NUM_LANES*32-1:0] capture_metadata_mismatch_count_flat;
  logic [NUM_LANES*32-1:0] capture_error_flags_flat;
  logic [NUM_LANES*4-1:0] capture_occupancy_slots_flat;
  logic [NUM_LANES*4-1:0] capture_max_occupancy_slots_flat;
  logic [NUM_LANES*2-1:0] capture_slot0_state_flat;
  logic [NUM_LANES*2-1:0] capture_slot1_state_flat;
  logic [NUM_LANES*AXIS_DATA_W-1:0] debug_engine_tdata_flat;
  logic [NUM_LANES-1:0] debug_engine_tvalid;
  logic [NUM_LANES-1:0] debug_engine_tready;
  logic [NUM_LANES-1:0] debug_engine_tlast;
  logic [NUM_LANES*TUSER_W-1:0] debug_engine_tuser_flat;
  logic [NUM_LANES*AXIS_DATA_W-1:0] debug_arb_tdata_flat;
  logic [NUM_LANES-1:0] debug_arb_tvalid;
  logic [NUM_LANES-1:0] debug_arb_tready;
  logic [NUM_LANES-1:0] debug_arb_tlast;
  logic [NUM_LANES*TUSER_W-1:0] debug_arb_tuser_flat;

  logic [AXIS_DATA_W-1:0] e0_tdata;
  logic e0_tvalid;
  logic e0_tready;
  logic e0_tlast;
  logic [TUSER_W-1:0] e0_tuser;
  logic [AXIS_DATA_W-1:0] e1_tdata;
  logic e1_tvalid;
  logic e1_tready;
  logic e1_tlast;
  logic [TUSER_W-1:0] e1_tuser;
  logic [AXIS_DATA_W-1:0] arb_s0_tdata;
  logic arb_s0_tvalid;
  logic arb_s0_tready;
  logic arb_s0_tlast;
  logic [TUSER_W-1:0] arb_s0_tuser;
  logic [AXIS_DATA_W-1:0] arb_s1_tdata;
  logic arb_s1_tvalid;
  logic arb_s1_tready;
  logic arb_s1_tlast;
  logic [TUSER_W-1:0] arb_s1_tuser;

  assign s_axis_tdata_flat[(0 * AXIS_DATA_W) +: AXIS_DATA_W] = s0_axis_tdata;
  assign s_axis_tdata_flat[(1 * AXIS_DATA_W) +: AXIS_DATA_W] = s1_axis_tdata;
  assign s_axis_tvalid = {s1_axis_tvalid, s0_axis_tvalid};
  assign s0_axis_tready = s_axis_tready[0];
  assign s1_axis_tready = s_axis_tready[1];
  assign s_axis_tlast = {s1_axis_tlast, s0_axis_tlast};
  assign s_axis_tuser_flat[(0 * TUSER_W) +: TUSER_W] = s0_axis_tuser;
  assign s_axis_tuser_flat[(1 * TUSER_W) +: TUSER_W] = s1_axis_tuser;

  assign engine0_busy = lane_busy[0];
  assign engine1_busy = lane_busy[1];
  assign engine0_packet_count = lane_packet_count_flat[(0 * 32) +: 32];
  assign engine1_packet_count = lane_packet_count_flat[(1 * 32) +: 32];
  assign engine0_error = lane_error_flat[(0 * 32) +: 32];
  assign engine1_error = lane_error_flat[(1 * 32) +: 32];
  assign engine0_input_stall_cycles = lane_input_stall_cycles_flat[(0 * 32) +: 32];
  assign engine1_input_stall_cycles = lane_input_stall_cycles_flat[(1 * 32) +: 32];
  assign engine0_output_stall_cycles = lane_output_stall_cycles_flat[(0 * 32) +: 32];
  assign engine1_output_stall_cycles = lane_output_stall_cycles_flat[(1 * 32) +: 32];
  assign arbiter_active_engine = arbiter_active_lane[0];
  assign fifo0_level = fifo_level_flat[(0 * FIFO_LEVEL_W) +: FIFO_LEVEL_W];
  assign fifo1_level = fifo_level_flat[(1 * FIFO_LEVEL_W) +: FIFO_LEVEL_W];
  assign fifo0_full = fifo_full[0];
  assign fifo1_full = fifo_full[1];
  assign fifo0_max_level = fifo_max_level_flat[(0 * FIFO_LEVEL_W) +: FIFO_LEVEL_W];
  assign fifo1_max_level = fifo_max_level_flat[(1 * FIFO_LEVEL_W) +: FIFO_LEVEL_W];
  assign fifo0_full_cycles = fifo_full_cycles_flat[(0 * 32) +: 32];
  assign fifo1_full_cycles = fifo_full_cycles_flat[(1 * 32) +: 32];
  assign fifo0_overflow_error = fifo_overflow_error[0];
  assign fifo1_overflow_error = fifo_overflow_error[1];
  assign fifo0_underflow_error = fifo_underflow_error[0];
  assign fifo1_underflow_error = fifo_underflow_error[1];
  assign capture0_accepted_blocks = capture_accepted_blocks_flat[(0 * 32) +: 32];
  assign capture1_accepted_blocks = capture_accepted_blocks_flat[(1 * 32) +: 32];
  assign capture0_replayed_blocks = capture_replayed_blocks_flat[(0 * 32) +: 32];
  assign capture1_replayed_blocks = capture_replayed_blocks_flat[(1 * 32) +: 32];
  assign capture0_slot_full_cycles = capture_slot_full_cycles_flat[(0 * 32) +: 32];
  assign capture1_slot_full_cycles = capture_slot_full_cycles_flat[(1 * 32) +: 32];
  assign capture0_active_input_bubble_cycles =
    capture_active_input_bubble_cycles_flat[(0 * 32) +: 32];
  assign capture1_active_input_bubble_cycles =
    capture_active_input_bubble_cycles_flat[(1 * 32) +: 32];
  assign capture0_metadata_mismatch_count =
    capture_metadata_mismatch_count_flat[(0 * 32) +: 32];
  assign capture1_metadata_mismatch_count =
    capture_metadata_mismatch_count_flat[(1 * 32) +: 32];
  assign capture0_error_flags = capture_error_flags_flat[(0 * 32) +: 32];
  assign capture1_error_flags = capture_error_flags_flat[(1 * 32) +: 32];
  assign capture0_occupancy_slots = capture_occupancy_slots_flat[(0 * 4) +: 4];
  assign capture1_occupancy_slots = capture_occupancy_slots_flat[(1 * 4) +: 4];
  assign capture0_max_occupancy_slots = capture_max_occupancy_slots_flat[(0 * 4) +: 4];
  assign capture1_max_occupancy_slots = capture_max_occupancy_slots_flat[(1 * 4) +: 4];
  assign capture0_slot0_state = capture_slot0_state_flat[(0 * 2) +: 2];
  assign capture0_slot1_state = capture_slot1_state_flat[(0 * 2) +: 2];
  assign capture1_slot0_state = capture_slot0_state_flat[(1 * 2) +: 2];
  assign capture1_slot1_state = capture_slot1_state_flat[(1 * 2) +: 2];
  assign e0_tdata = debug_engine_tdata_flat[(0 * AXIS_DATA_W) +: AXIS_DATA_W];
  assign e1_tdata = debug_engine_tdata_flat[(1 * AXIS_DATA_W) +: AXIS_DATA_W];
  assign e0_tvalid = debug_engine_tvalid[0];
  assign e1_tvalid = debug_engine_tvalid[1];
  assign e0_tready = debug_engine_tready[0];
  assign e1_tready = debug_engine_tready[1];
  assign e0_tlast = debug_engine_tlast[0];
  assign e1_tlast = debug_engine_tlast[1];
  assign e0_tuser = debug_engine_tuser_flat[(0 * TUSER_W) +: TUSER_W];
  assign e1_tuser = debug_engine_tuser_flat[(1 * TUSER_W) +: TUSER_W];
  assign arb_s0_tdata = debug_arb_tdata_flat[(0 * AXIS_DATA_W) +: AXIS_DATA_W];
  assign arb_s1_tdata = debug_arb_tdata_flat[(1 * AXIS_DATA_W) +: AXIS_DATA_W];
  assign arb_s0_tvalid = debug_arb_tvalid[0];
  assign arb_s1_tvalid = debug_arb_tvalid[1];
  assign arb_s0_tready = debug_arb_tready[0];
  assign arb_s1_tready = debug_arb_tready[1];
  assign arb_s0_tlast = debug_arb_tlast[0];
  assign arb_s1_tlast = debug_arb_tlast[1];
  assign arb_s0_tuser = debug_arb_tuser_flat[(0 * TUSER_W) +: TUSER_W];
  assign arb_s1_tuser = debug_arb_tuser_flat[(1 * TUSER_W) +: TUSER_W];

  mrtc_rdtc_axis2eng_wrapper_nlane #(
    .NUM_LANES                    (NUM_LANES),
    .PHASES_PER_BEAT              (PHASES_PER_BEAT),
    .AXIS_DATA_W                  (AXIS_DATA_W),
    .TUSER_W                      (TUSER_W),
    .COMP_BLOCK_BYTES             (COMP_BLOCK_BYTES),
    .ENABLE_ENGINE_OUT_FIFO       (ENABLE_ENGINE_OUT_FIFO),
    .ENGINE_OUT_FIFO_DEPTH_BEATS  (ENGINE_OUT_FIFO_DEPTH_BEATS),
    .ENGINE_OUT_FIFO_IMPL         (ENGINE_OUT_FIFO_IMPL),
`ifdef RDTC_ICARUS
    .ENGINE_OUT_FIFO_RAM_STYLE    ("block"),
`else
    .ENGINE_OUT_FIFO_RAM_STYLE    (ENGINE_OUT_FIFO_RAM_STYLE),
`endif
    .ENABLE_INPUT_CAPTURE_DECOUPLING(ENABLE_INPUT_CAPTURE_DECOUPLING),
    .CAPTURE_SLOTS_PER_ENGINE     (CAPTURE_SLOTS_PER_ENGINE),
    .FIFO_LEVEL_W                 (FIFO_LEVEL_W),
    .LANE_W                       (LANE_W)
  ) u_nlane (
    .clk                                   (clk),
    .rst_n                                 (rst_n),
    .i_clear_status                        (i_clear_status),
    .s_axis_tdata_flat                     (s_axis_tdata_flat),
    .s_axis_tvalid                         (s_axis_tvalid),
    .s_axis_tready                         (s_axis_tready),
    .s_axis_tlast                          (s_axis_tlast),
    .s_axis_tuser_flat                     (s_axis_tuser_flat),
    .m_axis_tdata                          (m_axis_tdata),
    .m_axis_tvalid                         (m_axis_tvalid),
    .m_axis_tready                         (m_axis_tready),
    .m_axis_tlast                          (m_axis_tlast),
    .m_axis_tuser                          (m_axis_tuser),
    .cfg_codec_mode                        (cfg_codec_mode),
    .cfg_rice_mode                         (cfg_rice_mode),
    .cfg_fixed_k                           (cfg_fixed_k),
    .cfg_frame_id                          (cfg_frame_id),
    .cfg_block_id_base                     (cfg_block_id_base),
    .cfg_tensor_spatial_size               (cfg_tensor_spatial_size),
    .cfg_tensor_doppler_size               (cfg_tensor_doppler_size),
    .cfg_tensor_range_size                 (cfg_tensor_range_size),
    .lane_busy                             (lane_busy),
    .lane_packet_count_flat                (lane_packet_count_flat),
    .lane_error_flat                       (lane_error_flat),
    .lane_input_stall_cycles_flat          (lane_input_stall_cycles_flat),
    .lane_output_stall_cycles_flat         (lane_output_stall_cycles_flat),
    .arbiter_packet_count                  (arbiter_packet_count),
    .arbiter_active_lane                   (arbiter_active_lane),
    .arbiter_active_valid                  (arbiter_active_valid),
    .arbiter_idle_cycles                   (arbiter_idle_cycles),
    .arbiter_backpressure_cycles           (arbiter_backpressure_cycles),
    .arbiter_error_flags                   (arbiter_error_flags),
    .fifo_level_flat                       (fifo_level_flat),
    .fifo_full                             (fifo_full),
    .fifo_max_level_flat                   (fifo_max_level_flat),
    .fifo_full_cycles_flat                 (fifo_full_cycles_flat),
    .fifo_overflow_error                   (fifo_overflow_error),
    .fifo_underflow_error                  (fifo_underflow_error),
    .capture_accepted_blocks_flat          (capture_accepted_blocks_flat),
    .capture_replayed_blocks_flat          (capture_replayed_blocks_flat),
    .capture_slot_full_cycles_flat         (capture_slot_full_cycles_flat),
    .capture_active_input_bubble_cycles_flat(capture_active_input_bubble_cycles_flat),
    .capture_metadata_mismatch_count_flat  (capture_metadata_mismatch_count_flat),
    .capture_error_flags_flat              (capture_error_flags_flat),
    .capture_occupancy_slots_flat          (capture_occupancy_slots_flat),
    .capture_max_occupancy_slots_flat      (capture_max_occupancy_slots_flat),
    .capture_slot0_state_flat              (capture_slot0_state_flat),
    .capture_slot1_state_flat              (capture_slot1_state_flat),
    .debug_engine_tdata_flat               (debug_engine_tdata_flat),
    .debug_engine_tvalid                   (debug_engine_tvalid),
    .debug_engine_tready                   (debug_engine_tready),
    .debug_engine_tlast                    (debug_engine_tlast),
    .debug_engine_tuser_flat               (debug_engine_tuser_flat),
    .debug_arb_tdata_flat                  (debug_arb_tdata_flat),
    .debug_arb_tvalid                      (debug_arb_tvalid),
    .debug_arb_tready                      (debug_arb_tready),
    .debug_arb_tlast                       (debug_arb_tlast),
    .debug_arb_tuser_flat                  (debug_arb_tuser_flat)
  );

  logic unused_static_checks;
  assign unused_static_checks = NUM_LANES_CHECK[0];
endmodule
