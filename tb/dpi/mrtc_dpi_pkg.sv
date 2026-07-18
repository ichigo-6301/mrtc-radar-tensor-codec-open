`timescale 1ns/1ps

package mrtc_dpi_pkg;
  import "DPI-C" function int dpi_mrtc_rdtc_encode_block(
    input  shortint i_data[],
    input  shortint q_data[],
    input  int      num_samples,
    input  int      codec_mode,
    input  int      rice_mode,
    input  int      fixed_k,
    input  int      frame_id,
    input  int      block_id,
    input  int      spatial_start,
    input  int      doppler_start,
    input  int      range_start,
    output byte unsigned out_bytes[],
    input  int      out_max_bytes,
    output int      out_num_bytes,
    output int      raw_bypass,
    output int      selected_k
  );

  import "DPI-C" function int dpi_mrtc_rdtc_decode_block(
    input  byte unsigned in_bytes[],
    input  int      in_num_bytes,
    output shortint out_i[],
    output shortint out_q[],
    input  int      max_samples,
    output int      out_num_samples
  );

  localparam int MRTC_CODEC_RAW        = 0;
  localparam int MRTC_CODEC_ZERO_RICE  = 1;
  localparam int MRTC_CODEC_DELTA_RICE = 2;
  localparam int MRTC_CODEC_RLE_RICE   = 3;

  localparam int MRTC_RICE_FIXED_K = 0;
  localparam int MRTC_RICE_BLOCK_ADAPTIVE_K = 1;
endpackage
