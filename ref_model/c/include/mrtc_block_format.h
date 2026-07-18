#ifndef MRTC_BLOCK_FORMAT_H
#define MRTC_BLOCK_FORMAT_H

#include <stdint.h>

#define MRTC_HEADER_BYTES 64
#define MRTC_MAGIC 0x4D52u
#define MRTC_VERSION 1u
#define MRTC_BLOCK_MODE_A_SAMPLES 1024
#define MRTC_BLOCK_MODE_A_RAW_BYTES 4096

enum {
    MRTC_SAMPLE_I16Q16 = 1
};

enum {
    MRTC_CODEC_RAW = 0,
    MRTC_CODEC_ZERO_RICE = 1,
    MRTC_CODEC_DELTA_RICE = 2,
    MRTC_CODEC_RLE_RICE = 3
};

enum {
    MRTC_RICE_FIXED_K = 0,
    MRTC_RICE_BLOCK_ADAPTIVE_K = 1
};

enum {
    MRTC_FLAG_RAW_BYPASS = 1u << 0,
    MRTC_FLAG_LAST_BLOCK = 1u << 1,
    MRTC_FLAG_CRC_ENABLE = 1u << 2,
    MRTC_FLAG_BLOCK_ADAPTIVE_K = 1u << 3,
    MRTC_FLAG_RLE_ENABLE = 1u << 4,
    MRTC_FLAG_SAMPLE_MAJOR_IQ = 1u << 5
};

typedef struct mrtc_block_header_t {
    uint16_t magic;
    uint8_t  version;
    uint8_t  header_len;
    uint16_t frame_id;
    uint16_t block_id;
    uint16_t tensor_spatial_size;
    uint16_t tensor_doppler_size;
    uint16_t tensor_range_size;
    uint16_t block_spatial_start;
    uint16_t block_doppler_start;
    uint16_t block_range_start;
    uint8_t  block_spatial_len;
    uint8_t  block_doppler_len;
    uint16_t block_range_len;
    uint8_t  sample_format;
    uint8_t  codec_mode;
    uint8_t  predictor_mode;
    uint8_t  rice_k;
    uint16_t flags;
    uint16_t reserved0;
    uint32_t raw_bytes;
    uint32_t payload_bytes;
    uint32_t payload_bits;
    uint32_t crc32;
    uint8_t  reserved[16];
} mrtc_block_header_t;

int mrtc_pack_header_le(const mrtc_block_header_t *h, uint8_t out[MRTC_HEADER_BYTES]);
int mrtc_unpack_header_le(const uint8_t in[MRTC_HEADER_BYTES], mrtc_block_header_t *h);
void mrtc_init_block_mode_a_header(mrtc_block_header_t *h);

#endif
