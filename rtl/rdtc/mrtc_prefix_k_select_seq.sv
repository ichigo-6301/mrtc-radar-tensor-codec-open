module mrtc_prefix_k_select_seq #(
  parameter int PREFIX_SAMPLES = 256,
  parameter int BLOCK_SAMPLES  = 1024,
  parameter int ADDR_W         = 10
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              i_start,
  input  logic [7:0]        i_codec_mode,
  output logic              o_rd_req,
  output logic [ADDR_W-1:0] o_rd_addr,
  input  logic              i_rd_valid,
  input  logic [31:0]       i_rd_data,
  output logic              o_busy,
  output logic              o_done,
  output logic [7:0]        o_selected_k,
  output logic [31:0]       o_prefix_bits,
  output logic              o_unsupported_codec
);
  import mrtc_pkg::*;

  typedef enum logic [3:0] {
    ST_IDLE        = 4'd0,
    ST_REQ         = 4'd1,
    ST_WAIT        = 4'd2,
    ST_ACCUM_REQ   = 4'd3,
    ST_REDUCE_L0   = 4'd4,
    ST_REDUCE_L1   = 4'd5,
    ST_REDUCE_L2   = 4'd6,
    ST_REDUCE_L3   = 4'd7,
    ST_FINAL_WRITE = 4'd8,
    ST_DONE        = 4'd9
  } state_t;

  localparam int K_COUNT = 16;
  localparam int RED0_COUNT = K_COUNT / 2;
  localparam int RED1_COUNT = RED0_COUNT / 2;
  localparam int RED2_COUNT = RED1_COUNT / 2;
  localparam int PREFIX_SAMPLES_POSITIVE_CHECK =
    1 / ((PREFIX_SAMPLES > 0) ? 1 : 0);
  localparam int PREFIX_SAMPLES_LIMIT_CHECK =
    1 / ((PREFIX_SAMPLES <= BLOCK_SAMPLES) ? 1 : 0);
  localparam int PREFIX_SAMPLES_LANE_ALIGN_CHECK =
    1 / (((PREFIX_SAMPLES % MRTC_LANES) == 0) ? 1 : 0);

  state_t            state_reg;
  logic [7:0]        codec_mode_reg;
  logic [ADDR_W-1:0] sample_idx_reg;
  logic signed [15:0] prev_i_reg;
  logic signed [15:0] prev_q_reg;
  logic [31:0]       rd_data_reg;
  logic [ADDR_W-1:0] rd_sample_idx_reg;
  logic signed [15:0] rd_prev_i_reg;
  logic signed [15:0] rd_prev_q_reg;
  logic              rd_last_sample_reg;
  logic [63:0]       cand_bits_reg [0:K_COUNT-1];
  logic [63:0]       red0_bits_reg [0:RED0_COUNT-1];
  logic [7:0]        red0_k_reg    [0:RED0_COUNT-1];
  logic [63:0]       red1_bits_reg [0:RED1_COUNT-1];
  logic [7:0]        red1_k_reg    [0:RED1_COUNT-1];
  logic [63:0]       red2_bits_reg [0:RED2_COUNT-1];
  logic [7:0]        red2_k_reg    [0:RED2_COUNT-1];
  logic [63:0]       best_bits_pipe_reg;
  logic [7:0]        best_k_pipe_reg;
  logic [7:0]        selected_k_reg;
  logic [31:0]       prefix_bits_reg;
  logic              unsupported_codec_reg;

  logic signed [15:0] curr_i_s16;
  logic signed [15:0] curr_q_s16;
  logic signed [17:0] residual_i_s18;
  logic signed [17:0] residual_q_s18;
  logic [31:0]        mapped_i_u32;
  logic [31:0]        mapped_q_u32;
  logic [31:0]        bits_i_u32 [0:K_COUNT-1];
  logic [31:0]        bits_q_u32 [0:K_COUNT-1];
  logic [63:0]        sample_bits_u64 [0:K_COUNT-1];
  logic [63:0]        cand_bits_next_u64 [0:K_COUNT-1];

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    if (residual >= 0) begin
      residual_to_mapped = $unsigned(residual <<< 1);
    end else begin
      residual_to_mapped = $unsigned((-residual <<< 1) - 1);
    end
  endfunction

  function automatic logic [31:0] rice_bits_for_mapped(
    input logic [31:0] mapped,
    input logic [3:0]  k_u
  );
    logic [31:0] quotient_u32;
    begin
      quotient_u32 = mapped >> k_u;
      rice_bits_for_mapped = quotient_u32 + 32'd1 + {28'd0, k_u};
    end
  endfunction

  function automatic logic choose_right(
    input logic [63:0] left_bits,
    input logic [7:0]  left_k,
    input logic [63:0] right_bits,
    input logic [7:0]  right_k
  );
    begin
      choose_right =
        (right_bits < left_bits) ||
        ((right_bits == left_bits) && (right_k < left_k));
    end
  endfunction

  assign curr_i_s16 = $signed(rd_data_reg[15:0]);
  assign curr_q_s16 = $signed(rd_data_reg[31:16]);

  assign residual_i_s18 =
    ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (rd_sample_idx_reg != ADDR_W'(0))) ?
      (curr_i_s16 - rd_prev_i_reg) : curr_i_s16;
  assign residual_q_s18 =
    ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (rd_sample_idx_reg != ADDR_W'(0))) ?
      (curr_q_s16 - rd_prev_q_reg) : curr_q_s16;

  assign mapped_i_u32 = residual_to_mapped(residual_i_s18);
  assign mapped_q_u32 = residual_to_mapped(residual_q_s18);

  genvar k_idx;
  generate
    for (k_idx = 0; k_idx < K_COUNT; k_idx = k_idx + 1) begin : g_k_bits
      assign bits_i_u32[k_idx] = rice_bits_for_mapped(mapped_i_u32, k_idx[3:0]);
      assign bits_q_u32[k_idx] = rice_bits_for_mapped(mapped_q_u32, k_idx[3:0]);
      assign sample_bits_u64[k_idx] = {32'd0, bits_i_u32[k_idx]} + {32'd0, bits_q_u32[k_idx]};
      assign cand_bits_next_u64[k_idx] = cand_bits_reg[k_idx] + sample_bits_u64[k_idx];
    end
  endgenerate

  assign o_rd_req            =
    (state_reg == ST_REQ) ||
    ((state_reg == ST_ACCUM_REQ) && !rd_last_sample_reg);
  assign o_rd_addr           = sample_idx_reg;
  assign o_busy              = (state_reg != ST_IDLE);
  assign o_done              = (state_reg == ST_DONE);
  assign o_selected_k        = selected_k_reg;
  assign o_prefix_bits       = prefix_bits_reg;
  assign o_unsupported_codec = unsupported_codec_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    integer idx;
    if (!rst_n) begin
      state_reg             <= ST_IDLE;
      codec_mode_reg        <= MRTC_CODEC_ZERO_RICE;
      sample_idx_reg        <= '0;
      prev_i_reg            <= '0;
      prev_q_reg            <= '0;
      rd_data_reg           <= '0;
      rd_sample_idx_reg     <= '0;
      rd_prev_i_reg         <= '0;
      rd_prev_q_reg         <= '0;
      rd_last_sample_reg    <= 1'b0;
      best_bits_pipe_reg    <= '0;
      best_k_pipe_reg       <= '0;
      selected_k_reg        <= 8'd0;
      prefix_bits_reg       <= 32'd0;
      unsupported_codec_reg <= 1'b0;
      for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
        cand_bits_reg[idx] <= '0;
      end
      for (idx = 0; idx < RED0_COUNT; idx = idx + 1) begin
        red0_bits_reg[idx] <= '0;
        red0_k_reg[idx]    <= '0;
      end
      for (idx = 0; idx < RED1_COUNT; idx = idx + 1) begin
        red1_bits_reg[idx] <= '0;
        red1_k_reg[idx]    <= '0;
      end
      for (idx = 0; idx < RED2_COUNT; idx = idx + 1) begin
        red2_bits_reg[idx] <= '0;
        red2_k_reg[idx]    <= '0;
      end
    end else begin
      case (state_reg)
        ST_IDLE: begin
          if (i_start) begin
            codec_mode_reg        <= i_codec_mode;
            sample_idx_reg        <= '0;
            prev_i_reg            <= '0;
            prev_q_reg            <= '0;
            rd_data_reg           <= '0;
            rd_sample_idx_reg     <= '0;
            rd_prev_i_reg         <= '0;
            rd_prev_q_reg         <= '0;
            rd_last_sample_reg    <= 1'b0;
            best_bits_pipe_reg    <= '0;
            best_k_pipe_reg       <= '0;
            selected_k_reg        <= 8'd0;
            prefix_bits_reg       <= 32'd0;
            unsupported_codec_reg <= 1'b0;
            for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
              cand_bits_reg[idx] <= 64'd0;
            end
            for (idx = 0; idx < RED0_COUNT; idx = idx + 1) begin
              red0_bits_reg[idx] <= '0;
              red0_k_reg[idx]    <= '0;
            end
            for (idx = 0; idx < RED1_COUNT; idx = idx + 1) begin
              red1_bits_reg[idx] <= '0;
              red1_k_reg[idx]    <= '0;
            end
            for (idx = 0; idx < RED2_COUNT; idx = idx + 1) begin
              red2_bits_reg[idx] <= '0;
              red2_k_reg[idx]    <= '0;
            end
            state_reg <= ST_REQ;
          end
        end

        ST_REQ: begin
          state_reg <= ST_WAIT;
        end

        ST_WAIT: begin
          if (i_rd_valid) begin
            rd_data_reg       <= i_rd_data;
            rd_sample_idx_reg <= sample_idx_reg;
            rd_prev_i_reg     <= prev_i_reg;
            rd_prev_q_reg     <= prev_q_reg;
            if (sample_idx_reg == ADDR_W'(PREFIX_SAMPLES - 1)) begin
              rd_last_sample_reg <= 1'b1;
            end else begin
              rd_last_sample_reg <= 1'b0;
              sample_idx_reg     <= sample_idx_reg + ADDR_W'(1);
            end
            state_reg <= ST_ACCUM_REQ;
          end
        end

        ST_ACCUM_REQ: begin
          for (idx = 0; idx < K_COUNT; idx = idx + 1) begin
            cand_bits_reg[idx] <= cand_bits_next_u64[idx];
          end
          prev_i_reg <= curr_i_s16;
          prev_q_reg <= curr_q_s16;

          if (rd_last_sample_reg) begin
            state_reg <= ST_REDUCE_L0;
          end else begin
            state_reg <= ST_WAIT;
          end
        end

        ST_REDUCE_L0: begin
          for (idx = 0; idx < RED0_COUNT; idx = idx + 1) begin
            if (choose_right(
                  cand_bits_reg[idx * 2],
                  idx * 2,
                  cand_bits_reg[(idx * 2) + 1],
                  (idx * 2) + 1)) begin
              red0_bits_reg[idx] <= cand_bits_reg[(idx * 2) + 1];
              red0_k_reg[idx]    <= (idx * 2) + 1;
            end else begin
              red0_bits_reg[idx] <= cand_bits_reg[idx * 2];
              red0_k_reg[idx]    <= idx * 2;
            end
          end
          state_reg <= ST_REDUCE_L1;
        end

        ST_REDUCE_L1: begin
          for (idx = 0; idx < RED1_COUNT; idx = idx + 1) begin
            if (choose_right(
                  red0_bits_reg[idx * 2],
                  red0_k_reg[idx * 2],
                  red0_bits_reg[(idx * 2) + 1],
                  red0_k_reg[(idx * 2) + 1])) begin
              red1_bits_reg[idx] <= red0_bits_reg[(idx * 2) + 1];
              red1_k_reg[idx]    <= red0_k_reg[(idx * 2) + 1];
            end else begin
              red1_bits_reg[idx] <= red0_bits_reg[idx * 2];
              red1_k_reg[idx]    <= red0_k_reg[idx * 2];
            end
          end
          state_reg <= ST_REDUCE_L2;
        end

        ST_REDUCE_L2: begin
          for (idx = 0; idx < RED2_COUNT; idx = idx + 1) begin
            if (choose_right(
                  red1_bits_reg[idx * 2],
                  red1_k_reg[idx * 2],
                  red1_bits_reg[(idx * 2) + 1],
                  red1_k_reg[(idx * 2) + 1])) begin
              red2_bits_reg[idx] <= red1_bits_reg[(idx * 2) + 1];
              red2_k_reg[idx]    <= red1_k_reg[(idx * 2) + 1];
            end else begin
              red2_bits_reg[idx] <= red1_bits_reg[idx * 2];
              red2_k_reg[idx]    <= red1_k_reg[idx * 2];
            end
          end
          state_reg <= ST_REDUCE_L3;
        end

        ST_REDUCE_L3: begin
          if (choose_right(
                red2_bits_reg[0],
                red2_k_reg[0],
                red2_bits_reg[1],
                red2_k_reg[1])) begin
            best_bits_pipe_reg <= red2_bits_reg[1];
            best_k_pipe_reg    <= red2_k_reg[1];
          end else begin
            best_bits_pipe_reg <= red2_bits_reg[0];
            best_k_pipe_reg    <= red2_k_reg[0];
          end
          state_reg <= ST_FINAL_WRITE;
        end

        ST_FINAL_WRITE: begin
          if ((codec_mode_reg != MRTC_CODEC_ZERO_RICE) &&
              (codec_mode_reg != MRTC_CODEC_DELTA_RICE)) begin
            selected_k_reg        <= 8'd0;
            prefix_bits_reg       <= 32'd0;
            unsupported_codec_reg <= 1'b1;
          end else begin
            selected_k_reg        <= best_k_pipe_reg;
            prefix_bits_reg       <= best_bits_pipe_reg[31:0];
            unsupported_codec_reg <= 1'b0;
          end
          state_reg <= ST_DONE;
        end

        ST_DONE: begin
          state_reg <= ST_IDLE;
        end

        default: begin
          state_reg <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
