module mrtc_rdtc_bounded_axis_multiengine_wrapper #(
  parameter int AXIS_DATA_W = 128,
  parameter int NUM_ENGINES = 2,
  parameter int ENGINE_BOUNDED_WAY_COUNT = 4,
  parameter int PREFIX_SAMPLES = 128,
  parameter int OUTPUT_FIFO_DEPTH = 16
) (
  input  logic                                clk,
  input  logic                                rst_n,
  input  logic                                i_clear_status,

  input  logic                                s_desc_valid,
  output logic                                s_desc_ready,
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

  input  logic [AXIS_DATA_W-1:0]              s_axis_raw_tdata,
  input  logic                                s_axis_raw_tvalid,
  output logic                                s_axis_raw_tready,
  input  logic                                s_axis_raw_tlast,

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
  output logic [31:0]                         stat_stall_output_cycles,
  output logic [31:0]                         stat_desc_accepted,
  output logic [31:0]                         stat_input_blocks,
  output logic [31:0]                         stat_output_packets,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0]
                                              stat_output_fifo_level,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0]
                                              stat_output_fifo_max_level
);
  import mrtc_pkg::*;

  localparam int AXIS_BYTES = AXIS_DATA_W / 8;
  localparam int BLOCK_WORDS = MRTC_BLOCK_SAMPLES / MRTC_LANES;
  localparam int BLOCK_WORD_COUNT_W = $clog2(BLOCK_WORDS + 1);
  localparam int JOB_DEPTH = 2;
  localparam int JOB_COUNT_W = $clog2(JOB_DEPTH + 1);
  localparam int PACKET_BEAT_IDX_W = $clog2((MRTC_MAX_OUTPUT_BYTES / AXIS_BYTES) + 1);
  localparam int FIFO_LEVEL_W = $clog2(OUTPUT_FIFO_DEPTH + 1);
  localparam int AXIS_CHECK = 1 / ((AXIS_DATA_W == 128) ? 1 : 0);
  localparam int ENGINE_CHECK = 1 / ((NUM_ENGINES == 2) ? 1 : 0);
  localparam int WAY_CHECK = 1 / ((ENGINE_BOUNDED_WAY_COUNT == 4) ? 1 : 0);
  localparam int PREFIX_CHECK = 1 / ((PREFIX_SAMPLES == 128) ? 1 : 0);
  localparam int FIFO_CHECK = 1 / ((OUTPUT_FIFO_DEPTH == 16) ? 1 : 0);

  logic [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] eng_axis_raw_tdata;
  logic [NUM_ENGINES-1:0]                  eng_axis_raw_tvalid;
  logic [NUM_ENGINES-1:0]                  eng_axis_raw_tready;
  logic [NUM_ENGINES-1:0]                  eng_axis_raw_tlast;
  logic [NUM_ENGINES-1:0][7:0]             eng_axis_raw_tuser;

  logic [NUM_ENGINES-1:0][AXIS_DATA_W-1:0] eng_axis_comp_tdata;
  logic [NUM_ENGINES-1:0]                  eng_axis_comp_tvalid;
  logic [NUM_ENGINES-1:0]                  eng_axis_comp_tready;
  logic [NUM_ENGINES-1:0]                  eng_axis_comp_tlast;
  logic [NUM_ENGINES-1:0][7:0]             eng_axis_comp_tuser;
  logic [NUM_ENGINES-1:0]                  eng_packet_commit;
  logic [NUM_ENGINES-1:0]                  eng_packet_abort;

  logic [NUM_ENGINES-1:0]                  eng_stat_busy;
  logic [NUM_ENGINES-1:0]                  eng_stat_done;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_error;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_raw_bytes;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_comp_bytes;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_num_blocks;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_stall_input;
  logic [NUM_ENGINES-1:0][31:0]            eng_stat_stall_output;

  logic [NUM_ENGINES-1:0][7:0]             eng_cfg_codec_mode_reg;
  logic [NUM_ENGINES-1:0][7:0]             eng_cfg_rice_mode_reg;
  logic [NUM_ENGINES-1:0][3:0]             eng_cfg_fixed_k_reg;
  logic [NUM_ENGINES-1:0][15:0]            eng_cfg_frame_id_reg;
  logic [NUM_ENGINES-1:0][15:0]            eng_cfg_block_id_reg;
  logic [NUM_ENGINES-1:0][15:0]            eng_cfg_tensor_spatial_reg;
  logic [NUM_ENGINES-1:0][15:0]            eng_cfg_tensor_doppler_reg;
  logic [NUM_ENGINES-1:0][15:0]            eng_cfg_tensor_range_reg;

  logic job_engine_reg [0:JOB_DEPTH-1];
  logic [15:0] job_block_id_reg [0:JOB_DEPTH-1];
  logic [15:0] job_block_range_start_reg [0:JOB_DEPTH-1];
  logic job_last_block_reg [0:JOB_DEPTH-1];
  logic job_wr_ptr_reg;
  logic input_rd_ptr_reg;
  logic output_rd_ptr_reg;
  logic [JOB_COUNT_W-1:0] job_count_reg;
  logic [JOB_COUNT_W-1:0] input_pending_count_reg;
  logic desc_rr_engine_reg;
  logic [NUM_ENGINES-1:0] engine_reserved_reg;
  logic [BLOCK_WORD_COUNT_W-1:0] input_beat_count_reg;
  logic [PACKET_BEAT_IDX_W-1:0] output_beat_idx_reg;
  logic [31:0] external_packet_bytes_reg;

  logic desc_fire;
  logic desc_config_error;
  logic input_fire;
  logic input_expected_last;
  logic input_tlast_error;
  logic input_block_done;
  logic input_unowned_error;
  logic input_engine_stall_error;
  logic output_job_valid;
  logic output_job_done;
  logic output_fifo_push;
  logic output_fifo_credit_exhausted;
  logic output_fifo_pop;
  logic output_fifo_empty;
  logic output_fifo_full;
  logic [FIFO_LEVEL_W-1:0] output_fifo_level;
  logic [FIFO_LEVEL_W-1:0] output_fifo_max_level;
  logic [31:0] output_fifo_push_count;
  logic [31:0] output_fifo_pop_count;

  logic [AXIS_DATA_W-1:0] selected_packet_tdata;
  logic selected_packet_tvalid;
  logic selected_packet_tready;
  logic selected_packet_tlast;
  logic [7:0] selected_packet_tuser;
  logic [AXIS_DATA_W-1:0] patched_packet_tdata;

  logic [AXIS_DATA_W-1:0] fifo_axis_tdata;
  logic fifo_axis_tvalid;
  logic fifo_axis_tready;
  logic fifo_axis_tlast;
  logic [7:0] fifo_axis_tuser;

  logic [31:0] error_code_reg;
  logic engine_error_valid;
  logic [31:0] engine_error_code;
  logic fatal_active;
  logic wrapper_error_event;
  logic [31:0] wrapper_error_code;
  logic any_engine_busy;

  function automatic logic next_job_ptr(input logic ptr);
    next_job_ptr = ~ptr;
  endfunction

  function automatic int axis_valid_bytes(
    input logic axis_last,
    input logic [7:0] axis_user
  );
    if (axis_last) begin
      axis_valid_bytes = int'(axis_user[3:0]) + 1;
    end else begin
      axis_valid_bytes = AXIS_BYTES;
    end
  endfunction

  function automatic logic [AXIS_DATA_W-1:0] patch_header_words(
    input logic [AXIS_DATA_W-1:0] in_data,
    input logic [PACKET_BEAT_IDX_W-1:0] beat_idx,
    input logic [15:0] block_id,
    input logic [15:0] block_range_start,
    input logic last_block
  );
    logic [AXIS_DATA_W-1:0] patched;
    logic [15:0] patched_flags;
    begin
      patched = in_data;
      if (beat_idx == PACKET_BEAT_IDX_W'(0)) begin
        patched[(MRTC_HDR_OFF_BLOCK_ID*8) +: 8] = block_id[7:0];
        patched[((MRTC_HDR_OFF_BLOCK_ID + 1)*8) +: 8] = block_id[15:8];
      end
      if (beat_idx == PACKET_BEAT_IDX_W'(1)) begin
        patched[((MRTC_HDR_OFF_BLOCK_RANGE - AXIS_BYTES)*8) +: 8] =
          block_range_start[7:0];
        patched[(((MRTC_HDR_OFF_BLOCK_RANGE + 1) - AXIS_BYTES)*8) +: 8] =
          block_range_start[15:8];
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
        patched[(((MRTC_HDR_OFF_FLAGS + 1) - AXIS_BYTES)*8) +: 8] =
          patched_flags[15:8];
      end
      patch_header_words = patched;
    end
  endfunction

  generate
    for (genvar engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx++) begin : g_engine
      mrtc_rdtc_encoder_bounded_ht #(
        .AXIS_DATA_W                 (AXIS_DATA_W),
        .WAY_COUNT                   (ENGINE_BOUNDED_WAY_COUNT),
        .WAY_DEPTH_WORDS             (32),
        .PREFIX_SAMPLES              (PREFIX_SAMPLES),
        .PREFIX_FINAL_ACCUM_PIPELINE (1'b1)
      ) u_engine (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .i_clear_status              (i_clear_status),
        .s_axis_raw_tdata            (eng_axis_raw_tdata[engine_idx]),
        .s_axis_raw_tvalid           (eng_axis_raw_tvalid[engine_idx]),
        .s_axis_raw_tready           (eng_axis_raw_tready[engine_idx]),
        .s_axis_raw_tlast            (eng_axis_raw_tlast[engine_idx]),
        .s_axis_raw_tuser            (eng_axis_raw_tuser[engine_idx]),
        .m_axis_comp_tdata           (eng_axis_comp_tdata[engine_idx]),
        .m_axis_comp_tvalid          (eng_axis_comp_tvalid[engine_idx]),
        .m_axis_comp_tready          (eng_axis_comp_tready[engine_idx]),
        .m_axis_comp_tlast           (eng_axis_comp_tlast[engine_idx]),
        .m_axis_comp_tuser           (eng_axis_comp_tuser[engine_idx]),
        .o_packet_commit             (eng_packet_commit[engine_idx]),
        .o_packet_abort              (eng_packet_abort[engine_idx]),
        .cfg_codec_mode              (eng_cfg_codec_mode_reg[engine_idx]),
        .cfg_rice_mode               (eng_cfg_rice_mode_reg[engine_idx]),
        .cfg_fixed_k                 (eng_cfg_fixed_k_reg[engine_idx]),
        .cfg_frame_id                (eng_cfg_frame_id_reg[engine_idx]),
        .cfg_block_id_base           (eng_cfg_block_id_reg[engine_idx]),
        .cfg_tensor_spatial_size     (eng_cfg_tensor_spatial_reg[engine_idx]),
        .cfg_tensor_doppler_size     (eng_cfg_tensor_doppler_reg[engine_idx]),
        .cfg_tensor_range_size       (eng_cfg_tensor_range_reg[engine_idx]),
        .stat_busy                   (eng_stat_busy[engine_idx]),
        .stat_done                   (eng_stat_done[engine_idx]),
        .stat_raw_bytes              (eng_stat_raw_bytes[engine_idx]),
        .stat_comp_bytes             (eng_stat_comp_bytes[engine_idx]),
        .stat_num_blocks             (eng_stat_num_blocks[engine_idx]),
        .stat_error                  (eng_stat_error[engine_idx]),
        .stat_raw_bypass_blocks      (),
        .stat_stall_input_cycles     (eng_stat_stall_input[engine_idx]),
        .stat_stall_output_cycles    (eng_stat_stall_output[engine_idx])
      );
    end
  endgenerate

  always_comb begin
    engine_error_valid = 1'b0;
    engine_error_code = MRTC_ERR_NONE;
    any_engine_busy = 1'b0;
    for (int engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx++) begin
      any_engine_busy = any_engine_busy || eng_stat_busy[engine_idx];
      if (!engine_error_valid && (eng_stat_error[engine_idx] != MRTC_ERR_NONE)) begin
        engine_error_valid = 1'b1;
        engine_error_code = eng_stat_error[engine_idx];
      end
      if (!engine_error_valid && eng_packet_abort[engine_idx]) begin
        engine_error_valid = 1'b1;
        engine_error_code = MRTC_ERR_INTERNAL_STATE;
      end
    end
  end

  assign fatal_active = (error_code_reg != MRTC_ERR_NONE) || engine_error_valid;
  assign stat_error = (error_code_reg != MRTC_ERR_NONE) ? error_code_reg : engine_error_code;

  assign desc_config_error = desc_fire &&
    ((s_desc_codec_mode != MRTC_CODEC_ZERO_RICE) ||
     (s_desc_rice_mode != MRTC_RICE_BLOCK_ADAPTIVE_K));
  assign s_desc_ready = rst_n && !fatal_active &&
                        (job_count_reg < JOB_COUNT_W'(JOB_DEPTH)) &&
                        !engine_reserved_reg[desc_rr_engine_reg] &&
                        !eng_stat_busy[desc_rr_engine_reg];
  assign desc_fire = s_desc_valid && s_desc_ready;

  always_comb begin
    for (int engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx++) begin
      eng_axis_raw_tdata[engine_idx] = s_axis_raw_tdata;
      eng_axis_raw_tvalid[engine_idx] = 1'b0;
      eng_axis_raw_tlast[engine_idx] = s_axis_raw_tlast;
      eng_axis_raw_tuser[engine_idx] = 8'd0;
    end
    s_axis_raw_tready = 1'b0;
    if (!fatal_active && (input_pending_count_reg != JOB_COUNT_W'(0))) begin
      if (job_engine_reg[input_rd_ptr_reg] == 1'b0) begin
        eng_axis_raw_tvalid[0] = s_axis_raw_tvalid;
        eng_axis_raw_tuser[0][0] = job_last_block_reg[input_rd_ptr_reg];
        s_axis_raw_tready = eng_axis_raw_tready[0];
      end else begin
        eng_axis_raw_tvalid[1] = s_axis_raw_tvalid;
        eng_axis_raw_tuser[1][0] = job_last_block_reg[input_rd_ptr_reg];
        s_axis_raw_tready = eng_axis_raw_tready[1];
      end
    end
  end

  assign input_fire = s_axis_raw_tvalid && s_axis_raw_tready;
  assign input_expected_last =
    (input_beat_count_reg == BLOCK_WORD_COUNT_W'(BLOCK_WORDS - 1));
  assign input_tlast_error = input_fire &&
                             (s_axis_raw_tlast != input_expected_last);
  assign input_block_done = input_fire && input_expected_last &&
                            s_axis_raw_tlast && !input_tlast_error;
  assign input_unowned_error = rst_n && !fatal_active &&
                               s_axis_raw_tvalid &&
                               (input_pending_count_reg == JOB_COUNT_W'(0));
  assign input_engine_stall_error = rst_n && !fatal_active &&
                                    s_axis_raw_tvalid &&
                                    (input_pending_count_reg != JOB_COUNT_W'(0)) &&
                                    !s_axis_raw_tready;

  assign output_job_valid = (job_count_reg != JOB_COUNT_W'(0));

  always_comb begin
    eng_axis_comp_tready = '0;
    selected_packet_tdata = '0;
    selected_packet_tvalid = 1'b0;
    selected_packet_tlast = 1'b0;
    selected_packet_tuser = '0;
    if (!fatal_active && output_job_valid) begin
      if (job_engine_reg[output_rd_ptr_reg] == 1'b0) begin
        eng_axis_comp_tready[0] = selected_packet_tready;
        selected_packet_tdata = eng_axis_comp_tdata[0];
        selected_packet_tvalid = eng_axis_comp_tvalid[0];
        selected_packet_tlast = eng_axis_comp_tlast[0];
        selected_packet_tuser = eng_axis_comp_tuser[0];
      end else begin
        eng_axis_comp_tready[1] = selected_packet_tready;
        selected_packet_tdata = eng_axis_comp_tdata[1];
        selected_packet_tvalid = eng_axis_comp_tvalid[1];
        selected_packet_tlast = eng_axis_comp_tlast[1];
        selected_packet_tuser = eng_axis_comp_tuser[1];
      end
    end
  end

  assign patched_packet_tdata = patch_header_words(
    selected_packet_tdata,
    output_beat_idx_reg,
    job_block_id_reg[output_rd_ptr_reg],
    job_block_range_start_reg[output_rd_ptr_reg],
    job_last_block_reg[output_rd_ptr_reg]
  );

  mrtc_axis_bounded_output_fifo #(
    .AXIS_DATA_W (AXIS_DATA_W),
    .TUSER_W     (8),
    .DEPTH_BEATS (OUTPUT_FIFO_DEPTH),
    .LEVEL_W     (FIFO_LEVEL_W)
  ) u_output_fifo (
    .clk                 (clk),
    .rst_n               (rst_n),
    .i_clear_status      (i_clear_status),
    .i_halt              (fatal_active),
    .s_axis_tdata        (patched_packet_tdata),
    .s_axis_tvalid       (selected_packet_tvalid),
    .s_axis_tready       (selected_packet_tready),
    .s_axis_tlast        (selected_packet_tlast),
    .s_axis_tuser        (selected_packet_tuser),
    .m_axis_tdata        (fifo_axis_tdata),
    .m_axis_tvalid       (fifo_axis_tvalid),
    .m_axis_tready       (fifo_axis_tready),
    .m_axis_tlast        (fifo_axis_tlast),
    .m_axis_tuser        (fifo_axis_tuser),
    .o_level             (output_fifo_level),
    .o_max_level         (output_fifo_max_level),
    .o_credit_exhausted  (output_fifo_credit_exhausted),
    .o_push_count        (output_fifo_push_count),
    .o_pop_count         (output_fifo_pop_count)
  );

  assign m_axis_comp_tdata = fifo_axis_tdata;
  assign m_axis_comp_tvalid = fifo_axis_tvalid;
  assign fifo_axis_tready = m_axis_comp_tready;
  assign m_axis_comp_tlast = fifo_axis_tlast;
  assign m_axis_comp_tuser = fifo_axis_tuser;
  assign output_fifo_push = selected_packet_tvalid && selected_packet_tready;
  assign output_job_done = output_fifo_push && selected_packet_tlast;
  assign output_fifo_pop = fifo_axis_tvalid && fifo_axis_tready;
  assign output_fifo_empty = (output_fifo_level == FIFO_LEVEL_W'(0));
  assign output_fifo_full = (output_fifo_level == FIFO_LEVEL_W'(OUTPUT_FIFO_DEPTH));
  assign stat_output_fifo_level = output_fifo_level;
  assign stat_output_fifo_max_level = output_fifo_max_level;

  always_comb begin
    wrapper_error_event = 1'b0;
    wrapper_error_code = MRTC_ERR_NONE;
    if (engine_error_valid) begin
      wrapper_error_event = 1'b1;
      wrapper_error_code = engine_error_code;
    end else if (output_fifo_credit_exhausted) begin
      wrapper_error_event = 1'b1;
      wrapper_error_code = MRTC_ERR_OUTPUT_CREDIT;
    end else if (desc_config_error) begin
      wrapper_error_event = 1'b1;
      wrapper_error_code = (s_desc_codec_mode != MRTC_CODEC_ZERO_RICE) ?
                           MRTC_ERR_UNSUPPORTED_CODEC : MRTC_ERR_UNSUPPORTED_RICE;
    end else if (input_tlast_error) begin
      wrapper_error_event = 1'b1;
      wrapper_error_code = input_expected_last ?
                           MRTC_ERR_INPUT_TOO_SHORT : MRTC_ERR_TLAST_EARLY;
    end else if (input_unowned_error || input_engine_stall_error) begin
      wrapper_error_event = 1'b1;
      wrapper_error_code = MRTC_ERR_BLOCK_NOT_READY;
    end
  end

  assign stat_busy = fatal_active || any_engine_busy ||
                     (job_count_reg != JOB_COUNT_W'(0)) ||
                     (input_pending_count_reg != JOB_COUNT_W'(0)) ||
                     !output_fifo_empty;

  always_ff @(posedge clk or negedge rst_n) begin
    integer beat_bytes;
    if (!rst_n) begin
      job_wr_ptr_reg <= 1'b0;
      input_rd_ptr_reg <= 1'b0;
      output_rd_ptr_reg <= 1'b0;
      job_count_reg <= '0;
      input_pending_count_reg <= '0;
      desc_rr_engine_reg <= 1'b0;
      engine_reserved_reg <= '0;
      input_beat_count_reg <= '0;
      output_beat_idx_reg <= '0;
      external_packet_bytes_reg <= 32'd0;
      error_code_reg <= MRTC_ERR_NONE;
      stat_done <= 1'b0;
      stat_num_blocks <= 32'd0;
      stat_raw_bytes <= 32'd0;
      stat_comp_bytes <= 32'd0;
      stat_stall_input_cycles <= 32'd0;
      stat_stall_output_cycles <= 32'd0;
      stat_desc_accepted <= 32'd0;
      stat_input_blocks <= 32'd0;
      stat_output_packets <= 32'd0;
      for (int engine_idx = 0; engine_idx < NUM_ENGINES; engine_idx++) begin
        eng_cfg_codec_mode_reg[engine_idx] <= MRTC_CODEC_ZERO_RICE;
        eng_cfg_rice_mode_reg[engine_idx] <= MRTC_RICE_BLOCK_ADAPTIVE_K;
        eng_cfg_fixed_k_reg[engine_idx] <= 4'd0;
        eng_cfg_frame_id_reg[engine_idx] <= 16'd0;
        eng_cfg_block_id_reg[engine_idx] <= 16'd0;
        eng_cfg_tensor_spatial_reg[engine_idx] <= 16'd0;
        eng_cfg_tensor_doppler_reg[engine_idx] <= 16'd0;
        eng_cfg_tensor_range_reg[engine_idx] <= 16'd0;
      end
    end else begin
      stat_done <= 1'b0;

      if (wrapper_error_event && (error_code_reg == MRTC_ERR_NONE)) begin
        error_code_reg <= wrapper_error_code;
      end

      unique case ({desc_fire, output_job_done})
        2'b10: job_count_reg <= job_count_reg + JOB_COUNT_W'(1);
        2'b01: job_count_reg <= job_count_reg - JOB_COUNT_W'(1);
        default: begin
        end
      endcase

      unique case ({desc_fire, input_block_done})
        2'b10: input_pending_count_reg <= input_pending_count_reg + JOB_COUNT_W'(1);
        2'b01: input_pending_count_reg <= input_pending_count_reg - JOB_COUNT_W'(1);
        default: begin
        end
      endcase

      if (desc_fire) begin
        job_engine_reg[job_wr_ptr_reg] <= desc_rr_engine_reg;
        job_block_id_reg[job_wr_ptr_reg] <= s_desc_block_id;
        job_block_range_start_reg[job_wr_ptr_reg] <= s_desc_block_range_start;
        job_last_block_reg[job_wr_ptr_reg] <= s_desc_last_block;
        job_wr_ptr_reg <= next_job_ptr(job_wr_ptr_reg);
        engine_reserved_reg[desc_rr_engine_reg] <= 1'b1;
        eng_cfg_codec_mode_reg[desc_rr_engine_reg] <= s_desc_codec_mode;
        eng_cfg_rice_mode_reg[desc_rr_engine_reg] <= s_desc_rice_mode;
        eng_cfg_fixed_k_reg[desc_rr_engine_reg] <= s_desc_fixed_k;
        eng_cfg_frame_id_reg[desc_rr_engine_reg] <= s_desc_frame_id;
        eng_cfg_block_id_reg[desc_rr_engine_reg] <= s_desc_block_id;
        eng_cfg_tensor_spatial_reg[desc_rr_engine_reg] <= s_desc_tensor_spatial_size;
        eng_cfg_tensor_doppler_reg[desc_rr_engine_reg] <= s_desc_tensor_doppler_size;
        eng_cfg_tensor_range_reg[desc_rr_engine_reg] <= s_desc_tensor_range_size;
        desc_rr_engine_reg <= ~desc_rr_engine_reg;
      end

      if (input_fire) begin
        if (input_block_done) begin
          input_rd_ptr_reg <= next_job_ptr(input_rd_ptr_reg);
          input_beat_count_reg <= '0;
        end else if (!input_tlast_error) begin
          input_beat_count_reg <= input_beat_count_reg + BLOCK_WORD_COUNT_W'(1);
        end
      end

      if (output_fifo_push) begin
        if (output_job_done) begin
          engine_reserved_reg[job_engine_reg[output_rd_ptr_reg]] <= 1'b0;
          output_rd_ptr_reg <= next_job_ptr(output_rd_ptr_reg);
          output_beat_idx_reg <= '0;
        end else begin
          output_beat_idx_reg <= output_beat_idx_reg + PACKET_BEAT_IDX_W'(1);
        end
      end

      if (i_clear_status) begin
        stat_num_blocks <= 32'd0;
        stat_raw_bytes <= 32'd0;
        stat_comp_bytes <= 32'd0;
        stat_stall_input_cycles <= 32'd0;
        stat_stall_output_cycles <= 32'd0;
        stat_desc_accepted <= 32'd0;
        stat_input_blocks <= 32'd0;
        stat_output_packets <= 32'd0;
      end else begin
        if (s_axis_raw_tvalid && !s_axis_raw_tready) begin
          stat_stall_input_cycles <= stat_stall_input_cycles + 32'd1;
        end
        if (m_axis_comp_tvalid && !m_axis_comp_tready) begin
          stat_stall_output_cycles <= stat_stall_output_cycles + 32'd1;
        end
        if (desc_fire) begin
          stat_desc_accepted <= stat_desc_accepted + 32'd1;
        end
        if (input_block_done) begin
          stat_input_blocks <= stat_input_blocks + 32'd1;
        end
        if (output_fifo_pop) begin
          beat_bytes = axis_valid_bytes(fifo_axis_tlast, fifo_axis_tuser);
          if (fifo_axis_tlast) begin
            stat_done <= 1'b1;
            stat_num_blocks <= stat_num_blocks + 32'd1;
            stat_raw_bytes <= stat_raw_bytes + 32'(MRTC_RAW_BYTES);
            stat_comp_bytes <= stat_comp_bytes + external_packet_bytes_reg + beat_bytes;
            stat_output_packets <= stat_output_packets + 32'd1;
            external_packet_bytes_reg <= 32'd0;
          end else begin
            external_packet_bytes_reg <= external_packet_bytes_reg + beat_bytes;
          end
        end
      end
    end
  end

  logic unused_static_checks;
  logic unused_engine_observability;
  assign unused_static_checks = ^{AXIS_CHECK[0], ENGINE_CHECK[0], WAY_CHECK[0],
                                  PREFIX_CHECK[0], FIFO_CHECK[0], output_fifo_full};
  assign unused_engine_observability = ^{
    eng_packet_commit,
    eng_stat_done,
    eng_stat_raw_bytes,
    eng_stat_comp_bytes,
    eng_stat_num_blocks,
    eng_stat_stall_input,
    eng_stat_stall_output,
    output_fifo_push_count,
    output_fifo_pop_count
  };
endmodule
