module mrtc_rice_k_select #(
  parameter int BLOCK_SAMPLES = 1024,
  parameter int RAW_BYTES = 4096,
  parameter int HEADER_BYTES = 64
) (
  input  logic        i_enable,
  input  logic [(BLOCK_SAMPLES*32)-1:0] i_block_mem_flat,
  input  logic [7:0]  i_codec_mode,
  input  logic [7:0]  i_rice_mode,
  input  logic [3:0]  i_fixed_k,
  output logic [7:0]  o_selected_k,
  output logic [31:0] o_payload_bits,
  output logic [31:0] o_payload_bytes,
  output logic        o_use_raw,
  output logic        o_unsupported_rice
);
  localparam logic [31:0] RAW_BYTES_U32    = 32'(RAW_BYTES);
  localparam logic [31:0] RAW_BITS_U32     = 32'(RAW_BYTES * 8);
  localparam logic [63:0] RAW_BYTES_U64    = 64'(RAW_BYTES);
  localparam logic [63:0] RAW_BITS_U64     = 64'(RAW_BYTES * 8);
  localparam logic [63:0] HEADER_BYTES_U64 = 64'(HEADER_BYTES);

  int unsigned sample_idx;
  int unsigned k_idx;
  logic signed [15:0] curr_i;
  logic signed [15:0] curr_q;
  logic signed [15:0] prev_i;
  logic signed [15:0] prev_q;
  logic signed [17:0] residual_i;
  logic signed [17:0] residual_q;
  logic [31:0]        mapped_i;
  logic [31:0]        mapped_q;
  logic [63:0]        best_bits;
  logic [63:0]        cand_bits;
  logic [7:0]         best_k;
  logic [31:0]        payload_bits_u32;
  logic [31:0]        payload_bytes_u32;
  logic [63:0]        final_bytes_u64;
  logic [31:0]        sample_word_u32;

  function automatic logic [31:0] get_sample_word(input int unsigned sample_index);
    get_sample_word = i_block_mem_flat[(sample_index*32) +: 32];
  endfunction

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    if (residual >= 0) begin
      residual_to_mapped = $unsigned(residual <<< 1);
    end else begin
      residual_to_mapped = $unsigned((-residual <<< 1) - 1);
    end
  endfunction

  function automatic logic [31:0] rice_bits_for_mapped(input logic [31:0] mapped, input logic [3:0] k_u);
    logic [31:0] quotient_u32;
    logic [31:0] k_ext_u32;
    begin
      quotient_u32 = mapped >> k_u;
      k_ext_u32 = {28'd0, k_u};
      rice_bits_for_mapped = quotient_u32 + 32'd1 + k_ext_u32;
    end
  endfunction

  always_comb begin
    o_selected_k       = {4'd0, i_fixed_k};
    o_payload_bits     = 32'd0;
    o_payload_bytes    = 32'd0;
    o_use_raw          = 1'b0;
    o_unsupported_rice = 1'b0;
    best_bits          = 64'hFFFF_FFFF_FFFF_FFFF;
    best_k             = {4'd0, i_fixed_k};

    if (!i_enable) begin
      o_selected_k = {4'd0, i_fixed_k};
      o_payload_bits = 32'd0;
      o_payload_bytes = 32'd0;
      o_use_raw = 1'b0;
      o_unsupported_rice = 1'b0;
    end else if (i_codec_mode == 8'd0) begin
      o_selected_k    = {4'd0, i_fixed_k};
      o_payload_bits  = RAW_BITS_U32;
      o_payload_bytes = RAW_BYTES_U32;
      o_use_raw       = 1'b1;
    end else if ((i_codec_mode != 8'd1) && (i_codec_mode != 8'd2)) begin
      o_unsupported_rice = 1'b1;
      o_use_raw          = 1'b1;
      o_payload_bits     = RAW_BITS_U32;
      o_payload_bytes    = RAW_BYTES_U32;
    end else begin
      if (i_rice_mode == 8'd0) begin
        best_bits = 64'd0;
        prev_i = '0;
        prev_q = '0;
        for (sample_idx = 0; sample_idx < BLOCK_SAMPLES; sample_idx = sample_idx + 1) begin
          sample_word_u32 = get_sample_word(sample_idx);
          curr_i = $signed(sample_word_u32[15:0]);
          curr_q = $signed(sample_word_u32[31:16]);
          residual_i = (i_codec_mode == 8'd2 && sample_idx > 0) ? (curr_i - prev_i) : curr_i;
          residual_q = (i_codec_mode == 8'd2 && sample_idx > 0) ? (curr_q - prev_q) : curr_q;
          mapped_i = residual_to_mapped(residual_i);
          mapped_q = residual_to_mapped(residual_q);
          best_bits = best_bits + rice_bits_for_mapped(mapped_i, i_fixed_k);
          best_bits = best_bits + rice_bits_for_mapped(mapped_q, i_fixed_k);
          prev_i = curr_i;
          prev_q = curr_q;
        end
        o_selected_k = {4'd0, i_fixed_k};
      end else if (i_rice_mode == 8'd1) begin
        for (k_idx = 0; k_idx < 16; k_idx = k_idx + 1) begin
          cand_bits = 64'd0;
          prev_i = '0;
          prev_q = '0;
          for (sample_idx = 0; sample_idx < BLOCK_SAMPLES; sample_idx = sample_idx + 1) begin
            sample_word_u32 = get_sample_word(sample_idx);
            curr_i = $signed(sample_word_u32[15:0]);
            curr_q = $signed(sample_word_u32[31:16]);
            residual_i = (i_codec_mode == 8'd2 && sample_idx > 0) ? (curr_i - prev_i) : curr_i;
            residual_q = (i_codec_mode == 8'd2 && sample_idx > 0) ? (curr_q - prev_q) : curr_q;
            mapped_i = residual_to_mapped(residual_i);
            mapped_q = residual_to_mapped(residual_q);
            cand_bits = cand_bits + rice_bits_for_mapped(mapped_i, k_idx[3:0]);
            cand_bits = cand_bits + rice_bits_for_mapped(mapped_q, k_idx[3:0]);
            prev_i = curr_i;
            prev_q = curr_q;
          end
          if (cand_bits < best_bits) begin
            best_bits = cand_bits;
            best_k = {4'd0, k_idx[3:0]};
          end
        end
        o_selected_k = best_k;
      end else begin
        o_unsupported_rice = 1'b1;
        best_bits = RAW_BITS_U64;
      end

      payload_bits_u32  = best_bits[31:0];
      payload_bytes_u32 = (best_bits[31:0] + 32'd7) >> 3;
      final_bytes_u64   = HEADER_BYTES_U64 + {32'd0, payload_bytes_u32};

      o_payload_bits  = payload_bits_u32;
      o_payload_bytes = payload_bytes_u32;
      o_use_raw       = (final_bytes_u64 >= RAW_BYTES_U64);
    end
  end
endmodule
