#include <string.h>
#include "mrtc_block_format.h"

static void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xffu);
    p[1] = (uint8_t)((v >> 8) & 0xffu);
}

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xffu);
    p[1] = (uint8_t)((v >> 8) & 0xffu);
    p[2] = (uint8_t)((v >> 16) & 0xffu);
    p[3] = (uint8_t)((v >> 24) & 0xffu);
}

static uint16_t get_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t get_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void mrtc_init_block_mode_a_header(mrtc_block_header_t *h) {
    memset(h, 0, sizeof(*h));
    h->magic = MRTC_MAGIC;
    h->version = MRTC_VERSION;
    h->header_len = MRTC_HEADER_BYTES;
    h->tensor_spatial_size = 1;
    h->tensor_doppler_size = 64;
    h->tensor_range_size = 16;
    h->block_spatial_len = 1;
    h->block_doppler_len = 64;
    h->block_range_len = 16;
    h->sample_format = MRTC_SAMPLE_I16Q16;
    h->codec_mode = MRTC_CODEC_ZERO_RICE;
    h->predictor_mode = MRTC_CODEC_ZERO_RICE;
    h->rice_k = 0;
    h->raw_bytes = MRTC_BLOCK_MODE_A_RAW_BYTES;
}

int mrtc_pack_header_le(const mrtc_block_header_t *h, uint8_t out[MRTC_HEADER_BYTES]) {
    if (!h || !out) return -1;
    memset(out, 0, MRTC_HEADER_BYTES);
    put_u16(out + 0, h->magic);
    out[2] = h->version;
    out[3] = h->header_len;
    put_u16(out + 4, h->frame_id);
    put_u16(out + 6, h->block_id);
    put_u16(out + 8, h->tensor_spatial_size);
    put_u16(out + 10, h->tensor_doppler_size);
    put_u16(out + 12, h->tensor_range_size);
    put_u16(out + 14, h->block_spatial_start);
    put_u16(out + 16, h->block_doppler_start);
    put_u16(out + 18, h->block_range_start);
    out[20] = h->block_spatial_len;
    out[21] = h->block_doppler_len;
    put_u16(out + 22, h->block_range_len);
    out[24] = h->sample_format;
    out[25] = h->codec_mode;
    out[26] = h->predictor_mode;
    out[27] = h->rice_k;
    put_u16(out + 28, h->flags);
    put_u16(out + 30, h->reserved0);
    put_u32(out + 32, h->raw_bytes);
    put_u32(out + 36, h->payload_bytes);
    put_u32(out + 40, h->payload_bits);
    put_u32(out + 44, h->crc32);
    memcpy(out + 48, h->reserved, 16);
    return 0;
}

int mrtc_unpack_header_le(const uint8_t in[MRTC_HEADER_BYTES], mrtc_block_header_t *h) {
    if (!h || !in) return -1;
    memset(h, 0, sizeof(*h));
    h->magic = get_u16(in + 0);
    h->version = in[2];
    h->header_len = in[3];
    h->frame_id = get_u16(in + 4);
    h->block_id = get_u16(in + 6);
    h->tensor_spatial_size = get_u16(in + 8);
    h->tensor_doppler_size = get_u16(in + 10);
    h->tensor_range_size = get_u16(in + 12);
    h->block_spatial_start = get_u16(in + 14);
    h->block_doppler_start = get_u16(in + 16);
    h->block_range_start = get_u16(in + 18);
    h->block_spatial_len = in[20];
    h->block_doppler_len = in[21];
    h->block_range_len = get_u16(in + 22);
    h->sample_format = in[24];
    h->codec_mode = in[25];
    h->predictor_mode = in[26];
    h->rice_k = in[27];
    h->flags = get_u16(in + 28);
    h->reserved0 = get_u16(in + 30);
    h->raw_bytes = get_u32(in + 32);
    h->payload_bytes = get_u32(in + 36);
    h->payload_bits = get_u32(in + 40);
    h->crc32 = get_u32(in + 44);
    memcpy(h->reserved, in + 48, 16);
    if (h->magic != MRTC_MAGIC) return -2;
    if (h->version != MRTC_VERSION) return -3;
    if (h->header_len != MRTC_HEADER_BYTES) return -4;
    return 0;
}
