module mrtc_comp_output_packer #(
  parameter int HEADER_BYTES = 64,
  parameter int RAW_BYTES = 4096,
  parameter int BLOCK_SAMPLES = 1024,
  parameter int MAX_PAYLOAD_BYTES = 4096
) (
  input  logic [(HEADER_BYTES*8)-1:0]       i_header_bytes_flat,
  input  logic        i_use_raw,
  input  logic [(BLOCK_SAMPLES*32)-1:0]     i_block_mem_flat,
  input  logic [(MAX_PAYLOAD_BYTES*8)-1:0]  i_comp_payload_flat,
  input  logic [31:0] i_payload_bytes,
  input  logic [12:0] i_stream_byte_idx,
  output logic [31:0] o_total_bytes,
  output logic [7:0]  o_stream_byte
);
  logic [7:0] payload_byte;
  logic [11:0] payload_idx;

  always_comb begin
    if (i_stream_byte_idx >= HEADER_BYTES) begin
      payload_idx = i_stream_byte_idx[11:0] - HEADER_BYTES[11:0];
    end else begin
      payload_idx = '0;
    end
  end

  function automatic logic [7:0] get_header_byte(input logic [12:0] header_index);
    get_header_byte = i_header_bytes_flat[(header_index*8) +: 8];
  endfunction

  mrtc_raw_bypass_mux #(
    .BLOCK_SAMPLES(BLOCK_SAMPLES),
    .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES)
  ) u_raw_bypass_mux (
    .i_use_raw         (i_use_raw),
    .i_block_mem_flat  (i_block_mem_flat),
    .i_comp_payload_flat(i_comp_payload_flat),
    .i_payload_idx     (payload_idx),
    .o_payload_byte(payload_byte)
  );

  always_comb begin
    o_total_bytes = HEADER_BYTES + (i_use_raw ? RAW_BYTES : i_payload_bytes);
    if (i_stream_byte_idx < HEADER_BYTES) begin
      o_stream_byte = get_header_byte(i_stream_byte_idx);
    end else begin
      o_stream_byte = payload_byte;
    end
  end
endmodule
