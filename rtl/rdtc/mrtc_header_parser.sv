module mrtc_header_parser #(
  parameter int HEADER_BYTES = 64,
  parameter int MAX_PAYLOAD_BYTES = 4096
) (
  input  logic [(HEADER_BYTES*8)-1:0] i_header_bytes_flat,
  input  logic [31:0] i_captured_bytes,
  output logic [15:0] o_frame_id,
  output logic [15:0] o_block_id,
  output logic [15:0] o_tensor_spatial_size,
  output logic [15:0] o_tensor_doppler_size,
  output logic [15:0] o_tensor_range_size,
  output logic [15:0] o_block_spatial_start,
  output logic [15:0] o_block_doppler_start,
  output logic [15:0] o_block_range_start,
  output logic [7:0]  o_block_spatial_len,
  output logic [7:0]  o_block_doppler_len,
  output logic [15:0] o_block_range_len,
  output logic [7:0]  o_sample_format,
  output logic [7:0]  o_codec_mode,
  output logic [7:0]  o_predictor_mode,
  output logic [7:0]  o_rice_k,
  output logic [15:0] o_flags,
  output logic [31:0] o_raw_bytes,
  output logic [31:0] o_payload_bytes,
  output logic [31:0] o_payload_bits,
  output logic [31:0] o_crc32,
  output logic        o_is_raw_mode,
  output logic [31:0] o_error
);
  import mrtc_pkg::*;
  logic is_stream_length_packet;

  function automatic logic [7:0] get_byte(input int offset);
    get_byte = i_header_bytes_flat[(offset*8) +: 8];
  endfunction

  function automatic logic [15:0] get_le16(input int offset);
    get_le16 = {get_byte(offset + 1), get_byte(offset)};
  endfunction

  function automatic logic [31:0] get_le32(input int offset);
    get_le32 = {
      get_byte(offset + 3),
      get_byte(offset + 2),
      get_byte(offset + 1),
      get_byte(offset)
    };
  endfunction

  always_comb begin
    o_frame_id            = get_le16(MRTC_HDR_OFF_FRAME_ID);
    o_block_id            = get_le16(MRTC_HDR_OFF_BLOCK_ID);
    o_tensor_spatial_size = get_le16(MRTC_HDR_OFF_TENSOR_SPATIAL);
    o_tensor_doppler_size = get_le16(MRTC_HDR_OFF_TENSOR_DOPPLER);
    o_tensor_range_size   = get_le16(MRTC_HDR_OFF_TENSOR_RANGE);
    o_block_spatial_start = get_le16(MRTC_HDR_OFF_BLOCK_SPATIAL);
    o_block_doppler_start = get_le16(MRTC_HDR_OFF_BLOCK_DOPPLER);
    o_block_range_start   = get_le16(MRTC_HDR_OFF_BLOCK_RANGE);
    o_block_spatial_len   = get_byte(MRTC_HDR_OFF_BLOCK_SP_LEN);
    o_block_doppler_len   = get_byte(MRTC_HDR_OFF_BLOCK_DOP_LEN);
    o_block_range_len     = get_le16(MRTC_HDR_OFF_BLOCK_RNG_LEN);
    o_sample_format       = get_byte(MRTC_HDR_OFF_SAMPLE_FORMAT);
    o_codec_mode          = get_byte(MRTC_HDR_OFF_CODEC_MODE);
    o_predictor_mode      = get_byte(MRTC_HDR_OFF_PRED_MODE);
    o_rice_k              = get_byte(MRTC_HDR_OFF_RICE_K);
    o_flags               = get_le16(MRTC_HDR_OFF_FLAGS);
    o_raw_bytes           = get_le32(MRTC_HDR_OFF_RAW_BYTES);
    o_payload_bytes       = get_le32(MRTC_HDR_OFF_PAYLOAD_BYTES);
    o_payload_bits        = get_le32(MRTC_HDR_OFF_PAYLOAD_BITS);
    o_crc32               = get_le32(MRTC_HDR_OFF_CRC32);
    o_is_raw_mode         = (o_codec_mode == MRTC_CODEC_RAW) || ((o_flags & MRTC_FLAG_RAW_BYPASS) != 0);
    is_stream_length_packet =
      !o_is_raw_mode && ((o_flags & MRTC_FLAG_STREAM_LENGTH_BY_TLAST) != 0);
    o_error               = MRTC_ERR_NONE;

    if (get_le16(MRTC_HDR_OFF_MAGIC) != MRTC_MAGIC) begin
      o_error = MRTC_ERR_BAD_MAGIC;
    end else if (get_byte(MRTC_HDR_OFF_VERSION) != MRTC_VERSION) begin
      o_error = MRTC_ERR_BAD_VERSION;
    end else if (get_byte(MRTC_HDR_OFF_HEADER_LEN) != HEADER_BYTES) begin
      o_error = MRTC_ERR_BAD_HEADER_LEN;
    end else if (o_sample_format != MRTC_SAMPLE_I16Q16) begin
      o_error = MRTC_ERR_UNSUPPORTED_SAMPLE_FORMAT;
    end else if ((o_codec_mode != MRTC_CODEC_RAW) &&
                 (o_codec_mode != MRTC_CODEC_ZERO_RICE) &&
                 (o_codec_mode != MRTC_CODEC_DELTA_RICE)) begin
      o_error = MRTC_ERR_UNSUPPORTED_CODEC;
    end else if ((o_block_spatial_len != MRTC_BLOCK_SPATIAL_LEN) ||
                 (o_block_doppler_len != MRTC_BLOCK_DOPPLER_LEN) ||
                 (o_block_range_len != MRTC_BLOCK_RANGE_LEN)) begin
      o_error = MRTC_ERR_BAD_BLOCK_SHAPE;
    end else if (o_raw_bytes != (o_block_spatial_len * o_block_doppler_len * o_block_range_len * 4)) begin
      o_error = MRTC_ERR_RAW_BYTES_MISMATCH;
    end else if (o_raw_bytes != MRTC_RAW_BYTES) begin
      o_error = MRTC_ERR_RAW_BYTES_MISMATCH;
    end else if (!is_stream_length_packet && (o_payload_bytes > MAX_PAYLOAD_BYTES)) begin
      o_error = MRTC_ERR_PAYLOAD_TOO_LONG;
    end else if (!is_stream_length_packet && ((HEADER_BYTES + o_payload_bytes) > i_captured_bytes)) begin
      o_error = MRTC_ERR_PAYLOAD_TRUNCATED;
    end else if ((o_raw_bytes == 0) || (o_raw_bytes > MRTC_RAW_BYTES) || ((o_raw_bytes & 32'd3) != 0)) begin
      o_error = MRTC_ERR_BLOCK_SIZE;
    end else if (o_is_raw_mode && (o_payload_bytes != o_raw_bytes)) begin
      o_error = MRTC_ERR_RAW_BYTES_MISMATCH;
    end else if (!o_is_raw_mode && !is_stream_length_packet && (o_payload_bits > (o_payload_bytes << 3))) begin
      o_error = MRTC_ERR_PAYLOAD_BITS_SHORT;
    end
  end
endmodule
