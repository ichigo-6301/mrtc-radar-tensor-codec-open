module mrtc_header_gen (
  input  logic [15:0] i_frame_id,
  input  logic [15:0] i_block_id,
  input  logic [15:0] i_tensor_spatial_size,
  input  logic [15:0] i_tensor_doppler_size,
  input  logic [15:0] i_tensor_range_size,
  input  logic [15:0] i_block_spatial_start,
  input  logic [15:0] i_block_doppler_start,
  input  logic [15:0] i_block_range_start,
  input  logic [7:0]  i_block_spatial_len,
  input  logic [7:0]  i_block_doppler_len,
  input  logic [15:0] i_block_range_len,
  input  logic [7:0]  i_sample_format,
  input  logic [7:0]  i_codec_mode,
  input  logic [7:0]  i_predictor_mode,
  input  logic [7:0]  i_rice_k,
  input  logic [15:0] i_flags,
  input  logic [31:0] i_raw_bytes,
  input  logic [31:0] i_payload_bytes,
  input  logic [31:0] i_payload_bits,
  input  logic [31:0] i_crc32,
  output logic [(64*8)-1:0] o_header_bytes_flat
);
  integer idx;

  always_comb begin
    for (idx = 0; idx < 64; idx = idx + 1) begin
      o_header_bytes_flat[(idx*8) +: 8] = 8'h00;
    end

    o_header_bytes_flat[(0*8)  +: 8] = 8'h52;
    o_header_bytes_flat[(1*8)  +: 8] = 8'h4D;
    o_header_bytes_flat[(2*8)  +: 8] = 8'd1;
    o_header_bytes_flat[(3*8)  +: 8] = 8'd64;
    o_header_bytes_flat[(4*8)  +: 8] = i_frame_id[7:0];
    o_header_bytes_flat[(5*8)  +: 8] = i_frame_id[15:8];
    o_header_bytes_flat[(6*8)  +: 8] = i_block_id[7:0];
    o_header_bytes_flat[(7*8)  +: 8] = i_block_id[15:8];
    o_header_bytes_flat[(8*8)  +: 8] = i_tensor_spatial_size[7:0];
    o_header_bytes_flat[(9*8)  +: 8] = i_tensor_spatial_size[15:8];
    o_header_bytes_flat[(10*8) +: 8] = i_tensor_doppler_size[7:0];
    o_header_bytes_flat[(11*8) +: 8] = i_tensor_doppler_size[15:8];
    o_header_bytes_flat[(12*8) +: 8] = i_tensor_range_size[7:0];
    o_header_bytes_flat[(13*8) +: 8] = i_tensor_range_size[15:8];
    o_header_bytes_flat[(14*8) +: 8] = i_block_spatial_start[7:0];
    o_header_bytes_flat[(15*8) +: 8] = i_block_spatial_start[15:8];
    o_header_bytes_flat[(16*8) +: 8] = i_block_doppler_start[7:0];
    o_header_bytes_flat[(17*8) +: 8] = i_block_doppler_start[15:8];
    o_header_bytes_flat[(18*8) +: 8] = i_block_range_start[7:0];
    o_header_bytes_flat[(19*8) +: 8] = i_block_range_start[15:8];
    o_header_bytes_flat[(20*8) +: 8] = i_block_spatial_len;
    o_header_bytes_flat[(21*8) +: 8] = i_block_doppler_len;
    o_header_bytes_flat[(22*8) +: 8] = i_block_range_len[7:0];
    o_header_bytes_flat[(23*8) +: 8] = i_block_range_len[15:8];
    o_header_bytes_flat[(24*8) +: 8] = i_sample_format;
    o_header_bytes_flat[(25*8) +: 8] = i_codec_mode;
    o_header_bytes_flat[(26*8) +: 8] = i_predictor_mode;
    o_header_bytes_flat[(27*8) +: 8] = i_rice_k;
    o_header_bytes_flat[(28*8) +: 8] = i_flags[7:0];
    o_header_bytes_flat[(29*8) +: 8] = i_flags[15:8];
    o_header_bytes_flat[(32*8) +: 8] = i_raw_bytes[7:0];
    o_header_bytes_flat[(33*8) +: 8] = i_raw_bytes[15:8];
    o_header_bytes_flat[(34*8) +: 8] = i_raw_bytes[23:16];
    o_header_bytes_flat[(35*8) +: 8] = i_raw_bytes[31:24];
    o_header_bytes_flat[(36*8) +: 8] = i_payload_bytes[7:0];
    o_header_bytes_flat[(37*8) +: 8] = i_payload_bytes[15:8];
    o_header_bytes_flat[(38*8) +: 8] = i_payload_bytes[23:16];
    o_header_bytes_flat[(39*8) +: 8] = i_payload_bytes[31:24];
    o_header_bytes_flat[(40*8) +: 8] = i_payload_bits[7:0];
    o_header_bytes_flat[(41*8) +: 8] = i_payload_bits[15:8];
    o_header_bytes_flat[(42*8) +: 8] = i_payload_bits[23:16];
    o_header_bytes_flat[(43*8) +: 8] = i_payload_bits[31:24];
    o_header_bytes_flat[(44*8) +: 8] = i_crc32[7:0];
    o_header_bytes_flat[(45*8) +: 8] = i_crc32[15:8];
    o_header_bytes_flat[(46*8) +: 8] = i_crc32[23:16];
    o_header_bytes_flat[(47*8) +: 8] = i_crc32[31:24];
  end
endmodule
