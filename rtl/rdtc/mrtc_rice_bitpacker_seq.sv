module mrtc_rice_bitpacker_seq #(
  parameter int BLOCK_SAMPLES     = 1024,
  parameter int MAX_PAYLOAD_BYTES = 4096,
  parameter int ADDR_W            = 10
) (
  input  logic                             clk,
  input  logic                             rst_n,
  // Pulse-style start input. Sampled only while idle and ignored while busy.
  input  logic                             i_start,
  input  logic [7:0]                       i_codec_mode,
  input  logic [7:0]                       i_selected_k,
  // Read-side contract:
  // - o_rd_req is a 1-cycle request pulse.
  // - o_rd_addr is valid with o_rd_req.
  // - the provider returns exactly one i_rd_valid pulse for each request.
  // - the current adapter may return same-cycle valid; future providers may delay.
  // - the candidate consumes sample data only when i_rd_valid is asserted.
  output logic                             o_rd_req,
  output logic [ADDR_W-1:0]                o_rd_addr,
  input  logic                             i_rd_valid,
  input  logic [31:0]                      i_rd_data,
  // Busy stays high from accepted start through the full request/pack/finalize
  // sequence. Done is a 1-cycle pulse; payload outputs are valid on o_done.
  output logic                             o_busy,
  output logic                             o_done,
  output logic [(MAX_PAYLOAD_BYTES*8)-1:0] o_payload_flat,
  output logic [31:0]                      o_payload_bits,
  output logic [31:0]                      o_payload_bytes,
  output logic                             o_overflow
);
  import mrtc_pkg::*;

  typedef enum logic [3:0] {
    ST_IDLE          = 4'd0,
    ST_SETUP         = 4'd1,
    ST_SAMPLE_REQ    = 4'd2,
    ST_SAMPLE_WAIT   = 4'd3,
    ST_PACK_I_SETUP  = 4'd4,
    ST_PACK_I_UNARY  = 4'd5,
    ST_PACK_I_ZERO   = 4'd6,
    ST_PACK_I_REM    = 4'd7,
    ST_PACK_Q_SETUP  = 4'd8,
    ST_PACK_Q_UNARY  = 4'd9,
    ST_PACK_Q_ZERO   = 4'd10,
    ST_PACK_Q_REM    = 4'd11,
    ST_NEXT_SAMPLE   = 4'd12,
    ST_FINALIZE      = 4'd13,
    ST_DONE          = 4'd14
  } state_t;

  state_t state_reg;

  logic [7:0]                         codec_mode_reg;
  logic [3:0]                         selected_k_reg;
  logic [ADDR_W-1:0]                  sample_idx_reg;
  logic signed [15:0]                 curr_i_reg;
  logic signed [15:0]                 curr_q_reg;
  logic signed [15:0]                 prev_i_reg;
  logic signed [15:0]                 prev_q_reg;
  logic [7:0]                         payload_byte_mem [0:MAX_PAYLOAD_BYTES-1];
  logic [31:0]                        payload_bits_reg;
  logic [31:0]                        payload_bytes_reg;
  logic [31:0]                        bit_pos_reg;
  logic                               overflow_reg;
  logic [31:0]                        mapped_reg;
  logic [31:0]                        unary_remaining_reg;
  logic [31:0]                        remainder_reg;
  logic [4:0]                         remainder_bits_left_reg;

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    if (residual >= 0) begin
      residual_to_mapped = $unsigned(residual <<< 1);
    end else begin
      residual_to_mapped = $unsigned((-residual <<< 1) - 1);
    end
  endfunction

  assign o_rd_req        = (state_reg == ST_SAMPLE_REQ);
  assign o_rd_addr       = sample_idx_reg;
  assign o_busy          = (state_reg != ST_IDLE);
  assign o_done          = (state_reg == ST_DONE);
  assign o_payload_bits  = payload_bits_reg;
  assign o_payload_bytes = payload_bytes_reg;
  assign o_overflow      = overflow_reg;

  generate
    genvar payload_flat_idx;
    for (payload_flat_idx = 0; payload_flat_idx < MAX_PAYLOAD_BYTES; payload_flat_idx = payload_flat_idx + 1) begin : g_payload_flat
      assign o_payload_flat[(payload_flat_idx*8) +: 8] = payload_byte_mem[payload_flat_idx];
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    logic signed [17:0] residual_s18;
    logic [31:0]        mapped_u32;
    logic [31:0]        quotient_u32;
    logic [31:0]        remainder_u32;
    int unsigned        clear_idx;
    int unsigned        byte_idx_tmp;
    int unsigned        bit_in_byte_tmp;
    if (!rst_n) begin
      state_reg         <= ST_IDLE;
      codec_mode_reg    <= 8'd0;
      selected_k_reg    <= 4'd0;
      sample_idx_reg    <= '0;
      curr_i_reg        <= '0;
      curr_q_reg        <= '0;
      prev_i_reg        <= '0;
      prev_q_reg        <= '0;
      payload_bits_reg  <= 32'd0;
      payload_bytes_reg <= 32'd0;
      bit_pos_reg       <= 32'd0;
      overflow_reg      <= 1'b0;
      mapped_reg        <= 32'd0;
      unary_remaining_reg <= 32'd0;
      remainder_reg       <= 32'd0;
      remainder_bits_left_reg <= 5'd0;
      for (clear_idx = 0; clear_idx < MAX_PAYLOAD_BYTES; clear_idx = clear_idx + 1) begin
        payload_byte_mem[clear_idx] <= 8'd0;
      end
    end else begin
      case (state_reg)
        ST_IDLE: begin
          if (i_start) begin
            codec_mode_reg    <= i_codec_mode;
            selected_k_reg    <= i_selected_k[3:0];
            sample_idx_reg    <= '0;
            curr_i_reg        <= '0;
            curr_q_reg        <= '0;
            prev_i_reg        <= '0;
            prev_q_reg        <= '0;
            payload_bits_reg  <= 32'd0;
            payload_bytes_reg <= 32'd0;
            bit_pos_reg       <= 32'd0;
            overflow_reg      <= 1'b0;
            mapped_reg        <= 32'd0;
            unary_remaining_reg <= 32'd0;
            remainder_reg       <= 32'd0;
            remainder_bits_left_reg <= 5'd0;
            for (clear_idx = 0; clear_idx < MAX_PAYLOAD_BYTES; clear_idx = clear_idx + 1) begin
              payload_byte_mem[clear_idx] <= 8'd0;
            end
            state_reg         <= ST_SETUP;
          end
        end

        ST_SETUP: begin
          if ((codec_mode_reg == MRTC_CODEC_ZERO_RICE) ||
              (codec_mode_reg == MRTC_CODEC_DELTA_RICE)) begin
            state_reg <= ST_SAMPLE_REQ;
          end else begin
            state_reg <= ST_DONE;
          end
        end

        ST_SAMPLE_REQ,
        ST_SAMPLE_WAIT: begin
          if (i_rd_valid) begin
            curr_i_reg <= $signed(i_rd_data[15:0]);
            curr_q_reg <= $signed(i_rd_data[31:16]);
            state_reg  <= ST_PACK_I_SETUP;
          end else if (state_reg == ST_SAMPLE_REQ) begin
            state_reg <= ST_SAMPLE_WAIT;
          end
        end

        ST_PACK_I_SETUP: begin
          residual_s18 =
            ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (sample_idx_reg != ADDR_W'(0))) ?
              (curr_i_reg - prev_i_reg) : curr_i_reg;
          mapped_u32 = residual_to_mapped(residual_s18);
          quotient_u32 = mapped_u32 >> selected_k_reg;
          if (selected_k_reg == 4'd0) begin
            remainder_u32 = 32'd0;
          end else begin
            remainder_u32 = mapped_u32 & ((32'd1 << selected_k_reg) - 32'd1);
          end
          mapped_reg              <= mapped_u32;
          unary_remaining_reg     <= quotient_u32;
          remainder_reg           <= remainder_u32;
          remainder_bits_left_reg <= {1'b0, selected_k_reg};
          if (quotient_u32 != 32'd0) begin
            state_reg <= ST_PACK_I_UNARY;
          end else begin
            state_reg <= ST_PACK_I_ZERO;
          end
        end

        ST_PACK_I_UNARY: begin
          byte_idx_tmp    = bit_pos_reg >> 3;
          bit_in_byte_tmp = 7 - (bit_pos_reg & 32'd7);
          if (byte_idx_tmp < MAX_PAYLOAD_BYTES) begin
            payload_byte_mem[byte_idx_tmp][bit_in_byte_tmp] <= 1'b1;
          end else begin
            overflow_reg <= 1'b1;
          end
          bit_pos_reg <= bit_pos_reg + 32'd1;
          if (unary_remaining_reg == 32'd1) begin
            unary_remaining_reg <= 32'd0;
            state_reg           <= ST_PACK_I_ZERO;
          end else begin
            unary_remaining_reg <= unary_remaining_reg - 32'd1;
          end
        end

        ST_PACK_I_ZERO: begin
          byte_idx_tmp = bit_pos_reg >> 3;
          if (byte_idx_tmp >= MAX_PAYLOAD_BYTES) begin
            overflow_reg <= 1'b1;
          end
          bit_pos_reg <= bit_pos_reg + 32'd1;
          if (remainder_bits_left_reg != 5'd0) begin
            state_reg <= ST_PACK_I_REM;
          end else begin
            state_reg <= ST_PACK_Q_SETUP;
          end
        end

        ST_PACK_I_REM: begin
          byte_idx_tmp    = bit_pos_reg >> 3;
          bit_in_byte_tmp = 7 - (bit_pos_reg & 32'd7);
          if (remainder_reg[remainder_bits_left_reg - 5'd1]) begin
            if (byte_idx_tmp < MAX_PAYLOAD_BYTES) begin
              payload_byte_mem[byte_idx_tmp][bit_in_byte_tmp] <= 1'b1;
            end else begin
              overflow_reg <= 1'b1;
            end
          end else if (byte_idx_tmp >= MAX_PAYLOAD_BYTES) begin
            overflow_reg <= 1'b1;
          end
          bit_pos_reg <= bit_pos_reg + 32'd1;
          if (remainder_bits_left_reg == 5'd1) begin
            remainder_bits_left_reg <= 5'd0;
            state_reg               <= ST_PACK_Q_SETUP;
          end else begin
            remainder_bits_left_reg <= remainder_bits_left_reg - 5'd1;
          end
        end

        ST_PACK_Q_SETUP: begin
          residual_s18 =
            ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (sample_idx_reg != ADDR_W'(0))) ?
              (curr_q_reg - prev_q_reg) : curr_q_reg;
          mapped_u32 = residual_to_mapped(residual_s18);
          quotient_u32 = mapped_u32 >> selected_k_reg;
          if (selected_k_reg == 4'd0) begin
            remainder_u32 = 32'd0;
          end else begin
            remainder_u32 = mapped_u32 & ((32'd1 << selected_k_reg) - 32'd1);
          end
          mapped_reg              <= mapped_u32;
          unary_remaining_reg     <= quotient_u32;
          remainder_reg           <= remainder_u32;
          remainder_bits_left_reg <= {1'b0, selected_k_reg};
          if (quotient_u32 != 32'd0) begin
            state_reg <= ST_PACK_Q_UNARY;
          end else begin
            state_reg <= ST_PACK_Q_ZERO;
          end
        end

        ST_PACK_Q_UNARY: begin
          byte_idx_tmp    = bit_pos_reg >> 3;
          bit_in_byte_tmp = 7 - (bit_pos_reg & 32'd7);
          if (byte_idx_tmp < MAX_PAYLOAD_BYTES) begin
            payload_byte_mem[byte_idx_tmp][bit_in_byte_tmp] <= 1'b1;
          end else begin
            overflow_reg <= 1'b1;
          end
          bit_pos_reg <= bit_pos_reg + 32'd1;
          if (unary_remaining_reg == 32'd1) begin
            unary_remaining_reg <= 32'd0;
            state_reg           <= ST_PACK_Q_ZERO;
          end else begin
            unary_remaining_reg <= unary_remaining_reg - 32'd1;
          end
        end

        ST_PACK_Q_ZERO: begin
          byte_idx_tmp = bit_pos_reg >> 3;
          if (byte_idx_tmp >= MAX_PAYLOAD_BYTES) begin
            overflow_reg <= 1'b1;
          end
          bit_pos_reg <= bit_pos_reg + 32'd1;
          if (remainder_bits_left_reg != 5'd0) begin
            state_reg <= ST_PACK_Q_REM;
          end else begin
            prev_i_reg <= curr_i_reg;
            prev_q_reg <= curr_q_reg;
            state_reg  <= ST_NEXT_SAMPLE;
          end
        end

        ST_PACK_Q_REM: begin
          byte_idx_tmp    = bit_pos_reg >> 3;
          bit_in_byte_tmp = 7 - (bit_pos_reg & 32'd7);
          if (remainder_reg[remainder_bits_left_reg - 5'd1]) begin
            if (byte_idx_tmp < MAX_PAYLOAD_BYTES) begin
              payload_byte_mem[byte_idx_tmp][bit_in_byte_tmp] <= 1'b1;
            end else begin
              overflow_reg <= 1'b1;
            end
          end else if (byte_idx_tmp >= MAX_PAYLOAD_BYTES) begin
            overflow_reg <= 1'b1;
          end
          bit_pos_reg <= bit_pos_reg + 32'd1;
          if (remainder_bits_left_reg == 5'd1) begin
            remainder_bits_left_reg <= 5'd0;
            prev_i_reg              <= curr_i_reg;
            prev_q_reg              <= curr_q_reg;
            state_reg               <= ST_NEXT_SAMPLE;
          end else begin
            remainder_bits_left_reg <= remainder_bits_left_reg - 5'd1;
          end
        end

        ST_NEXT_SAMPLE: begin
          if (sample_idx_reg == ADDR_W'(BLOCK_SAMPLES-1)) begin
            state_reg <= ST_FINALIZE;
          end else begin
            sample_idx_reg <= sample_idx_reg + ADDR_W'(1);
            state_reg      <= ST_SAMPLE_REQ;
          end
        end

        ST_FINALIZE: begin
          payload_bits_reg  <= bit_pos_reg;
          payload_bytes_reg <= (bit_pos_reg + 32'd7) >> 3;
          state_reg         <= ST_DONE;
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
