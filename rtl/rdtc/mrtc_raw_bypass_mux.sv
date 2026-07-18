module mrtc_raw_bypass_mux #(
  parameter int BLOCK_SAMPLES = 1024,
  parameter int MAX_PAYLOAD_BYTES = 4096
) (
  input  logic        i_use_raw,
  input  logic [(BLOCK_SAMPLES*32)-1:0]     i_block_mem_flat,
  input  logic [(MAX_PAYLOAD_BYTES*8)-1:0]  i_comp_payload_flat,
  input  logic [11:0] i_payload_idx,
  output logic [7:0]  o_payload_byte
);
  logic [9:0] sample_idx;
  logic [1:0] byte_sel;
  logic [31:0] sample_word_u32;

  function automatic logic [31:0] get_sample_word(input logic [9:0] sample_index);
    get_sample_word = i_block_mem_flat[(sample_index*32) +: 32];
  endfunction

  function automatic logic [7:0] get_payload_byte(input logic [11:0] payload_index);
    get_payload_byte = i_comp_payload_flat[(payload_index*8) +: 8];
  endfunction

  always_comb begin
    if (i_use_raw) begin
      sample_idx = i_payload_idx[11:2];
      byte_sel   = i_payload_idx[1:0];
      sample_word_u32 = get_sample_word(sample_idx);
      case (byte_sel)
        2'd0: o_payload_byte = sample_word_u32[7:0];
        2'd1: o_payload_byte = sample_word_u32[15:8];
        2'd2: o_payload_byte = sample_word_u32[23:16];
        default: o_payload_byte = sample_word_u32[31:24];
      endcase
    end else begin
      sample_word_u32 = 32'd0;
      o_payload_byte = get_payload_byte(i_payload_idx);
    end
  end
endmodule
