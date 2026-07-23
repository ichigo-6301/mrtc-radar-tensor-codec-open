module mrtc_rdtc_axis32_wrapper #(
  parameter int IN_AXIS_DATA_W = 32,
  parameter int CORE_AXIS_DATA_W = mrtc_pkg::MRTC_AXIS_DATA_W,
  parameter int TUSER_W = 8,
  parameter int COMP_BLOCK_BYTES = mrtc_pkg::MRTC_COMP_BLOCK_BYTES,
  parameter bit ENABLE_ENGINE_OUT_FIFO = 1'b1,
  parameter int ENGINE_OUT_FIFO_DEPTH_BEATS = 256,
  parameter int ENGINE_OUT_FIFO_IMPL = 0,
`ifdef RDTC_ICARUS
  parameter ENGINE_OUT_FIFO_RAM_STYLE = "block"
`else
  parameter string ENGINE_OUT_FIFO_RAM_STYLE = "block"
`endif
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         i_clear_status,

  input  logic [IN_AXIS_DATA_W-1:0]    s_axis_tdata,
  input  logic [(IN_AXIS_DATA_W/8)-1:0] s_axis_tkeep,
  input  logic                         s_axis_tvalid,
  output logic                         s_axis_tready,
  input  logic                         s_axis_tlast,
  input  logic [TUSER_W-1:0]           s_axis_tuser,

  output logic [IN_AXIS_DATA_W-1:0]    m_axis_tdata,
  output logic [(IN_AXIS_DATA_W/8)-1:0] m_axis_tkeep,
  output logic                         m_axis_tvalid,
  input  logic                         m_axis_tready,
  output logic                         m_axis_tlast,
  output logic [TUSER_W-1:0]           m_axis_tuser,

  input  logic [7:0]                   cfg_codec_mode,
  input  logic [7:0]                   cfg_rice_mode,
  input  logic [3:0]                   cfg_fixed_k,
  input  logic [15:0]                  cfg_frame_id,
  input  logic [15:0]                  cfg_block_id_base,
  input  logic [15:0]                  cfg_tensor_spatial_size,
  input  logic [15:0]                  cfg_tensor_doppler_size,
  input  logic [15:0]                  cfg_tensor_range_size,

  output logic [31:0]                  stat_input_beat_count,
  output logic [31:0]                  stat_input_byte_count,
  output logic [31:0]                  stat_input_stall_cycles,
  output logic [31:0]                  stat_input_tkeep_error_count,
  output logic [31:0]                  stat_input_tlast_error_count,
  output logic [31:0]                  stat_packed_core_beat_count,
  output logic [31:0]                  stat_output_beat_count,
  output logic [31:0]                  stat_output_byte_count,
  output logic [31:0]                  stat_output_packet_count,
  output logic [31:0]                  stat_output_backpressure_cycles,
  output logic [31:0]                  stat_output_last_tkeep,
  output logic [31:0]                  stat_core_packet_count,
  output logic [31:0]                  stat_core_error_flags
);
  import mrtc_pkg::*;

  localparam int IN_AXIS_BYTES = IN_AXIS_DATA_W / 8;
  localparam int CORE_AXIS_BYTES = CORE_AXIS_DATA_W / 8;
  localparam int PACK_RATIO = CORE_AXIS_DATA_W / IN_AXIS_DATA_W;
  localparam int INPUT_BEATS_PER_BLOCK = COMP_BLOCK_BYTES / IN_AXIS_BYTES;
  localparam int PACK_COUNT_W = (PACK_RATIO <= 1) ? 1 : $clog2(PACK_RATIO);
  localparam int CORE_BYTE_COUNT_W = $clog2(CORE_AXIS_BYTES + 1);
  localparam int INPUT_WIDTH_CHECK = 1 / ((IN_AXIS_DATA_W == 32) ? 1 : 0);
  localparam int CORE_WIDTH_CHECK = 1 / ((CORE_AXIS_DATA_W == 128) ? 1 : 0);
  localparam int PACK_ALIGN_CHECK = 1 / (((CORE_AXIS_DATA_W % IN_AXIS_DATA_W) == 0) ? 1 : 0);
  localparam int BLOCK_ALIGN_CHECK = 1 / (((COMP_BLOCK_BYTES % IN_AXIS_BYTES) == 0) ? 1 : 0);

  logic [CORE_AXIS_DATA_W-1:0] pack_data_reg;
  logic [PACK_COUNT_W-1:0] pack_count_reg;
  logic [31:0] block_input_beat_idx_reg;
  logic [TUSER_W-1:0] block_tuser_reg;
  logic in_block_reg;

  logic [CORE_AXIS_DATA_W-1:0] core_s_tdata_reg;
  logic core_s_tvalid_reg;
  logic core_s_tready;
  logic core_s_tlast_reg;
  logic [TUSER_W-1:0] core_s_tuser_reg;

  logic [CORE_AXIS_DATA_W-1:0] core_m_tdata;
  logic core_m_tvalid;
  logic core_m_tready;
  logic core_m_tlast;
  logic [TUSER_W-1:0] core_m_tuser;

  logic [CORE_AXIS_DATA_W-1:0] ser_data_reg;
  logic [TUSER_W-1:0] ser_user_reg;
  logic [CORE_BYTE_COUNT_W-1:0] ser_byte_offset_reg;
  logic [CORE_BYTE_COUNT_W-1:0] ser_bytes_remaining_reg;
  logic ser_last_reg;
  logic ser_active_reg;

  logic engine0_busy;
  logic engine1_busy;
  logic [31:0] engine0_packet_count;
  logic [31:0] engine1_packet_count;
  logic [31:0] engine0_error;
  logic [31:0] engine1_error;
  logic [31:0] engine0_input_stall_cycles;
  logic [31:0] engine1_input_stall_cycles;
  logic [31:0] engine0_output_stall_cycles;
  logic [31:0] engine1_output_stall_cycles;
  logic [31:0] arbiter_packet_count;
  logic arbiter_active_engine;
  logic arbiter_active_valid;
  logic [31:0] arbiter_idle_cycles;
  logic [31:0] arbiter_backpressure_cycles;
  logic [31:0] arbiter_error_flags;
  logic [8:0] fifo0_level;
  logic [8:0] fifo1_level;
  logic fifo0_full;
  logic fifo1_full;
  logic [8:0] fifo0_max_level;
  logic [8:0] fifo1_max_level;
  logic [31:0] fifo0_full_cycles;
  logic [31:0] fifo1_full_cycles;
  logic fifo0_overflow_error;
  logic fifo1_overflow_error;
  logic fifo0_underflow_error;
  logic fifo1_underflow_error;
  logic [31:0] capture0_accepted_blocks;
  logic [31:0] capture1_accepted_blocks;
  logic [31:0] capture0_replayed_blocks;
  logic [31:0] capture1_replayed_blocks;
  logic [31:0] capture0_slot_full_cycles;
  logic [31:0] capture1_slot_full_cycles;
  logic [31:0] capture0_active_input_bubble_cycles;
  logic [31:0] capture1_active_input_bubble_cycles;
  logic [31:0] capture0_metadata_mismatch_count;
  logic [31:0] capture1_metadata_mismatch_count;
  logic [31:0] capture0_error_flags;
  logic [31:0] capture1_error_flags;
  logic [3:0] capture0_occupancy_slots;
  logic [3:0] capture1_occupancy_slots;
  logic [3:0] capture0_max_occupancy_slots;
  logic [3:0] capture1_max_occupancy_slots;
  logic [1:0] capture0_slot0_state;
  logic [1:0] capture0_slot1_state;
  logic [1:0] capture1_slot0_state;
  logic [1:0] capture1_slot1_state;

  logic s_fire;
  logic core_in_fire;
  logic can_form_core_beat;
  logic forming_core_beat;
  logic core_out_fire;
  logic m_fire;
  logic [CORE_AXIS_DATA_W-1:0] formed_core_data;
  logic formed_core_last;
  logic [TUSER_W-1:0] formed_core_user;
  logic [CORE_BYTE_COUNT_W-1:0] core_m_valid_bytes;
  logic [2:0] out_valid_bytes;

  assign can_form_core_beat = !core_s_tvalid_reg || core_s_tready;
  assign s_axis_tready = rst_n &&
                         ((pack_count_reg != PACK_COUNT_W'(PACK_RATIO - 1)) ||
                          can_form_core_beat);
  assign s_fire = s_axis_tvalid && s_axis_tready;
  assign core_in_fire = core_s_tvalid_reg && core_s_tready;
  assign forming_core_beat = s_fire && (pack_count_reg == PACK_COUNT_W'(PACK_RATIO - 1));
  assign formed_core_last = (block_input_beat_idx_reg == 32'(INPUT_BEATS_PER_BLOCK - 1));
  assign formed_core_user = in_block_reg ? block_tuser_reg : s_axis_tuser;
  assign core_m_tready = !ser_active_reg;
  assign core_out_fire = core_m_tvalid && core_m_tready;
  assign m_fire = m_axis_tvalid && m_axis_tready;
  assign core_m_valid_bytes = core_m_tlast ?
                              (CORE_BYTE_COUNT_W'({4'd0, core_m_tuser[3:0]}) +
                               CORE_BYTE_COUNT_W'(1)) :
                              CORE_BYTE_COUNT_W'(CORE_AXIS_BYTES);

  always_comb begin
    formed_core_data = pack_data_reg;
    formed_core_data[(PACK_RATIO - 1) * IN_AXIS_DATA_W +: IN_AXIS_DATA_W] = s_axis_tdata;
  end

  function automatic logic [IN_AXIS_BYTES-1:0] keep_mask(input int valid_bytes);
    logic [IN_AXIS_BYTES-1:0] mask;
    begin
      mask = '0;
      for (int idx = 0; idx < IN_AXIS_BYTES; idx = idx + 1) begin
        mask[idx] = (idx < valid_bytes);
      end
      return mask;
    end
  endfunction

  always_comb begin
    int bytes_i;
    bytes_i = (int'(ser_bytes_remaining_reg) >= IN_AXIS_BYTES) ?
              IN_AXIS_BYTES : int'(ser_bytes_remaining_reg);
    out_valid_bytes = 3'(bytes_i);
    m_axis_tdata = ser_data_reg[(int'(ser_byte_offset_reg) * 8) +: IN_AXIS_DATA_W];
    m_axis_tkeep = keep_mask(bytes_i);
    m_axis_tvalid = ser_active_reg;
    m_axis_tlast = ser_active_reg && ser_last_reg &&
                   (int'(ser_bytes_remaining_reg) <= IN_AXIS_BYTES);
    m_axis_tuser = ser_user_reg;
    m_axis_tuser[3:0] = (bytes_i == 0) ? 4'd0 : (4'(bytes_i) - 4'd1);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pack_data_reg <= '0;
      pack_count_reg <= '0;
      block_input_beat_idx_reg <= 32'd0;
      block_tuser_reg <= '0;
      in_block_reg <= 1'b0;
      core_s_tdata_reg <= '0;
      core_s_tvalid_reg <= 1'b0;
      core_s_tlast_reg <= 1'b0;
      core_s_tuser_reg <= '0;
      stat_input_beat_count <= 32'd0;
      stat_input_byte_count <= 32'd0;
      stat_input_stall_cycles <= 32'd0;
      stat_input_tkeep_error_count <= 32'd0;
      stat_input_tlast_error_count <= 32'd0;
      stat_packed_core_beat_count <= 32'd0;
    end else begin
      if (i_clear_status) begin
        stat_input_beat_count <= 32'd0;
        stat_input_byte_count <= 32'd0;
        stat_input_stall_cycles <= 32'd0;
        stat_input_tkeep_error_count <= 32'd0;
        stat_input_tlast_error_count <= 32'd0;
        stat_packed_core_beat_count <= 32'd0;
      end else begin
        if (s_axis_tvalid && !s_axis_tready) begin
          stat_input_stall_cycles <= stat_input_stall_cycles + 32'd1;
        end
        if (s_fire) begin
          stat_input_beat_count <= stat_input_beat_count + 32'd1;
          stat_input_byte_count <= stat_input_byte_count + 32'(IN_AXIS_BYTES);
          if (s_axis_tkeep != {IN_AXIS_BYTES{1'b1}}) begin
            stat_input_tkeep_error_count <= stat_input_tkeep_error_count + 32'd1;
          end
          if (s_axis_tlast != (block_input_beat_idx_reg == 32'(INPUT_BEATS_PER_BLOCK - 1))) begin
            stat_input_tlast_error_count <= stat_input_tlast_error_count + 32'd1;
          end
          if (forming_core_beat) begin
            stat_packed_core_beat_count <= stat_packed_core_beat_count + 32'd1;
          end
        end
      end

      if (core_in_fire && !forming_core_beat) begin
        core_s_tvalid_reg <= 1'b0;
        core_s_tdata_reg <= '0;
        core_s_tlast_reg <= 1'b0;
        core_s_tuser_reg <= '0;
      end

      if (s_fire) begin
        if (!in_block_reg) begin
          block_tuser_reg <= s_axis_tuser;
          in_block_reg <= 1'b1;
        end

        if (forming_core_beat) begin
          core_s_tdata_reg <= formed_core_data;
          core_s_tvalid_reg <= 1'b1;
          core_s_tlast_reg <= formed_core_last;
          core_s_tuser_reg <= formed_core_user;
          pack_data_reg <= '0;
          pack_count_reg <= '0;
        end else begin
          pack_data_reg[int'(pack_count_reg) * IN_AXIS_DATA_W +: IN_AXIS_DATA_W] <= s_axis_tdata;
          pack_count_reg <= pack_count_reg + PACK_COUNT_W'(1);
        end

        if (block_input_beat_idx_reg == 32'(INPUT_BEATS_PER_BLOCK - 1)) begin
          block_input_beat_idx_reg <= 32'd0;
          in_block_reg <= 1'b0;
        end else begin
          block_input_beat_idx_reg <= block_input_beat_idx_reg + 32'd1;
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ser_data_reg <= '0;
      ser_user_reg <= '0;
      ser_byte_offset_reg <= '0;
      ser_bytes_remaining_reg <= '0;
      ser_last_reg <= 1'b0;
      ser_active_reg <= 1'b0;
      stat_output_beat_count <= 32'd0;
      stat_output_byte_count <= 32'd0;
      stat_output_packet_count <= 32'd0;
      stat_output_backpressure_cycles <= 32'd0;
      stat_output_last_tkeep <= 32'd0;
    end else begin
      if (i_clear_status) begin
        stat_output_beat_count <= 32'd0;
        stat_output_byte_count <= 32'd0;
        stat_output_packet_count <= 32'd0;
        stat_output_backpressure_cycles <= 32'd0;
        stat_output_last_tkeep <= 32'd0;
      end else begin
        if (m_axis_tvalid && !m_axis_tready) begin
          stat_output_backpressure_cycles <= stat_output_backpressure_cycles + 32'd1;
        end
        if (m_fire) begin
          stat_output_beat_count <= stat_output_beat_count + 32'd1;
          stat_output_byte_count <= stat_output_byte_count + {29'd0, out_valid_bytes};
          if (m_axis_tlast) begin
            stat_output_packet_count <= stat_output_packet_count + 32'd1;
            stat_output_last_tkeep <= {28'd0, m_axis_tkeep};
          end
        end
      end

      if (m_fire) begin
        if (int'(ser_bytes_remaining_reg) <= IN_AXIS_BYTES) begin
          ser_active_reg <= 1'b0;
          ser_data_reg <= '0;
          ser_user_reg <= '0;
          ser_byte_offset_reg <= '0;
          ser_bytes_remaining_reg <= '0;
          ser_last_reg <= 1'b0;
        end else begin
          ser_byte_offset_reg <= ser_byte_offset_reg + CORE_BYTE_COUNT_W'(IN_AXIS_BYTES);
          ser_bytes_remaining_reg <= ser_bytes_remaining_reg - CORE_BYTE_COUNT_W'(IN_AXIS_BYTES);
        end
      end

      if (core_out_fire) begin
        ser_data_reg <= core_m_tdata;
        ser_user_reg <= core_m_tuser;
        ser_byte_offset_reg <= '0;
        ser_bytes_remaining_reg <= core_m_valid_bytes;
        ser_last_reg <= core_m_tlast;
        ser_active_reg <= 1'b1;
      end
    end
  end

  // This historical AXIS32 adapter drives only input 0 of the two-input
  // wrapper. It validates width conversion and one active codec stream; it
  // is not evidence of concurrent dual-input FPGA operation.
  mrtc_rdtc_axis2eng_wrapper #(
    .AXIS_DATA_W                   (CORE_AXIS_DATA_W),
    .TUSER_W                       (TUSER_W),
    .COMP_BLOCK_BYTES              (COMP_BLOCK_BYTES),
    .ENABLE_ENGINE_OUT_FIFO        (ENABLE_ENGINE_OUT_FIFO),
    .ENGINE_OUT_FIFO_DEPTH_BEATS   (ENGINE_OUT_FIFO_DEPTH_BEATS),
    .ENGINE_OUT_FIFO_IMPL          (ENGINE_OUT_FIFO_IMPL),
`ifdef RDTC_ICARUS
    .ENGINE_OUT_FIFO_RAM_STYLE     ("block"),
