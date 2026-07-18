module mrtc_rice_bitpacker_axis #(
  parameter int AXIS_DATA_W   = 128,
  parameter int BLOCK_SAMPLES = 1024,
  parameter int ADDR_W        = 10,
  parameter int FRAG_W        = 32
) (
  input  logic                                  clk,
  input  logic                                  rst_n,
  input  logic                                  i_start,
  input  logic [7:0]                            i_codec_mode,
  input  logic [7:0]                            i_selected_k,
  input  logic                                  i_expected_length_valid,
  input  logic [31:0]                           i_expected_payload_bits,
  input  logic [31:0]                           i_expected_payload_bytes,
  output logic                                  o_rd_req,
  output logic [ADDR_W-1:0]                     o_rd_addr,
  input  logic                                  i_rd_valid,
  input  logic [31:0]                           i_rd_data,
  output logic [AXIS_DATA_W-1:0]                m_axis_tdata,
  output logic                                  m_axis_tvalid,
  input  logic                                  m_axis_tready,
  output logic                                  m_axis_tlast,
  output logic [$clog2((AXIS_DATA_W/8)+1)-1:0]  m_axis_tvalid_bytes_minus1,
  output logic                                  o_busy,
  output logic                                  o_done,
  output logic [31:0]                           o_payload_bits_counted,
  output logic [31:0]                           o_payload_bytes_counted,
  output logic                                  o_count_mismatch,
  output logic                                  o_overflow
);
  import mrtc_pkg::*;

  typedef enum logic [3:0] {
    ST_IDLE          = 4'd0,
    ST_SETUP         = 4'd1,
    ST_SAMPLE_REQ    = 4'd2,
    ST_SAMPLE_WAIT   = 4'd3,
    ST_SYMBOL_SETUP  = 4'd4,
    ST_EMIT_UNARY    = 4'd5,
    ST_EMIT_ZERO_REM = 4'd6,
    ST_WAIT_AXIS_DONE= 4'd7,
    ST_DONE          = 4'd8
  } state_t;

  state_t state_reg;

  logic [7:0]            codec_mode_reg;
  logic [3:0]            selected_k_reg;
  logic [ADDR_W-1:0]     sample_idx_reg;
  logic                  component_is_q_reg;
  logic signed [15:0]    curr_i_reg;
  logic signed [15:0]    curr_q_reg;
  logic signed [15:0]    prev_i_reg;
  logic signed [15:0]    prev_q_reg;
  logic [31:0]           payload_bits_counted_reg;
  logic [31:0]           payload_bytes_counted_reg;
  logic                  count_mismatch_reg;
  logic                  overflow_reg;
  logic [31:0]           unary_remaining_reg;
  logic [31:0]           remainder_reg;
  logic [4:0]            remainder_bits_left_reg;

  logic                  frag_valid_reg;
  logic [FRAG_W-1:0]     frag_data_reg;
  logic [$clog2(FRAG_W+1)-1:0] frag_bits_reg;
  logic                  frag_last_reg;
  logic                  frag_ready;
  logic                  packer_done;
  logic                  packer_overflow;

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    if (residual >= 0) begin
      residual_to_mapped = $unsigned(residual <<< 1);
    end else begin
      residual_to_mapped = $unsigned((-residual <<< 1) - 1);
    end
  endfunction

  assign o_rd_req                  = (state_reg == ST_SAMPLE_REQ);
  assign o_rd_addr                 = sample_idx_reg;
  assign o_busy                    = (state_reg != ST_IDLE);
  assign o_done                    = (state_reg == ST_DONE);
  assign o_payload_bits_counted    = payload_bits_counted_reg;
  assign o_payload_bytes_counted   = payload_bytes_counted_reg;
  assign o_count_mismatch          = count_mismatch_reg;
  assign o_overflow                = overflow_reg | packer_overflow;

  mrtc_axis_width_packer #(
    .AXIS_DATA_W(AXIS_DATA_W),
    .FRAG_W     (FRAG_W)
  ) u_axis_width_packer (
    .clk                     (clk),
    .rst_n                   (rst_n),
    .s_frag_valid            (frag_valid_reg),
    .s_frag_ready            (frag_ready),
    .s_frag_data             (frag_data_reg),
    .s_frag_bits             (frag_bits_reg),
    .s_frag_last             (frag_last_reg),
    .m_axis_tdata            (m_axis_tdata),
    .m_axis_tvalid           (m_axis_tvalid),
    .m_axis_tready           (m_axis_tready),
    .m_axis_tlast            (m_axis_tlast),
    .m_axis_tvalid_bytes_minus1(m_axis_tvalid_bytes_minus1),
    .o_busy                  (),
    .o_done                  (packer_done),
    .o_overflow              (packer_overflow)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    logic                  frag_accepted;
    logic                  final_symbol;
    logic signed [17:0]    residual_s18;
    logic [31:0]           mapped_u32;
    logic [31:0]           quotient_u32;
    logic [31:0]           remainder_u32;
    logic [31:0]           next_payload_bits_u32;
    logic [31:0]           next_payload_bytes_u32;
    logic [FRAG_W-1:0]     next_frag_data;
    int                    emit_bits_int;
    int                    frag_idx;
    if (!rst_n) begin
      state_reg                 <= ST_IDLE;
      codec_mode_reg            <= 8'd0;
      selected_k_reg            <= 4'd0;
      sample_idx_reg            <= '0;
      component_is_q_reg        <= 1'b0;
      curr_i_reg                <= '0;
      curr_q_reg                <= '0;
      prev_i_reg                <= '0;
      prev_q_reg                <= '0;
      payload_bits_counted_reg  <= 32'd0;
      payload_bytes_counted_reg <= 32'd0;
      count_mismatch_reg        <= 1'b0;
      overflow_reg              <= 1'b0;
      unary_remaining_reg       <= 32'd0;
      remainder_reg             <= 32'd0;
      remainder_bits_left_reg   <= 5'd0;
      frag_valid_reg            <= 1'b0;
      frag_data_reg             <= '0;
      frag_bits_reg             <= '0;
      frag_last_reg             <= 1'b0;
    end else begin
      frag_accepted = frag_valid_reg && frag_ready;

      if (packer_overflow) begin
        overflow_reg <= 1'b1;
      end

      if (frag_accepted) begin
        frag_valid_reg <= 1'b0;
        frag_data_reg  <= '0;
        frag_bits_reg  <= '0;
        frag_last_reg  <= 1'b0;
        next_payload_bits_u32 = payload_bits_counted_reg + 32'(frag_bits_reg);
        payload_bits_counted_reg  <= next_payload_bits_u32;
        payload_bytes_counted_reg <= (next_payload_bits_u32 + 32'd7) >> 3;
      end

      case (state_reg)
        ST_IDLE: begin
          if (i_start) begin
            codec_mode_reg            <= i_codec_mode;
            selected_k_reg            <= i_selected_k[3:0];
            sample_idx_reg            <= '0;
            component_is_q_reg        <= 1'b0;
            curr_i_reg                <= '0;
            curr_q_reg                <= '0;
            prev_i_reg                <= '0;
            prev_q_reg                <= '0;
            payload_bits_counted_reg  <= 32'd0;
            payload_bytes_counted_reg <= 32'd0;
            count_mismatch_reg        <= 1'b0;
            overflow_reg              <= 1'b0;
            unary_remaining_reg       <= 32'd0;
            remainder_reg             <= 32'd0;
            remainder_bits_left_reg   <= 5'd0;
            frag_valid_reg            <= 1'b0;
            frag_data_reg             <= '0;
            frag_bits_reg             <= '0;
            frag_last_reg             <= 1'b0;
            state_reg                 <= ST_SETUP;
          end
        end

        ST_SETUP: begin
          if ((codec_mode_reg == MRTC_CODEC_ZERO_RICE) ||
              (codec_mode_reg == MRTC_CODEC_DELTA_RICE)) begin
            state_reg <= ST_SAMPLE_REQ;
          end else begin
            count_mismatch_reg <= i_expected_length_valid &&
                                  ((i_expected_payload_bits != 32'd0) ||
                                   (i_expected_payload_bytes != 32'd0));
            state_reg <= ST_DONE;
          end
        end

        ST_SAMPLE_REQ,
        ST_SAMPLE_WAIT: begin
          if (i_rd_valid) begin
            curr_i_reg <= $signed(i_rd_data[15:0]);
            curr_q_reg <= $signed(i_rd_data[31:16]);
            state_reg  <= ST_SYMBOL_SETUP;
          end else if (state_reg == ST_SAMPLE_REQ) begin
            state_reg <= ST_SAMPLE_WAIT;
          end
        end

        ST_SYMBOL_SETUP: begin
          if (component_is_q_reg) begin
            residual_s18 =
              ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (sample_idx_reg != ADDR_W'(0))) ?
                (curr_q_reg - prev_q_reg) : curr_q_reg;
          end else begin
            residual_s18 =
              ((codec_mode_reg == MRTC_CODEC_DELTA_RICE) && (sample_idx_reg != ADDR_W'(0))) ?
                (curr_i_reg - prev_i_reg) : curr_i_reg;
          end
          mapped_u32   = residual_to_mapped(residual_s18);
          quotient_u32 = mapped_u32 >> selected_k_reg;
          if (selected_k_reg == 4'd0) begin
            remainder_u32 = 32'd0;
          end else begin
            remainder_u32 = mapped_u32 & ((32'd1 << selected_k_reg) - 32'd1);
          end
          unary_remaining_reg     <= quotient_u32;
          remainder_reg           <= remainder_u32;
          remainder_bits_left_reg <= {1'b0, selected_k_reg};
          if (quotient_u32 != 32'd0) begin
            state_reg <= ST_EMIT_UNARY;
          end else begin
            state_reg <= ST_EMIT_ZERO_REM;
          end
        end

        ST_EMIT_UNARY: begin
          if (!frag_valid_reg) begin
            emit_bits_int = (unary_remaining_reg > FRAG_W) ? FRAG_W : unary_remaining_reg;
            next_frag_data = '0;
            for (frag_idx = 0; frag_idx < emit_bits_int; frag_idx = frag_idx + 1) begin
              next_frag_data[frag_idx] = 1'b1;
            end
            frag_data_reg  <= next_frag_data;
            frag_bits_reg  <= $clog2(FRAG_W+1)'(emit_bits_int);
            frag_last_reg  <= 1'b0;
            frag_valid_reg <= 1'b1;
          end else if (frag_accepted) begin
            if (unary_remaining_reg > FRAG_W) begin
              unary_remaining_reg <= unary_remaining_reg - FRAG_W;
            end else begin
              unary_remaining_reg <= 32'd0;
              state_reg           <= ST_EMIT_ZERO_REM;
            end
          end
        end

        ST_EMIT_ZERO_REM: begin
          if (!frag_valid_reg) begin
            emit_bits_int = 1 + remainder_bits_left_reg;
            next_frag_data = '0;
            for (frag_idx = 0; frag_idx < remainder_bits_left_reg; frag_idx = frag_idx + 1) begin
              next_frag_data[(emit_bits_int - 2) - frag_idx] =
                remainder_reg[remainder_bits_left_reg - 1 - frag_idx];
            end
            final_symbol = component_is_q_reg && (sample_idx_reg == ADDR_W'(BLOCK_SAMPLES-1));
            frag_data_reg  <= next_frag_data;
            frag_bits_reg  <= $clog2(FRAG_W+1)'(emit_bits_int);
            frag_last_reg  <= final_symbol;
            frag_valid_reg <= 1'b1;
          end else if (frag_accepted) begin
            if (component_is_q_reg) begin
              prev_i_reg <= curr_i_reg;
              prev_q_reg <= curr_q_reg;
              if (sample_idx_reg == ADDR_W'(BLOCK_SAMPLES-1)) begin
                next_payload_bits_u32  = payload_bits_counted_reg + 32'(frag_bits_reg);
                next_payload_bytes_u32 = (next_payload_bits_u32 + 32'd7) >> 3;
                count_mismatch_reg <= i_expected_length_valid &&
                                      ((next_payload_bits_u32 != i_expected_payload_bits) ||
                                       (next_payload_bytes_u32 != i_expected_payload_bytes));
                state_reg <= ST_WAIT_AXIS_DONE;
              end else begin
                sample_idx_reg     <= sample_idx_reg + ADDR_W'(1);
                component_is_q_reg <= 1'b0;
                state_reg          <= ST_SAMPLE_REQ;
              end
            end else begin
              component_is_q_reg <= 1'b1;
              state_reg          <= ST_SYMBOL_SETUP;
            end
          end
        end

        ST_WAIT_AXIS_DONE: begin
          if (packer_done) begin
            state_reg <= ST_DONE;
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
