module mrtc_axi_lite_reg_block #(
  parameter int ADDR_W = 12,
  parameter int DATA_W = 32
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic [ADDR_W-1:0]     s_axil_awaddr,
  input  logic                  s_axil_awvalid,
  output logic                  s_axil_awready,
  input  logic [DATA_W-1:0]     s_axil_wdata,
  input  logic [(DATA_W/8)-1:0] s_axil_wstrb,
  input  logic                  s_axil_wvalid,
  output logic                  s_axil_wready,
  output logic [1:0]            s_axil_bresp,
  output logic                  s_axil_bvalid,
  input  logic                  s_axil_bready,
  input  logic [ADDR_W-1:0]     s_axil_araddr,
  input  logic                  s_axil_arvalid,
  output logic                  s_axil_arready,
  output logic [DATA_W-1:0]     s_axil_rdata,
  output logic [1:0]            s_axil_rresp,
  output logic                  s_axil_rvalid,
  input  logic                  s_axil_rready,

  input  logic                  i_stat_enc_busy,
  input  logic                  i_stat_enc_done,
  input  logic [31:0]           i_stat_enc_raw_bytes,
  input  logic [31:0]           i_stat_enc_comp_bytes,
  input  logic [31:0]           i_stat_enc_num_blocks,
  input  logic [31:0]           i_stat_enc_error,
  input  logic [31:0]           i_stat_enc_raw_bypass_blocks,
  input  logic [31:0]           i_stat_enc_stall_input_cycles,
  input  logic [31:0]           i_stat_enc_stall_output_cycles,
  input  logic                  i_stat_dec_busy,
  input  logic                  i_stat_dec_done,
  input  logic [31:0]           i_stat_dec_raw_bytes,
  input  logic [31:0]           i_stat_dec_comp_bytes,
  input  logic [31:0]           i_stat_dec_num_blocks,
  input  logic [31:0]           i_stat_dec_error,
  input  logic [31:0]           i_stat_dec_error_blocks,
  input  logic [31:0]           i_stat_dec_stall_input_cycles,
  input  logic [31:0]           i_stat_dec_stall_output_cycles,

  output logic                  o_enable,
  output logic                  o_encoder_enable,
  output logic                  o_decoder_enable,
  output logic                  o_soft_reset_pulse,
  output logic                  o_clear_status_pulse,
  output logic [7:0]            o_cfg_codec_mode,
  output logic [7:0]            o_cfg_rice_mode,
  output logic [3:0]            o_cfg_fixed_k,
  output logic [15:0]           o_cfg_frame_id,
  output logic [15:0]           o_cfg_tensor_spatial_size,
  output logic [15:0]           o_cfg_tensor_doppler_size,
  output logic [15:0]           o_cfg_tensor_range_size,
  output logic                  o_irq_done,
  output logic                  o_irq_error,
  output logic                  o_irq
);
  import mrtc_pkg::*;

  localparam logic [11:0] REG_CTRL           = 12'h000;
  localparam logic [11:0] REG_STATUS         = 12'h004;
  localparam logic [11:0] REG_CFG_CODEC      = 12'h008;
  localparam logic [11:0] REG_FRAME_ID       = 12'h00C;
  localparam logic [11:0] REG_TENSOR_SPATIAL = 12'h010;
  localparam logic [11:0] REG_TENSOR_DOPPLER = 12'h014;
  localparam logic [11:0] REG_TENSOR_RANGE   = 12'h018;
  localparam logic [11:0] REG_ENC_RAW_BYTES  = 12'h020;
  localparam logic [11:0] REG_ENC_COMP_BYTES = 12'h024;
  localparam logic [11:0] REG_ENC_NUM_BLOCKS = 12'h028;
  localparam logic [11:0] REG_ENC_ERROR      = 12'h02C;
  localparam logic [11:0] REG_DEC_RAW_BYTES  = 12'h030;
  localparam logic [11:0] REG_DEC_COMP_BYTES = 12'h034;
  localparam logic [11:0] REG_DEC_NUM_BLOCKS = 12'h038;
  localparam logic [11:0] REG_DEC_ERROR      = 12'h03C;
  localparam logic [11:0] REG_VERSION        = 12'h040;
  localparam logic [11:0] REG_CAPABILITY     = 12'h044;
  localparam logic [11:0] REG_IRQ_STATUS     = 12'h048;
  localparam logic [11:0] REG_IRQ_MASK       = 12'h04C;
  localparam logic [11:0] REG_IRQ_CLEAR      = 12'h050;
  localparam logic [11:0] REG_ENC_RAW_BYPASS = 12'h054;
  localparam logic [11:0] REG_ENC_STALL_IN   = 12'h058;
  localparam logic [11:0] REG_ENC_STALL_OUT  = 12'h05C;
  localparam logic [11:0] REG_DEC_ERR_BLOCKS = 12'h060;
  localparam logic [11:0] REG_DEC_STALL_IN   = 12'h064;
  localparam logic [11:0] REG_DEC_STALL_OUT  = 12'h068;

  logic enc_done_pending;
  logic dec_done_pending;
  logic enc_error_pending;
  logic dec_error_pending;
  logic [3:0] irq_mask_reg;
  logic [DATA_W-1:0] rdata_next;
  logic [31:0] merged;

  assign o_irq_done = (enc_done_pending && irq_mask_reg[0]) ||
                      (dec_done_pending && irq_mask_reg[1]);
  assign o_irq_error = (enc_error_pending && irq_mask_reg[2]) ||
                       (dec_error_pending && irq_mask_reg[3]);
  assign o_irq = o_irq_done | o_irq_error;

  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] prior,
    input logic [31:0] wdata,
    input logic [3:0]  wstrb
  );
    logic [31:0] result;
    begin
      result = prior;
      if (wstrb[0]) result[7:0]   = wdata[7:0];
      if (wstrb[1]) result[15:8]  = wdata[15:8];
      if (wstrb[2]) result[23:16] = wdata[23:16];
      if (wstrb[3]) result[31:24] = wdata[31:24];
      apply_wstrb = result;
    end
  endfunction

  always_comb begin
    rdata_next = 32'd0;
    case (s_axil_araddr[11:0])
      REG_CTRL: begin
        rdata_next[0] = o_enable;
        rdata_next[3] = o_encoder_enable;
        rdata_next[4] = o_decoder_enable;
      end
      REG_STATUS: begin
        rdata_next[0] = i_stat_enc_busy;
        rdata_next[1] = i_stat_dec_busy;
        rdata_next[2] = enc_done_pending;
        rdata_next[3] = dec_done_pending;
        rdata_next[4] = enc_error_pending | dec_error_pending;
      end
      REG_CFG_CODEC: begin
        rdata_next[7:0]   = o_cfg_codec_mode;
        rdata_next[15:8]  = o_cfg_rice_mode;
        rdata_next[19:16] = o_cfg_fixed_k;
      end
      REG_FRAME_ID:       rdata_next[15:0] = o_cfg_frame_id;
      REG_TENSOR_SPATIAL: rdata_next[15:0] = o_cfg_tensor_spatial_size;
      REG_TENSOR_DOPPLER: rdata_next[15:0] = o_cfg_tensor_doppler_size;
      REG_TENSOR_RANGE:   rdata_next[15:0] = o_cfg_tensor_range_size;
      REG_ENC_RAW_BYTES:  rdata_next       = i_stat_enc_raw_bytes;
      REG_ENC_COMP_BYTES: rdata_next       = i_stat_enc_comp_bytes;
      REG_ENC_NUM_BLOCKS: rdata_next       = i_stat_enc_num_blocks;
      REG_ENC_ERROR:      rdata_next       = i_stat_enc_error;
      REG_DEC_RAW_BYTES:  rdata_next       = i_stat_dec_raw_bytes;
      REG_DEC_COMP_BYTES: rdata_next       = i_stat_dec_comp_bytes;
      REG_DEC_NUM_BLOCKS: rdata_next       = i_stat_dec_num_blocks;
      REG_DEC_ERROR:      rdata_next       = i_stat_dec_error;
      REG_VERSION:        rdata_next       = 32'h0001_0000;
      REG_CAPABILITY: begin
        rdata_next[0] = 1'b1;
        rdata_next[1] = 1'b1;
        rdata_next[2] = 1'b1;
        rdata_next[3] = 1'b0;
        rdata_next[4] = 1'b0;
      end
      REG_IRQ_STATUS: begin
        rdata_next[0] = enc_done_pending;
        rdata_next[1] = dec_done_pending;
        rdata_next[2] = enc_error_pending;
        rdata_next[3] = dec_error_pending;
      end
      REG_IRQ_MASK: begin
        rdata_next[3:0] = irq_mask_reg;
      end
      REG_IRQ_CLEAR:      rdata_next       = 32'd0;
      REG_ENC_RAW_BYPASS: rdata_next       = i_stat_enc_raw_bypass_blocks;
      REG_ENC_STALL_IN:   rdata_next       = i_stat_enc_stall_input_cycles;
      REG_ENC_STALL_OUT:  rdata_next       = i_stat_enc_stall_output_cycles;
      REG_DEC_ERR_BLOCKS: rdata_next       = i_stat_dec_error_blocks;
      REG_DEC_STALL_IN:   rdata_next       = i_stat_dec_stall_input_cycles;
      REG_DEC_STALL_OUT:  rdata_next       = i_stat_dec_stall_output_cycles;
      default:           rdata_next       = 32'd0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axil_awready <= 1'b0;
      s_axil_wready <= 1'b0;
      s_axil_bresp <= 2'b00;
      s_axil_bvalid <= 1'b0;
      s_axil_arready <= 1'b0;
      s_axil_rdata <= '0;
      s_axil_rresp <= 2'b00;
      s_axil_rvalid <= 1'b0;

      o_enable <= 1'b0;
      o_encoder_enable <= 1'b0;
      o_decoder_enable <= 1'b0;
      o_soft_reset_pulse <= 1'b0;
      o_clear_status_pulse <= 1'b0;
      o_cfg_codec_mode <= MRTC_CODEC_ZERO_RICE;
      o_cfg_rice_mode <= MRTC_RICE_FIXED_K;
      o_cfg_fixed_k <= 4'd0;
      o_cfg_frame_id <= 16'd0;
      o_cfg_tensor_spatial_size <= MRTC_BLOCK_SPATIAL_LEN;
      o_cfg_tensor_doppler_size <= MRTC_BLOCK_DOPPLER_LEN;
      o_cfg_tensor_range_size <= MRTC_BLOCK_RANGE_LEN;
      irq_mask_reg <= 4'd0;

      enc_done_pending <= 1'b0;
      dec_done_pending <= 1'b0;
      enc_error_pending <= 1'b0;
      dec_error_pending <= 1'b0;
    end else begin
      s_axil_awready <= 1'b0;
      s_axil_wready <= 1'b0;
      s_axil_arready <= 1'b0;
      o_soft_reset_pulse <= 1'b0;
      o_clear_status_pulse <= 1'b0;

      if (i_stat_enc_done) begin
        enc_done_pending <= 1'b1;
      end
      if (i_stat_dec_done) begin
        dec_done_pending <= 1'b1;
      end
      if (i_stat_enc_error != 0) begin
        enc_error_pending <= 1'b1;
      end
      if (i_stat_dec_error != 0) begin
        dec_error_pending <= 1'b1;
      end

      if (s_axil_bvalid && s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
      if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end

      if (!s_axil_bvalid && s_axil_awvalid && s_axil_wvalid) begin
        s_axil_awready <= 1'b1;
        s_axil_wready <= 1'b1;
        s_axil_bvalid <= 1'b1;
        s_axil_bresp <= 2'b00;

        case (s_axil_awaddr[11:0])
          REG_CTRL: begin
            merged = apply_wstrb(32'd0, s_axil_wdata, s_axil_wstrb);
            if (merged[1]) begin
              o_enable <= 1'b0;
              o_encoder_enable <= 1'b0;
              o_decoder_enable <= 1'b0;
              enc_done_pending <= 1'b0;
              dec_done_pending <= 1'b0;
              enc_error_pending <= 1'b0;
              dec_error_pending <= 1'b0;
              o_soft_reset_pulse <= 1'b1;
            end else begin
              o_enable <= merged[0];
              o_encoder_enable <= merged[3];
              o_decoder_enable <= merged[4];
              if (merged[2]) begin
                enc_done_pending <= 1'b0;
                dec_done_pending <= 1'b0;
                enc_error_pending <= 1'b0;
                dec_error_pending <= 1'b0;
                o_clear_status_pulse <= 1'b1;
              end
            end
          end
          REG_CFG_CODEC: begin
            merged = apply_wstrb({12'd0, o_cfg_fixed_k, o_cfg_rice_mode, o_cfg_codec_mode}, s_axil_wdata, s_axil_wstrb);
            o_cfg_codec_mode <= merged[7:0];
            o_cfg_rice_mode <= merged[15:8];
            o_cfg_fixed_k <= merged[19:16];
          end
          REG_FRAME_ID: begin
            merged = apply_wstrb({16'd0, o_cfg_frame_id}, s_axil_wdata, s_axil_wstrb);
            o_cfg_frame_id <= merged[15:0];
          end
          REG_TENSOR_SPATIAL: begin
            merged = apply_wstrb({16'd0, o_cfg_tensor_spatial_size}, s_axil_wdata, s_axil_wstrb);
            o_cfg_tensor_spatial_size <= merged[15:0];
          end
          REG_TENSOR_DOPPLER: begin
            merged = apply_wstrb({16'd0, o_cfg_tensor_doppler_size}, s_axil_wdata, s_axil_wstrb);
            o_cfg_tensor_doppler_size <= merged[15:0];
          end
          REG_TENSOR_RANGE: begin
            merged = apply_wstrb({16'd0, o_cfg_tensor_range_size}, s_axil_wdata, s_axil_wstrb);
            o_cfg_tensor_range_size <= merged[15:0];
          end
          REG_IRQ_MASK: begin
            merged = apply_wstrb({28'd0, irq_mask_reg}, s_axil_wdata, s_axil_wstrb);
            irq_mask_reg <= merged[3:0];
          end
          REG_IRQ_CLEAR: begin
            merged = apply_wstrb(32'd0, s_axil_wdata, s_axil_wstrb);
            if (merged[0]) enc_done_pending <= 1'b0;
            if (merged[1]) dec_done_pending <= 1'b0;
            if (merged[2]) enc_error_pending <= 1'b0;
            if (merged[3]) dec_error_pending <= 1'b0;
          end
          default: begin
          end
        endcase
      end

      if (!s_axil_rvalid && s_axil_arvalid) begin
        s_axil_arready <= 1'b1;
        s_axil_rvalid <= 1'b1;
        s_axil_rresp <= 2'b00;
        s_axil_rdata <= rdata_next;
      end
    end
  end
endmodule
