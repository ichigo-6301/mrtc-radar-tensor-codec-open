module mrtc_rice_k_select_seq #(
  parameter int BLOCK_SAMPLES = 1024,
  parameter int RAW_BYTES     = 4096,
  parameter int HEADER_BYTES  = 64,
  parameter int ADDR_W        = 10
) (
  input  logic              clk,
  input  logic              rst_n,
  // Pulse-style start input. Sampled only while idle (o_busy == 0) and
  // ignored once a scan is already in flight.
  input  logic              i_start,
  input  logic [7:0]        i_codec_mode,
  input  logic [7:0]        i_rice_mode,
  input  logic [3:0]        i_fixed_k,
  // Read-side protocol for future block-memory providers:
  // - o_rd_req is a 1-cycle request pulse.
  // - o_rd_addr is valid alongside o_rd_req.
  // - the provider returns exactly one i_rd_valid pulse with matching data.
  // - same-cycle valid is allowed today; delayed valid is allowed in future.
  // - samples are consumed only when i_rd_valid is asserted.
  output logic              o_rd_req,
  output logic [ADDR_W-1:0] o_rd_addr,
  input  logic              i_rd_valid,
  input  logic [31:0]       i_rd_data,
  // Busy is high from accepted start through the full scan/finalize sequence.
  // Done is a 1-cycle pulse; future encoder integration must latch all result
  // outputs on o_done because there is no external ready/backpressure input.
  output logic              o_busy,
  output logic              o_done,
  output logic [7:0]        o_selected_k,
  output logic [31:0]       o_payload_bits,
  output logic [31:0]       o_payload_bytes,
  output logic              o_use_raw,
  output logic              o_unsupported_rice
);
  import mrtc_pkg::*;

  typedef enum logic [3:0] {
    ST_IDLE      = 4'd0,
    ST_SETUP     = 4'd1,
    ST_FIXED_REQ = 4'd2,
    ST_FIXED_WAIT = 4'd3,
    ST_ADAPT_REQ = 4'd4,
    ST_ADAPT_WAIT = 4'd5,
    ST_DONE      = 4'd6
  } state_t;

  localparam logic [31:0] RAW_BITS_U32     = 32'(RAW_BYTES * 8);
  localparam logic [63:0] RAW_BYTES_U64    = 64'(RAW_BYTES);
  localparam logic [63:0] HEADER_BYTES_U64 = 64'(HEADER_BYTES);
  localparam logic [63:0] MAX_BITS_U64     = 64'hFFFF_FFFF_FFFF_FFFF;

  state_t             state_reg;
  logic [7:0]         codec_mode_reg;
  logic [7:0]         rice_mode_reg;
  logic [3:0]         fixed_k_reg;
  logic [3:0]         k_reg;
  logic [ADDR_W-1:0]  sample_idx_reg;
  logic signed [15:0] prev_i_reg;
  logic signed [15:0] prev_q_reg;
  logic [63:0]        cand_bits_reg;
  logic [63:0]        best_bits_reg;
  logic [7:0]         best_k_reg;
  logic               seq_unsupported_rice_reg;
  logic [7:0]         selected_k_reg;
  logic [31:0]        payload_bits_reg;
  logic [31:0]        payload_bytes_reg;
  logic               use_raw_reg;

  logic signed [15:0] curr_i_s16;
  logic signed [15:0] curr_q_s16;
  logic signed [17:0] residual_i_s18;
  logic signed [17:0] residual_q_s18;
  logic [31:0]        mapped_i_u32;
  logic [31:0]        mapped_q_u32;
  logic [31:0]        bits_i_u32;
  logic [31:0]        bits_q_u32;
  logic [63:0]        sample_bits_u64;
  logic [63:0]        cand_bits_next_u64;
  logic [63:0]        best_bits_next_u64;
  logic [7:0]         best_k_next_u8;
  logic [31:0]        payload_bits_next_u32;
  logic [31:0]        payload_bytes_next_u32;
  logic [63:0]        final_bytes_next_u64;

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
    logic [31:0] k_ext_u32;
    begin
      quotient_u32 = mapped >> k_u;
      k_ext_u32 = {28'd0, k_u};
      rice_bits_for_mapped = quotient_u32 + 32'd1 + k_ext_u32;
    end
  endfunction

  assign curr_i_s16 = $signed(i_rd_data[15:0]);
  assign curr_q_s16 = $signed(i_rd_data[31:16]);

  assign residual_i_s18 =
    ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (sample_idx_reg != ADDR_W'(0))) ?
      (curr_i_s16 - prev_i_reg) : curr_i_s16;
  assign residual_q_s18 =
    ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (sample_idx_reg != ADDR_W'(0))) ?
      (curr_q_s16 - prev_q_reg) : curr_q_s16;

  assign mapped_i_u32 = residual_to_mapped(residual_i_s18);
  assign mapped_q_u32 = residual_to_mapped(residual_q_s18);
  assign bits_i_u32   = rice_bits_for_mapped(mapped_i_u32, k_reg);
  assign bits_q_u32   = rice_bits_for_mapped(mapped_q_u32, k_reg);
  assign sample_bits_u64 = {32'd0, bits_i_u32} + {32'd0, bits_q_u32};
  assign cand_bits_next_u64 = cand_bits_reg + sample_bits_u64;

  assign best_bits_next_u64 = (cand_bits_next_u64 < best_bits_reg) ? cand_bits_next_u64 : best_bits_reg;
  assign best_k_next_u8     = (cand_bits_next_u64 < best_bits_reg) ? {4'd0, k_reg} : best_k_reg;
  assign payload_bits_next_u32  = best_bits_next_u64[31:0];
  assign payload_bytes_next_u32 = (payload_bits_next_u32 + 32'd7) >> 3;
  assign final_bytes_next_u64   = HEADER_BYTES_U64 + {32'd0, payload_bytes_next_u32};

  assign o_rd_req  = (state_reg == ST_FIXED_REQ) || (state_reg == ST_ADAPT_REQ);
  assign o_rd_addr = sample_idx_reg;
  assign o_busy    = (state_reg != ST_IDLE);
  assign o_done    = (state_reg == ST_DONE);

  assign o_selected_k       = selected_k_reg;
  assign o_payload_bits     = payload_bits_reg;
  assign o_payload_bytes    = payload_bytes_reg;
  assign o_use_raw          = use_raw_reg;
  assign o_unsupported_rice = seq_unsupported_rice_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_reg                 <= ST_IDLE;
      codec_mode_reg            <= MRTC_CODEC_ZERO_RICE;
      rice_mode_reg             <= MRTC_RICE_FIXED_K;
      fixed_k_reg               <= 4'd0;
      k_reg                     <= 4'd0;
      sample_idx_reg            <= '0;
      prev_i_reg                <= '0;
      prev_q_reg                <= '0;
      cand_bits_reg             <= '0;
      best_bits_reg             <= MAX_BITS_U64;
      best_k_reg                <= 8'd0;
      seq_unsupported_rice_reg  <= 1'b0;
      selected_k_reg            <= 8'd0;
      payload_bits_reg          <= 32'd0;
      payload_bytes_reg         <= 32'd0;
      use_raw_reg               <= 1'b0;
    end else begin
      case (state_reg)
        ST_IDLE: begin
          if (i_start) begin
            codec_mode_reg           <= i_codec_mode;
            rice_mode_reg            <= i_rice_mode;
            fixed_k_reg              <= i_fixed_k;
            k_reg                    <= i_fixed_k;
            sample_idx_reg           <= '0;
            prev_i_reg               <= '0;
            prev_q_reg               <= '0;
            cand_bits_reg            <= '0;
            best_bits_reg            <= MAX_BITS_U64;
            best_k_reg               <= {4'd0, i_fixed_k};
            seq_unsupported_rice_reg <= 1'b0;
            selected_k_reg           <= {4'd0, i_fixed_k};
            payload_bits_reg         <= 32'd0;
            payload_bytes_reg        <= 32'd0;
            use_raw_reg              <= 1'b0;
            state_reg                <= ST_SETUP;
          end
        end

        ST_SETUP: begin
          if (codec_mode_reg == MRTC_CODEC_RAW) begin
            seq_unsupported_rice_reg <= 1'b0;
            selected_k_reg           <= {4'd0, fixed_k_reg};
            payload_bits_reg         <= RAW_BITS_U32;
            payload_bytes_reg        <= 32'(RAW_BYTES);
            use_raw_reg              <= 1'b1;
            state_reg                <= ST_DONE;
          end else if ((codec_mode_reg != MRTC_CODEC_ZERO_RICE) &&
                       (codec_mode_reg != MRTC_CODEC_DELTA_RICE)) begin
            seq_unsupported_rice_reg <= 1'b1;
            selected_k_reg           <= {4'd0, fixed_k_reg};
            payload_bits_reg         <= RAW_BITS_U32;
            payload_bytes_reg        <= 32'(RAW_BYTES);
            use_raw_reg              <= 1'b1;
            state_reg                <= ST_DONE;
          end else if (rice_mode_reg == MRTC_RICE_FIXED_K) begin
            k_reg          <= fixed_k_reg;
            sample_idx_reg <= '0;
            prev_i_reg     <= '0;
            prev_q_reg     <= '0;
            cand_bits_reg  <= 64'd0;
            state_reg      <= ST_FIXED_REQ;
          end else if (rice_mode_reg == MRTC_RICE_BLOCK_ADAPTIVE_K) begin
            k_reg          <= 4'd0;
            sample_idx_reg <= '0;
            prev_i_reg     <= '0;
            prev_q_reg     <= '0;
            cand_bits_reg  <= 64'd0;
            best_bits_reg  <= MAX_BITS_U64;
            best_k_reg     <= {4'd0, fixed_k_reg};
            state_reg      <= ST_ADAPT_REQ;
          end else begin
            seq_unsupported_rice_reg <= 1'b1;
            selected_k_reg           <= {4'd0, fixed_k_reg};
            payload_bits_reg         <= RAW_BITS_U32;
            payload_bytes_reg        <= 32'(RAW_BYTES);
            use_raw_reg              <= 1'b1;
            state_reg                <= ST_DONE;
          end
        end

        ST_FIXED_REQ,
        ST_FIXED_WAIT: begin
          if (i_rd_valid) begin
            if (sample_idx_reg == ADDR_W'(BLOCK_SAMPLES-1)) begin
              selected_k_reg    <= {4'd0, k_reg};
              payload_bits_reg  <= cand_bits_next_u64[31:0];
              payload_bytes_reg <= (cand_bits_next_u64[31:0] + 32'd7) >> 3;
              use_raw_reg       <= (HEADER_BYTES_U64 + {32'd0, ((cand_bits_next_u64[31:0] + 32'd7) >> 3)}) >= RAW_BYTES_U64;
              state_reg         <= ST_DONE;
            end else begin
              sample_idx_reg <= sample_idx_reg + ADDR_W'(1);
              prev_i_reg     <= curr_i_s16;
              prev_q_reg     <= curr_q_s16;
              cand_bits_reg  <= cand_bits_next_u64;
              state_reg      <= ST_FIXED_REQ;
            end
          end else if (state_reg == ST_FIXED_REQ) begin
            state_reg <= ST_FIXED_WAIT;
          end
        end

        ST_ADAPT_REQ,
        ST_ADAPT_WAIT: begin
          if (i_rd_valid) begin
            if (sample_idx_reg == ADDR_W'(BLOCK_SAMPLES-1)) begin
              if (k_reg == 4'd15) begin
                selected_k_reg    <= best_k_next_u8;
                payload_bits_reg  <= payload_bits_next_u32;
                payload_bytes_reg <= payload_bytes_next_u32;
                use_raw_reg       <= (final_bytes_next_u64 >= RAW_BYTES_U64);
                best_bits_reg     <= best_bits_next_u64;
                best_k_reg        <= best_k_next_u8;
                state_reg         <= ST_DONE;
              end else begin
                best_bits_reg  <= best_bits_next_u64;
                best_k_reg     <= best_k_next_u8;
                k_reg          <= k_reg + 4'd1;
                sample_idx_reg <= '0;
                prev_i_reg     <= '0;
                prev_q_reg     <= '0;
                cand_bits_reg  <= 64'd0;
                state_reg      <= ST_ADAPT_REQ;
              end
            end else begin
              sample_idx_reg <= sample_idx_reg + ADDR_W'(1);
              prev_i_reg     <= curr_i_s16;
              prev_q_reg     <= curr_q_s16;
              cand_bits_reg  <= cand_bits_next_u64;
              state_reg      <= ST_ADAPT_REQ;
            end
          end else if (state_reg == ST_ADAPT_REQ) begin
            state_reg <= ST_ADAPT_WAIT;
          end
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
