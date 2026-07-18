module mrtc_prefix_precompute_engine #(
  parameter int PREFIX_SAMPLES = 256,
  parameter int BLOCK_SAMPLES = 1024,
  parameter int ADDR_W = 10
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              i_bank0_ready,
  input  logic              i_bank1_ready,
  input  logic              i_bank0_result_valid,
  input  logic              i_bank1_result_valid,
  input  logic [7:0]        i_bank0_codec_mode,
  input  logic [7:0]        i_bank1_codec_mode,
  output logic              o_rd_req,
  output logic [ADDR_W-1:0] o_rd_addr,
  input  logic              i_rd_valid,
  input  logic [31:0]       i_rd_data,
  output logic              o_busy,
  output logic              o_result_done,
  output logic              o_result_bank_sel,
  output logic [7:0]        o_selected_k,
  output logic [31:0]       o_prefix_bits,
  output logic [31:0]       o_prefix_cycles,
  output logic              o_unsupported_codec
);
  import mrtc_pkg::*;

  typedef enum logic [1:0] {
    PRE_IDLE = 2'd0,
    PRE_RUN  = 2'd1,
    PRE_DONE = 2'd2
  } pre_state_t;

  pre_state_t state_reg;
  logic       bank_sel_reg;
  logic [7:0] codec_mode_reg;
  logic       start_pulse_reg;
  logic [31:0] cycle_count_reg;

  logic       prefix_busy;
  logic       prefix_done;
  logic       prefix_rd_req;
  logic [ADDR_W-1:0] prefix_rd_addr;
  logic [7:0] prefix_selected_k;
  logic [31:0] prefix_bits;
  logic       prefix_unsupported_codec;

  assign o_rd_req            = prefix_rd_req;
  assign o_rd_addr           = prefix_rd_addr;
  assign o_busy              = (state_reg != PRE_IDLE);
  assign o_result_done       = (state_reg == PRE_DONE);
  assign o_result_bank_sel   = bank_sel_reg;
  assign o_selected_k        = prefix_selected_k;
  assign o_prefix_bits       = prefix_bits;
  assign o_prefix_cycles     = cycle_count_reg;
  assign o_unsupported_codec = prefix_unsupported_codec;

  mrtc_prefix_k_select_seq #(
    .PREFIX_SAMPLES(PREFIX_SAMPLES),
    .BLOCK_SAMPLES (BLOCK_SAMPLES),
    .ADDR_W        (ADDR_W)
  ) u_prefix_select (
    .clk                (clk),
    .rst_n              (rst_n),
    .i_start            (start_pulse_reg),
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_reg       <= PRE_IDLE;
      bank_sel_reg    <= 1'b0;
      codec_mode_reg  <= MRTC_CODEC_ZERO_RICE;
      start_pulse_reg <= 1'b0;
      cycle_count_reg <= 32'd0;
    end else begin
      start_pulse_reg <= 1'b0;

      if ((state_reg == PRE_RUN) && prefix_busy) begin
        cycle_count_reg <= cycle_count_reg + 32'd1;
      end

      case (state_reg)
        PRE_IDLE: begin
          cycle_count_reg <= 32'd0;
          if (i_bank0_ready && !i_bank0_result_valid) begin
            bank_sel_reg    <= 1'b0;
            codec_mode_reg  <= i_bank0_codec_mode;
            start_pulse_reg <= 1'b1;
            state_reg       <= PRE_RUN;
          end else if (i_bank1_ready && !i_bank1_result_valid) begin
            bank_sel_reg    <= 1'b1;
            codec_mode_reg  <= i_bank1_codec_mode;
            start_pulse_reg <= 1'b1;
            state_reg       <= PRE_RUN;
          end
        end

        PRE_RUN: begin
          if (prefix_done) begin
            state_reg <= PRE_DONE;
          end
        end

        PRE_DONE: begin
          state_reg <= PRE_IDLE;
        end

        default: begin
          state_reg <= PRE_IDLE;
        end
      endcase
    end
  end
endmodule