`else
    .ENGINE_OUT_FIFO_RAM_STYLE     (ENGINE_OUT_FIFO_RAM_STYLE),
`endif
    .ENABLE_INPUT_CAPTURE_DECOUPLING(1'b1),
    .CAPTURE_SLOTS_PER_ENGINE      (2)
  ) u_core_wrapper (
    .clk                         (clk),
    .rst_n                       (rst_n),
    .i_clear_status              (i_clear_status),
    .s0_axis_tdata               (core_s_tdata_reg),
    .s0_axis_tvalid              (core_s_tvalid_reg),
    .s0_axis_tready              (core_s_tready),
    .s0_axis_tlast               (core_s_tlast_reg),
    .s0_axis_tuser               (core_s_tuser_reg),
    .s1_axis_tdata               ('0),
    .s1_axis_tvalid              (1'b0),
    .s1_axis_tready              (),
    .s1_axis_tlast               (1'b0),
    .s1_axis_tuser               ('0),
    .m_axis_tdata                (core_m_tdata),
    .m_axis_tvalid               (core_m_tvalid),
    .m_axis_tready               (core_m_tready),
    .m_axis_tlast                (core_m_tlast),
    .m_axis_tuser                (core_m_tuser),
    .cfg_codec_mode              (cfg_codec_mode),
    .cfg_rice_mode               (cfg_rice_mode),
    .cfg_fixed_k                 (cfg_fixed_k),
    .cfg_frame_id                (cfg_frame_id),
    .cfg_block_id_base           (cfg_block_id_base),
    .cfg_tensor_spatial_size     (cfg_tensor_spatial_size),
    .cfg_tensor_doppler_size     (cfg_tensor_doppler_size),
    .cfg_tensor_range_size       (cfg_tensor_range_size),
    .engine0_busy                (engine0_busy),
    .engine1_busy                (engine1_busy),
    .engine0_packet_count        (engine0_packet_count),
    .engine1_packet_count        (engine1_packet_count),
    .engine0_error               (engine0_error),
    .engine1_error               (engine1_error),
    .engine0_input_stall_cycles  (engine0_input_stall_cycles),
    .engine1_input_stall_cycles  (engine1_input_stall_cycles),
    .engine0_output_stall_cycles (engine0_output_stall_cycles),
    .engine1_output_stall_cycles (engine1_output_stall_cycles),
    .arbiter_packet_count        (arbiter_packet_count),
    .arbiter_active_engine       (arbiter_active_engine),
    .arbiter_active_valid        (arbiter_active_valid),
    .arbiter_idle_cycles         (arbiter_idle_cycles),
    .arbiter_backpressure_cycles (arbiter_backpressure_cycles),
    .arbiter_error_flags         (arbiter_error_flags),
    .fifo0_level                 (fifo0_level),
    .fifo1_level                 (fifo1_level),
    .fifo0_full                  (fifo0_full),
    .fifo1_full                  (fifo1_full),
    .fifo0_max_level             (fifo0_max_level),
    .fifo1_max_level             (fifo1_max_level),
    .fifo0_full_cycles           (fifo0_full_cycles),
    .fifo1_full_cycles           (fifo1_full_cycles),
    .fifo0_overflow_error        (fifo0_overflow_error),
    .fifo1_overflow_error        (fifo1_overflow_error),
    .fifo0_underflow_error       (fifo0_underflow_error),
    .fifo1_underflow_error       (fifo1_underflow_error),
    .capture0_accepted_blocks    (capture0_accepted_blocks),
    .capture1_accepted_blocks    (capture1_accepted_blocks),
    .capture0_replayed_blocks    (capture0_replayed_blocks),
    .capture1_replayed_blocks    (capture1_replayed_blocks),
    .capture0_slot_full_cycles   (capture0_slot_full_cycles),
    .capture1_slot_full_cycles   (capture1_slot_full_cycles),
    .capture0_active_input_bubble_cycles(capture0_active_input_bubble_cycles),
    .capture1_active_input_bubble_cycles(capture1_active_input_bubble_cycles),
    .capture0_metadata_mismatch_count(capture0_metadata_mismatch_count),
    .capture1_metadata_mismatch_count(capture1_metadata_mismatch_count),
    .capture0_error_flags        (capture0_error_flags),
    .capture1_error_flags        (capture1_error_flags),
    .capture0_occupancy_slots    (capture0_occupancy_slots),
    .capture1_occupancy_slots    (capture1_occupancy_slots),
    .capture0_max_occupancy_slots(capture0_max_occupancy_slots),
    .capture1_max_occupancy_slots(capture1_max_occupancy_slots),
    .capture0_slot0_state        (capture0_slot0_state),
    .capture0_slot1_state        (capture0_slot1_state),
    .capture1_slot0_state        (capture1_slot0_state),
    .capture1_slot1_state        (capture1_slot1_state)
  );

  always_comb begin
    stat_core_packet_count = arbiter_packet_count;
    stat_core_error_flags = engine0_error | engine1_error | arbiter_error_flags |
                            {31'd0, fifo0_overflow_error | fifo1_overflow_error |
                                    fifo0_underflow_error | fifo1_underflow_error} |
                            capture0_error_flags | capture1_error_flags;
  end

  logic unused_static_checks;
  assign unused_static_checks = ^{1'b0, INPUT_WIDTH_CHECK[0], CORE_WIDTH_CHECK[0],
                                  PACK_ALIGN_CHECK[0], BLOCK_ALIGN_CHECK[0],
                                  cfg_codec_mode, cfg_rice_mode, cfg_fixed_k,
                                  engine0_busy, engine1_busy,
                                  engine0_input_stall_cycles, engine1_input_stall_cycles,
                                  engine0_output_stall_cycles, engine1_output_stall_cycles,
                                  arbiter_active_engine, arbiter_active_valid,
                                  arbiter_idle_cycles, arbiter_backpressure_cycles,
                                  fifo0_level, fifo1_level, fifo0_full, fifo1_full,
                                  fifo0_max_level, fifo1_max_level,
                                  fifo0_full_cycles, fifo1_full_cycles,
                                  capture0_accepted_blocks, capture1_accepted_blocks,
                                  capture0_replayed_blocks, capture1_replayed_blocks,
                                  capture0_slot_full_cycles, capture1_slot_full_cycles,
                                  capture0_active_input_bubble_cycles,
                                  capture1_active_input_bubble_cycles,
                                  capture0_metadata_mismatch_count,
                                  capture1_metadata_mismatch_count,
                                  capture0_occupancy_slots, capture1_occupancy_slots,
                                  capture0_max_occupancy_slots, capture1_max_occupancy_slots,
                                  capture0_slot0_state, capture0_slot1_state,
                                  capture1_slot0_state, capture1_slot1_state};
endmodule
