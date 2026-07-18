module mrtc_rice_bitpacker #(
  parameter int BLOCK_SAMPLES = 1024,
  parameter int MAX_PAYLOAD_BYTES = 4096
) (
  input  logic        i_enable,
  input  logic [(BLOCK_SAMPLES*32)-1:0] i_block_mem_flat,
  input  logic [7:0]  i_codec_mode,
  input  logic [7:0]  i_selected_k,
  output logic [(MAX_PAYLOAD_BYTES*8)-1:0] o_payload_flat,
  output logic [31:0] o_payload_bits,
  output logic [31:0] o_payload_bytes
);
  integer idx;
  integer bit_pos;
  integer bit_idx;
  integer unary_idx;
  integer byte_idx_tmp;
  integer bit_in_byte_tmp;
  logic signed [15:0] curr_i;
  logic signed [15:0] curr_q;
  logic signed [15:0] prev_i;
  logic signed [15:0] prev_q;
  logic signed [17:0] residual_i;
  logic signed [17:0] residual_q;
  logic [31:0]        mapped_i;
  logic [31:0]        mapped_q;
  logic [31:0]        quotient;
  logic [31:0]        remainder;
  logic [31:0]        sample_word_u32;
  logic [7:0]         payload_mem [0:MAX_PAYLOAD_BYTES-1];

  function automatic logic [31:0] get_sample_word(input integer sample_index);
    get_sample_word = i_block_mem_flat[(sample_index*32) +: 32];
  endfunction

  function automatic logic [31:0] residual_to_mapped(input logic signed [17:0] residual);
    if (residual >= 0) begin
      residual_to_mapped = $unsigned(residual <<< 1);
    end else begin
      residual_to_mapped = $unsigned((-residual <<< 1) - 1);
    end
  endfunction

  always_comb begin
    for (idx = 0; idx < MAX_PAYLOAD_BYTES; idx = idx + 1) begin
        payload_mem[idx] = 8'h00;
    end

    bit_pos = 0;
    prev_i = '0;
    prev_q = '0;

    if (i_enable) begin
      for (idx = 0; idx < BLOCK_SAMPLES; idx = idx + 1) begin
        sample_word_u32 = get_sample_word(idx);
        curr_i = sample_word_u32[15:0];
        curr_q = sample_word_u32[31:16];
        residual_i = (i_codec_mode == 8'd2 && idx > 0) ? (curr_i - prev_i) : curr_i;
        mapped_i = residual_to_mapped(residual_i);
        quotient = mapped_i >> i_selected_k[3:0];
        remainder = mapped_i & ((32'd1 << i_selected_k[3:0]) - 1);
        for (unary_idx = 0; unary_idx < quotient; unary_idx = unary_idx + 1) begin
          byte_idx_tmp = bit_pos >> 3;
          bit_in_byte_tmp = 7 - (bit_pos & 7);
          payload_mem[byte_idx_tmp][bit_in_byte_tmp] = 1'b1;
          bit_pos = bit_pos + 1;
        end
        bit_pos = bit_pos + 1;
        for (bit_idx = i_selected_k[3:0] - 1; bit_idx >= 0; bit_idx = bit_idx - 1) begin
          if (remainder[bit_idx]) begin
            byte_idx_tmp = bit_pos >> 3;
            bit_in_byte_tmp = 7 - (bit_pos & 7);
            payload_mem[byte_idx_tmp][bit_in_byte_tmp] = 1'b1;
          end
          bit_pos = bit_pos + 1;
        end
        residual_q = (i_codec_mode == 8'd2 && idx > 0) ? (curr_q - prev_q) : curr_q;
        mapped_q = residual_to_mapped(residual_q);
        quotient = mapped_q >> i_selected_k[3:0];
        remainder = mapped_q & ((32'd1 << i_selected_k[3:0]) - 1);
        for (unary_idx = 0; unary_idx < quotient; unary_idx = unary_idx + 1) begin
          byte_idx_tmp = bit_pos >> 3;
          bit_in_byte_tmp = 7 - (bit_pos & 7);
          payload_mem[byte_idx_tmp][bit_in_byte_tmp] = 1'b1;
          bit_pos = bit_pos + 1;
        end
        bit_pos = bit_pos + 1;
        for (bit_idx = i_selected_k[3:0] - 1; bit_idx >= 0; bit_idx = bit_idx - 1) begin
          if (remainder[bit_idx]) begin
            byte_idx_tmp = bit_pos >> 3;
            bit_in_byte_tmp = 7 - (bit_pos & 7);
            payload_mem[byte_idx_tmp][bit_in_byte_tmp] = 1'b1;
          end
          bit_pos = bit_pos + 1;
        end
        prev_i = curr_i;
        prev_q = curr_q;
      end
    end

    o_payload_bits = bit_pos[31:0];
    o_payload_bytes = (bit_pos[31:0] + 32'd7) >> 3;
  end

  generate
    genvar payload_idx;
    for (payload_idx = 0; payload_idx < MAX_PAYLOAD_BYTES; payload_idx = payload_idx + 1) begin : g_payload_flat
      assign o_payload_flat[(payload_idx*8) +: 8] = payload_mem[payload_idx];
    end
  endgenerate
endmodule
