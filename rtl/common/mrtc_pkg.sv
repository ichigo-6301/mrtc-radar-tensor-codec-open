package mrtc_pkg;
  localparam int MRTC_I_W = 16;
  localparam int MRTC_Q_W = 16;
  localparam int MRTC_COMPLEX_SAMPLE_W = MRTC_I_W + MRTC_Q_W;
  localparam int MRTC_PHASES_PER_BEAT = 4;
  localparam int MRTC_AXIS_DATA_W = MRTC_COMPLEX_SAMPLE_W * MRTC_PHASES_PER_BEAT;
  localparam int MRTC_AXIS_TUSER_W = 8;
  localparam int MRTC_AXIS_BYTES = MRTC_AXIS_DATA_W / 8;
  localparam int MRTC_VALID_BYTE_COUNT_W = $clog2(MRTC_AXIS_BYTES + 1);
  localparam int MRTC_COMP_BLOCK_BYTES = 4096;
  localparam int MRTC_COMPLEX_SAMPLES_PER_BLOCK =
    MRTC_COMP_BLOCK_BYTES / (MRTC_COMPLEX_SAMPLE_W / 8);
  localparam int MRTC_BLOCK_BEATS = MRTC_COMP_BLOCK_BYTES / MRTC_AXIS_BYTES;
  localparam int MRTC_PREFIX_COMPLEX_SAMPLES = 256;
  localparam int MRTC_PREFIX_BEATS = MRTC_PREFIX_COMPLEX_SAMPLES / MRTC_PHASES_PER_BEAT;

  // Legacy aliases kept for current-config compatibility while R7B plumbing
  // moves active modules to the phase-centric names above.
  localparam int MRTC_SAMPLE_W = MRTC_I_W;
  localparam int MRTC_IQ_COMP = 2;
  localparam int MRTC_SAMPLE_BITS = MRTC_COMPLEX_SAMPLE_W;
  localparam int MRTC_SAMPLE_PAIR_W = MRTC_COMPLEX_SAMPLE_W;
  localparam int MRTC_LANES = MRTC_PHASES_PER_BEAT;
  localparam int MRTC_SAMPLES_PER_WORD = MRTC_PHASES_PER_BEAT;

  localparam int MRTC_BLOCK_SPATIAL_LEN = 1;
  localparam int MRTC_BLOCK_DOPPLER_LEN = 64;
  localparam int MRTC_BLOCK_RANGE_LEN = 16;
  localparam int MRTC_BLOCK_SAMPLES = MRTC_COMPLEX_SAMPLES_PER_BLOCK;
  localparam int MRTC_RAW_BYTES = MRTC_COMP_BLOCK_BYTES;
  localparam int MRTC_HEADER_BYTES = 64;
  localparam int MRTC_MAX_PAYLOAD_BYTES = MRTC_RAW_BYTES;
  localparam int MRTC_MAX_OUTPUT_BYTES = MRTC_HEADER_BYTES + MRTC_RAW_BYTES;

  localparam int MRTC_DEFAULT_TENSOR_SPATIAL = 1;
  localparam int MRTC_DEFAULT_TENSOR_DOPPLER = 64;
  localparam int MRTC_DEFAULT_TENSOR_RANGE = 16;

  localparam int MRTC_I_W_CHECK =
    1 / ((MRTC_I_W == 16) ? 1 : 0);
  localparam int MRTC_Q_W_CHECK =
    1 / ((MRTC_Q_W == 16) ? 1 : 0);
  localparam int MRTC_COMPLEX_SAMPLE_W_CHECK =
    1 / ((MRTC_COMPLEX_SAMPLE_W == 32) ? 1 : 0);
  localparam int MRTC_PHASES_PER_BEAT_SUPPORTED_CHECK =
    1 / (((MRTC_PHASES_PER_BEAT == 2) ||
          (MRTC_PHASES_PER_BEAT == 4) ||
          (MRTC_PHASES_PER_BEAT == 8)) ? 1 : 0);
  localparam int MRTC_LANES_SUPPORTED_CHECK =
    1 / (((MRTC_LANES == 1) ||
          (MRTC_LANES == 2) ||
          (MRTC_LANES == 4) ||
          (MRTC_LANES == 8) ||
          (MRTC_LANES == 16)) ? 1 : 0);
  localparam int MRTC_AXIS_DATA_W_CHECK =
    1 / ((MRTC_AXIS_DATA_W == (MRTC_PHASES_PER_BEAT * MRTC_COMPLEX_SAMPLE_W)) ? 1 : 0);
  localparam int MRTC_AXIS_BYTES_CHECK =
    1 / ((MRTC_AXIS_BYTES == (MRTC_AXIS_DATA_W / 8)) ? 1 : 0);
  localparam int MRTC_BLOCK_LANE_ALIGN_CHECK =
    1 / (((MRTC_BLOCK_SAMPLES % MRTC_LANES) == 0) ? 1 : 0);
  localparam int MRTC_COMP_BLOCK_BYTES_CHECK =
    1 / ((MRTC_COMP_BLOCK_BYTES == 4096) ? 1 : 0);
  localparam int MRTC_BLOCK_BYTE_ALIGN_CHECK =
    1 / (((MRTC_COMP_BLOCK_BYTES % MRTC_AXIS_BYTES) == 0) ? 1 : 0);
  localparam int MRTC_COMPLEX_SAMPLES_PER_BLOCK_CHECK =
    1 / ((MRTC_COMPLEX_SAMPLES_PER_BLOCK == 1024) ? 1 : 0);
  localparam int MRTC_PREFIX_BEAT_ALIGN_CHECK =
    1 / (((MRTC_PREFIX_COMPLEX_SAMPLES % MRTC_PHASES_PER_BEAT) == 0) ? 1 : 0);

  localparam logic [15:0] MRTC_MAGIC = 16'h4D52;
  localparam logic [7:0] MRTC_VERSION = 8'd1;
  localparam logic [7:0] MRTC_SAMPLE_I16Q16 = 8'd1;

  typedef enum logic [7:0] {
    MRTC_CODEC_RAW        = 8'd0,
    MRTC_CODEC_ZERO_RICE  = 8'd1,
    MRTC_CODEC_DELTA_RICE = 8'd2,
    MRTC_CODEC_RLE_RICE   = 8'd3
  } mrtc_codec_t;

  typedef enum logic [7:0] {
    MRTC_RICE_FIXED_K          = 8'd0,
    MRTC_RICE_BLOCK_ADAPTIVE_K = 8'd1
  } mrtc_rice_mode_t;

  localparam int MRTC_K_POLICY_FULL_ADAPTIVE = 0;
  localparam int MRTC_K_POLICY_PREFIX_FAST   = 1;
  localparam int MRTC_BPACK_ARCH_LEGACY_SAMPLE = 0;
  localparam int MRTC_BPACK_ARCH_LANE_WORD     = 1;

  localparam logic [15:0] MRTC_FLAG_RAW_BYPASS       = 16'h0001;
  localparam logic [15:0] MRTC_FLAG_LAST_BLOCK       = 16'h0002;
  localparam logic [15:0] MRTC_FLAG_CRC_ENABLE       = 16'h0004;
  localparam logic [15:0] MRTC_FLAG_BLOCK_ADAPTIVE_K = 16'h0008;
  localparam logic [15:0] MRTC_FLAG_RLE_ENABLE       = 16'h0010;
  localparam logic [15:0] MRTC_FLAG_SAMPLE_MAJOR_IQ  = 16'h0020;
  localparam logic [15:0] MRTC_FLAG_PREFIX_K_FAST    = 16'h0040;
  localparam logic [15:0] MRTC_FLAG_STREAM_LENGTH_BY_TLAST = 16'h0080;

  localparam int MRTC_HDR_OFF_MAGIC          = 0;
  localparam int MRTC_HDR_OFF_VERSION        = 2;
  localparam int MRTC_HDR_OFF_HEADER_LEN     = 3;
  localparam int MRTC_HDR_OFF_FRAME_ID       = 4;
  localparam int MRTC_HDR_OFF_BLOCK_ID       = 6;
  localparam int MRTC_HDR_OFF_TENSOR_SPATIAL = 8;
  localparam int MRTC_HDR_OFF_TENSOR_DOPPLER = 10;
  localparam int MRTC_HDR_OFF_TENSOR_RANGE   = 12;
  localparam int MRTC_HDR_OFF_BLOCK_SPATIAL  = 14;
  localparam int MRTC_HDR_OFF_BLOCK_DOPPLER  = 16;
  localparam int MRTC_HDR_OFF_BLOCK_RANGE    = 18;
  localparam int MRTC_HDR_OFF_BLOCK_SP_LEN   = 20;
  localparam int MRTC_HDR_OFF_BLOCK_DOP_LEN  = 21;
  localparam int MRTC_HDR_OFF_BLOCK_RNG_LEN  = 22;
  localparam int MRTC_HDR_OFF_SAMPLE_FORMAT  = 24;
  localparam int MRTC_HDR_OFF_CODEC_MODE     = 25;
  localparam int MRTC_HDR_OFF_PRED_MODE      = 26;
  localparam int MRTC_HDR_OFF_RICE_K         = 27;
  localparam int MRTC_HDR_OFF_FLAGS          = 28;
  localparam int MRTC_HDR_OFF_RESERVED0      = 30;
  localparam int MRTC_HDR_OFF_RAW_BYTES      = 32;
  localparam int MRTC_HDR_OFF_PAYLOAD_BYTES  = 36;
  localparam int MRTC_HDR_OFF_PAYLOAD_BITS   = 40;
  localparam int MRTC_HDR_OFF_CRC32          = 44;
  localparam int MRTC_HDR_OFF_RESERVED1      = 48;

  localparam logic [31:0] MRTC_ERR_NONE                      = 32'd0;
  localparam logic [31:0] MRTC_ERR_TLAST_EARLY               = 32'd1;
  localparam logic [31:0] MRTC_ERR_UNSUPPORTED_CODEC         = 32'd2;
  localparam logic [31:0] MRTC_ERR_UNSUPPORTED_RICE          = 32'd3;
  localparam logic [31:0] MRTC_ERR_BLOCK_NOT_READY           = 32'd4;
  localparam logic [31:0] MRTC_ERR_SERIALIZER_STALL          = 32'd5;
  localparam logic [31:0] MRTC_ERR_BAD_MAGIC                 = 32'd6;
  localparam logic [31:0] MRTC_ERR_BAD_VERSION               = 32'd7;
  localparam logic [31:0] MRTC_ERR_BAD_HEADER_LEN            = 32'd8;
  localparam logic [31:0] MRTC_ERR_UNSUPPORTED_SAMPLE_FORMAT = 32'd9;
  localparam logic [31:0] MRTC_ERR_PAYLOAD_TOO_LONG          = 32'd10;
  localparam logic [31:0] MRTC_ERR_RICE_TRUNCATED            = 32'd11;
  localparam logic [31:0] MRTC_ERR_SAMPLE_RANGE              = 32'd12;
  localparam logic [31:0] MRTC_ERR_INPUT_TOO_SHORT           = 32'd13;
  localparam logic [31:0] MRTC_ERR_BLOCK_SIZE                = 32'd14;
  localparam logic [31:0] MRTC_ERR_PAYLOAD_TRUNCATED         = 32'd15;
  localparam logic [31:0] MRTC_ERR_PAYLOAD_BITS_SHORT        = 32'd16;
  localparam logic [31:0] MRTC_ERR_RAW_BYTES_MISMATCH        = 32'd17;
  localparam logic [31:0] MRTC_ERR_BAD_BLOCK_SHAPE           = 32'd18;
  localparam logic [31:0] MRTC_ERR_INTERNAL_STATE            = 32'd19;

  localparam logic [31:0] MRTC_ERR_UNSUPPORTED_SAMPLE        = MRTC_ERR_UNSUPPORTED_SAMPLE_FORMAT;

  localparam int MRTC_POINT_AXIS_DATA_W = 128;
  localparam int MRTC_PC_MAX_POINTS_PER_BLOCK = 64;
  localparam logic [7:0] MRTC_PC_REC_POINT     = 8'h50;
  localparam logic [7:0] MRTC_PC_REC_BLOCK_END = 8'hE0;

  function automatic logic [15:0] mrtc_le16(input logic [15:0] value);
    mrtc_le16 = value;
  endfunction

  function automatic logic [31:0] mrtc_le32(input logic [31:0] value);
    mrtc_le32 = value;
  endfunction
endpackage
