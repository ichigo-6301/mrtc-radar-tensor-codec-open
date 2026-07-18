module mrtc_k_policy_engine #(
  parameter int MRTC_K_POLICY_ARCH = mrtc_pkg::MRTC_K_POLICY_FULL_ADAPTIVE,
  parameter bit PREFIX_DURING_CAPTURE = 1'b0,
  parameter bit PREFIX_STREAM_LENGTH_BY_TLAST = 1'b1,
  parameter int PREFIX_SAMPLES     = 256,
  parameter int BLOCK_SAMPLES      = 1024,
  parameter int RAW_BYTES          = 4096,
  parameter int HEADER_BYTES       = 64,
  parameter int ADDR_W             = 10
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              i_start,
  input  logic [7:0]        i_codec_mode,
  input  logic [7:0]        i_rice_mode,
  input  logic [3:0]        i_fixed_k,
  input  logic              i_prefix_precomputed_valid,
  input  logic [7:0]        i_prefix_precomputed_k,
  input  logic [31:0]       i_prefix_precomputed_bits,
  input  logic [31:0]       i_prefix_precomputed_cycles,
  input  logic              i_prefix_precomputed_unsupported,
  output logic              o_rd_req,
  output logic [ADDR_W-1:0] o_rd_addr,
  input  logic              i_rd_valid,
  input  logic [31:0]       i_rd_data,
  output logic              o_busy,
  output logic              o_done,
  output logic [7:0]        o_selected_k,
  output logic [31:0]       o_payload_bits,
  output logic [31:0]       o_payload_bytes,
  output logic              o_use_raw,
  output logic              o_unsupported_rice,
  output logic              o_prefix_fast_active,
  output logic [31:0]       o_prefix_bits,
  output logic [31:0]       o_prefix_cycles,
  output logic [31:0]       o_size_count_cycles,
  output logic [31:0]       o_total_policy_cycles
);
  import mrtc_pkg::*;
  localparam int PREFIX_SCALE = BLOCK_SAMPLES / PREFIX_SAMPLES;

  typedef enum logic [2:0] {
    ST_IDLE         = 3'd0,
    ST_PREFIX_START = 3'd1,
    ST_PREFIX_WAIT  = 3'd2,
    ST_SIZE_START   = 3'd3,
    ST_SIZE_WAIT    = 3'd4,
    ST_DONE         = 3'd5
  } prefix_fast_state_t;

  generate
    if (MRTC_K_POLICY_ARCH == MRTC_K_POLICY_FULL_ADAPTIVE) begin : g_full_adaptive
      logic        full_busy;
      logic        full_done;
      logic        full_rd_req;
      logic [ADDR_W-1:0] full_rd_addr;
      logic [7:0]  full_selected_k;
      logic [31:0] full_payload_bits;
      logic [31:0] full_payload_bytes;
      logic        full_use_raw;
      logic        full_unsupported_rice;
      logic [31:0] cycle_count_reg;

      assign o_rd_req             = full_rd_req;
      assign o_rd_addr            = full_rd_addr;
      assign o_busy               = full_busy;
      assign o_done               = full_done;
      assign o_selected_k         = full_selected_k;
      assign o_payload_bits       = full_payload_bits;
      assign o_payload_bytes      = full_payload_bytes;
      assign o_use_raw            = full_use_raw;
      assign o_unsupported_rice   = full_unsupported_rice;
      assign o_prefix_fast_active = 1'b0;
      assign o_prefix_bits        = 32'd0;
      assign o_prefix_cycles      = 32'd0;
      assign o_size_count_cycles  = cycle_count_reg;
      assign o_total_policy_cycles = cycle_count_reg;

      mrtc_rice_k_select_seq #(
        .BLOCK_SAMPLES(BLOCK_SAMPLES),
        .RAW_BYTES    (RAW_BYTES),
        .HEADER_BYTES (HEADER_BYTES),
        .ADDR_W       (ADDR_W)
      ) u_full_adaptive (
        .clk               (clk),
        .rst_n             (rst_n),
        .i_start           (i_start),
        .i_codec_mode      (i_codec_mode),
        .i_rice_mode       (i_rice_mode),
        .i_fixed_k         (i_fixed_k),
        .o_rd_req          (full_rd_req),
        .o_rd_addr         (full_rd_addr),
        .i_rd_valid        (i_rd_valid),
        .i_rd_data         (i_rd_data),
        .o_busy            (full_busy),
        .o_done            (full_done),
        .o_selected_k      (full_selected_k),
        .o_payload_bits    (full_payload_bits),
        .o_payload_bytes   (full_payload_bytes),
        .o_use_raw         (full_use_raw),
        .o_unsupported_rice(full_unsupported_rice)
      );

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          cycle_count_reg <= 32'd0;
        end else if (i_start) begin
          cycle_count_reg <= 32'd0;
        end else if (full_busy) begin
          cycle_count_reg <= cycle_count_reg + 32'd1;
        end
      end
    end else begin : g_prefix_fast
      prefix_fast_state_t state_reg;
      logic [7:0] codec_mode_reg;
      logic [7:0] rice_mode_reg;
      logic [3:0] fixed_k_reg;
      logic [7:0] prefix_selected_k_reg;
      logic [31:0] prefix_bits_reg;
      logic        prefix_unsupported_reg;
      logic [31:0] prefix_cycles_reg;
      logic [31:0] size_cycles_reg;

      logic        prefix_start;
      logic        prefix_busy;
      logic        prefix_done;
      logic        prefix_rd_req;
      logic [ADDR_W-1:0] prefix_rd_addr;
      logic [7:0]  prefix_selected_k;
      logic [31:0] prefix_bits;
      logic        prefix_unsupported_codec;

      logic        size_start;
      logic        size_busy;
      logic        size_done;
      logic        size_rd_req;
      logic [ADDR_W-1:0] size_rd_addr;
      logic [31:0] size_payload_bits;
      logic [31:0] size_payload_bytes;
      logic        size_use_raw;
      logic        size_unsupported_rice;
      logic        prefix_skip_size_count;
      logic        use_precomputed_prefix;
      logic [7:0]  prefix_codec_mode_eval;
      logic [63:0] prefix_est_payload_bits_u64;
      logic [63:0] prefix_est_payload_bytes_u64;
      logic        prefix_est_use_raw;
      logic [31:0] prefix_bits_for_estimate;

      logic [7:0]  selected_k_reg;
      logic [31:0] payload_bits_reg;
      logic [31:0] payload_bytes_reg;
      logic        use_raw_reg;
      logic        unsupported_rice_reg;

      assign prefix_start = (state_reg == ST_PREFIX_START);
      assign size_start   = (state_reg == ST_SIZE_START);
      assign prefix_codec_mode_eval =
        (state_reg == ST_IDLE) ? i_codec_mode : codec_mode_reg;
      assign use_precomputed_prefix =
        PREFIX_DURING_CAPTURE &&
        i_prefix_precomputed_valid &&
        ((prefix_codec_mode_eval == MRTC_CODEC_ZERO_RICE) || (prefix_codec_mode_eval == MRTC_CODEC_DELTA_RICE));
      assign prefix_skip_size_count =
        PREFIX_STREAM_LENGTH_BY_TLAST &&
        ((prefix_codec_mode_eval == MRTC_CODEC_ZERO_RICE) || (prefix_codec_mode_eval == MRTC_CODEC_DELTA_RICE));
      assign prefix_bits_for_estimate =
        use_precomputed_prefix ? i_prefix_precomputed_bits : prefix_bits;
      assign prefix_est_payload_bits_u64  = {32'd0, prefix_bits_for_estimate} * PREFIX_SCALE;
      assign prefix_est_payload_bytes_u64 = (prefix_est_payload_bits_u64 + 64'd7) >> 3;
      assign prefix_est_use_raw =
        ((HEADER_BYTES + prefix_est_payload_bytes_u64) >= RAW_BYTES);

      assign o_rd_req =
        (state_reg == ST_PREFIX_START) || (state_reg == ST_PREFIX_WAIT) ? prefix_rd_req :
        ((state_reg == ST_SIZE_START) || (state_reg == ST_SIZE_WAIT) ? size_rd_req : 1'b0);
      assign o_rd_addr =
        (state_reg == ST_PREFIX_START) || (state_reg == ST_PREFIX_WAIT) ? prefix_rd_addr : size_rd_addr;
      assign o_busy               = (state_reg != ST_IDLE);
      assign o_done               = (state_reg == ST_DONE);
      assign o_selected_k         = selected_k_reg;
      assign o_payload_bits       = payload_bits_reg;
      assign o_payload_bytes      = payload_bytes_reg;
      assign o_use_raw            = use_raw_reg;
      assign o_unsupported_rice   = unsupported_rice_reg;
      assign o_prefix_fast_active = 1'b1;
      assign o_prefix_bits        = prefix_bits_reg;
      assign o_prefix_cycles      = prefix_cycles_reg;
      assign o_size_count_cycles  = size_cycles_reg;
      assign o_total_policy_cycles = prefix_cycles_reg + size_cycles_reg;

      mrtc_prefix_k_select_seq #(
        .PREFIX_SAMPLES(PREFIX_SAMPLES),
        .BLOCK_SAMPLES (BLOCK_SAMPLES),
        .ADDR_W        (ADDR_W)
      ) u_prefix_select (
        .clk                (clk),
        .rst_n              (rst_n),
        .i_start            (prefix_start),
        .i_codec_mode       (codec_mode_reg),
        .o_rd_req           (prefix_rd_req),
        .o_rd_addr          (prefix_rd_addr),
        .i_rd_valid         (i_rd_valid),
        .i_rd_data          (i_rd_data),
        .o_busy             (prefix_busy),
        .o_done             (prefix_done),
        .o_selected_k       (prefix_selected_k),
        .o_prefix_bits      (prefix_bits),
        .o_unsupported_codec(prefix_unsupported_codec)
      );

      mrtc_rice_k_select_seq #(
        .BLOCK_SAMPLES(BLOCK_SAMPLES),
        .RAW_BYTES    (RAW_BYTES),
        .HEADER_BYTES (HEADER_BYTES),
        .ADDR_W       (ADDR_W)
      ) u_fixed_size_count (
        .clk               (clk),
        .rst_n             (rst_n),
        .i_start           (size_start),
        .i_codec_mode      (codec_mode_reg),
        .i_rice_mode       (MRTC_RICE_FIXED_K),
        .i_fixed_k         (prefix_selected_k_reg[3:0]),
        .o_rd_req          (size_rd_req),
        .o_rd_addr         (size_rd_addr),
        .i_rd_valid        (i_rd_valid),
        .i_rd_data         (i_rd_data),
        .o_busy            (size_busy),
        .o_done            (size_done),
        .o_selected_k      (),
        .o_payload_bits    (size_payload_bits),
        .o_payload_bytes   (size_payload_bytes),
        .o_use_raw         (size_use_raw),
        .o_unsupported_rice(size_unsupported_rice)
      );

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          state_reg             <= ST_IDLE;
          codec_mode_reg        <= MRTC_CODEC_ZERO_RICE;
          rice_mode_reg         <= MRTC_RICE_BLOCK_ADAPTIVE_K;
          fixed_k_reg           <= 4'd0;
          prefix_selected_k_reg <= 8'd0;
          prefix_bits_reg       <= 32'd0;
          prefix_unsupported_reg <= 1'b0;
          prefix_cycles_reg     <= 32'd0;
          size_cycles_reg       <= 32'd0;
          selected_k_reg        <= 8'd0;
          payload_bits_reg      <= 32'd0;
          payload_bytes_reg     <= 32'd0;
          use_raw_reg           <= 1'b0;
          unsupported_rice_reg  <= 1'b0;
        end else begin
          if (state_reg == ST_PREFIX_WAIT && prefix_busy) begin
            prefix_cycles_reg <= prefix_cycles_reg + 32'd1;
          end
          if (state_reg == ST_SIZE_WAIT && size_busy) begin
            size_cycles_reg <= size_cycles_reg + 32'd1;
          end

          case (state_reg)
            ST_IDLE: begin
              if (i_start) begin
                codec_mode_reg         <= i_codec_mode;
                rice_mode_reg          <= i_rice_mode;
                fixed_k_reg            <= i_fixed_k;
                prefix_selected_k_reg  <= 8'd0;
                prefix_bits_reg        <= 32'd0;
                prefix_unsupported_reg <= 1'b0;
                prefix_cycles_reg      <= 32'd0;
                size_cycles_reg        <= 32'd0;
                selected_k_reg         <= 8'd0;
                payload_bits_reg       <= 32'd0;
                payload_bytes_reg      <= 32'd0;
                use_raw_reg            <= 1'b0;
                unsupported_rice_reg   <= 1'b0;
                if ((i_codec_mode == MRTC_CODEC_ZERO_RICE) ||
                    (i_codec_mode == MRTC_CODEC_DELTA_RICE)) begin
                  if (PREFIX_DURING_CAPTURE && i_prefix_precomputed_valid) begin
                    prefix_selected_k_reg  <= i_prefix_precomputed_k;
                    prefix_bits_reg        <= i_prefix_precomputed_bits;
                    prefix_unsupported_reg <= i_prefix_precomputed_unsupported;
                    prefix_cycles_reg      <= i_prefix_precomputed_cycles;
                    if (i_prefix_precomputed_unsupported) begin
                      selected_k_reg       <= 8'd0;
                      payload_bits_reg     <= 32'(RAW_BYTES * 8);
                      payload_bytes_reg    <= 32'(RAW_BYTES);
                      use_raw_reg          <= 1'b1;
                      unsupported_rice_reg <= 1'b1;
                      state_reg            <= ST_DONE;
                    end else if (PREFIX_STREAM_LENGTH_BY_TLAST) begin
                      selected_k_reg       <= i_prefix_precomputed_k;
                      payload_bits_reg     <= prefix_est_use_raw ? 32'(RAW_BYTES * 8) : 32'd0;
                      payload_bytes_reg    <= prefix_est_use_raw ? 32'(RAW_BYTES) : 32'd0;
                      use_raw_reg          <= prefix_est_use_raw;
                      unsupported_rice_reg <= 1'b0;
                      state_reg            <= ST_DONE;
                    end else begin
                      state_reg <= ST_SIZE_START;
                    end
                  end else begin
                    state_reg <= ST_PREFIX_START;
                  end
                end else begin
                  prefix_selected_k_reg <= {4'd0, i_fixed_k};
                  state_reg             <= ST_SIZE_START;
                end
              end
            end

            ST_PREFIX_START: begin
              state_reg <= ST_PREFIX_WAIT;
            end

            ST_PREFIX_WAIT: begin
              if (prefix_done) begin
                prefix_selected_k_reg  <= prefix_selected_k;
                prefix_bits_reg        <= prefix_bits;
                prefix_unsupported_reg <= prefix_unsupported_codec;
                if (prefix_unsupported_codec) begin
                  selected_k_reg       <= 8'd0;
                  payload_bits_reg     <= 32'(RAW_BYTES * 8);
                  payload_bytes_reg    <= 32'(RAW_BYTES);
                  use_raw_reg          <= 1'b1;
                  unsupported_rice_reg <= 1'b1;
                  state_reg            <= ST_DONE;
                end else if (prefix_skip_size_count) begin
                  selected_k_reg       <= prefix_selected_k;
                  payload_bits_reg     <= prefix_est_use_raw ? 32'(RAW_BYTES * 8) : 32'd0;
                  payload_bytes_reg    <= prefix_est_use_raw ? 32'(RAW_BYTES) : 32'd0;
                  use_raw_reg          <= prefix_est_use_raw;
                  unsupported_rice_reg <= 1'b0;
                  state_reg            <= ST_DONE;
                end else begin
                  state_reg <= ST_SIZE_START;
                end
              end
            end

            ST_SIZE_START: begin
              state_reg <= ST_SIZE_WAIT;
            end

            ST_SIZE_WAIT: begin
              if (size_done) begin
                if ((codec_mode_reg == MRTC_CODEC_ZERO_RICE) ||
                    (codec_mode_reg == MRTC_CODEC_DELTA_RICE)) begin
                  selected_k_reg <= prefix_selected_k_reg;
                end else begin
                  selected_k_reg <= {4'd0, fixed_k_reg};
                end
                payload_bits_reg     <= size_payload_bits;
                payload_bytes_reg    <= size_payload_bytes;
                use_raw_reg          <= size_use_raw;
                unsupported_rice_reg <= size_unsupported_rice;
                state_reg            <= ST_DONE;
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
    end
  endgenerate
endmodule
