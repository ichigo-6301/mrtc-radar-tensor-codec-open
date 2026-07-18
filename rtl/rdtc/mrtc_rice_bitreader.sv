module mrtc_rice_bitreader #(
  parameter int MAX_PAYLOAD_BYTES = 4096
) (
  input  logic [(MAX_PAYLOAD_BYTES*8)-1:0] i_payload_flat,
  input  logic [31:0] i_payload_bits,
  input  logic [31:0] i_start_bit_pos,
  input  logic [7:0]  i_rice_k,
  output logic [31:0] o_mapped,
  output logic [31:0] o_next_bit_pos,
  output logic        o_payload_exhausted,
  output logic        o_structural_error
);
  integer idx;
  integer rem_idx;
  logic bit_value;
  logic found_stop;
  logic [31:0] q_count;
  logic [31:0] rem_value;
  logic [31:0] pos;

  function automatic logic get_payload_bit(input logic [31:0] payload_bit_pos);
    logic [31:0] byte_index;
    logic [2:0]  bit_index;
    logic [7:0]  byte_value;
    begin
      byte_index = payload_bit_pos >> 3;
      bit_index  = payload_bit_pos[2:0];
      byte_value = i_payload_flat[(byte_index*8) +: 8];
      get_payload_bit = byte_value[7 - bit_index];
    end
  endfunction

  always_comb begin
    o_mapped = 32'd0;
    o_next_bit_pos = i_start_bit_pos;
    o_payload_exhausted = 1'b0;
    o_structural_error = 1'b0;
    q_count = 32'd0;
    rem_value = 32'd0;
    pos = i_start_bit_pos;
    found_stop = 1'b0;

    if (i_start_bit_pos >= i_payload_bits) begin
      o_payload_exhausted = 1'b1;
    end else begin
      for (idx = 0; idx < (MAX_PAYLOAD_BYTES * 8); idx = idx + 1) begin
        if (!found_stop && !o_payload_exhausted && !o_structural_error && (pos < i_payload_bits)) begin
          bit_value = get_payload_bit(pos);
          pos = pos + 32'd1;
          if (bit_value) begin
            q_count = q_count + 32'd1;
          end else begin
            found_stop = 1'b1;
          end
        end
      end

      if (!found_stop) begin
        o_structural_error = 1'b1;
      end else begin
        for (rem_idx = 0; rem_idx < 8; rem_idx = rem_idx + 1) begin
          if (rem_idx < i_rice_k) begin
            if (pos >= i_payload_bits) begin
              o_payload_exhausted = 1'b1;
            end else begin
              rem_value = (rem_value << 1) | {31'd0, get_payload_bit(pos)};
              pos = pos + 32'd1;
            end
          end
        end
      end
    end

    if (!o_payload_exhausted && !o_structural_error) begin
      o_mapped = (q_count << i_rice_k) | rem_value;
      o_next_bit_pos = pos;
    end
  end
endmodule
