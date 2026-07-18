#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "mrtc_rdtc_ref.h"

typedef struct { uint8_t *buf; int max_bytes; int bit_pos; } bit_writer_t;
uint32_t mrtc_residual_to_mapped(int32_t r);
int32_t mrtc_mapped_to_residual(uint32_t m);
void mrtc_bw_init(bit_writer_t *w, uint8_t *buf, int max_bytes);
int mrtc_rice_encode_mapped(bit_writer_t *w, uint32_t mapped, int k);
uint64_t mrtc_rice_count_bits_for_mapped(uint32_t mapped, int k);

static void put_s16_le(uint8_t *p, int16_t v) {
    uint16_t u = (uint16_t)v;
    p[0] = (uint8_t)(u & 0xffu);
    p[1] = (uint8_t)((u >> 8) & 0xffu);
}

static uint64_t sample_major_bits(const int16_t *i_data, const int16_t *q_data, int n, int codec, int k) {
    uint64_t bits = 0;
    int16_t prev_i = 0;
    int16_t prev_q = 0;
    for (int idx = 0; idx < n; ++idx) {
        int32_t pred_i = (codec == MRTC_CODEC_DELTA_RICE && idx > 0) ? prev_i : 0;
        int32_t pred_q = (codec == MRTC_CODEC_DELTA_RICE && idx > 0) ? prev_q : 0;
        int32_t residual_i = (int32_t)i_data[idx] - pred_i;
        int32_t residual_q = (int32_t)q_data[idx] - pred_q;
        bits += mrtc_rice_count_bits_for_mapped(mrtc_residual_to_mapped(residual_i), k);
        bits += mrtc_rice_count_bits_for_mapped(mrtc_residual_to_mapped(residual_q), k);
        prev_i = i_data[idx];
        prev_q = q_data[idx];
    }
    return bits;
}

static int select_k(const int16_t *i_data, const int16_t *q_data, int n, int codec, int rice_mode, int fixed_k, uint64_t *bits_out) {
    int best_k = fixed_k;
    uint64_t best_bits = UINT64_MAX;
    int k0 = (rice_mode == MRTC_RICE_FIXED_K) ? fixed_k : 0;
    int k1 = (rice_mode == MRTC_RICE_FIXED_K) ? fixed_k : 15;
    for (int k = k0; k <= k1; ++k) {
        uint64_t bits = sample_major_bits(i_data, q_data, n, codec, k);
        if (bits < best_bits) {
            best_bits = bits;
            best_k = k;
        }
    }
    *bits_out = best_bits;
    return best_k;
}

static int encode_sample_major(bit_writer_t *w, const int16_t *i_data, const int16_t *q_data, int n, int codec, int k) {
    int16_t prev_i = 0;
    int16_t prev_q = 0;
    for (int idx = 0; idx < n; ++idx) {
        int32_t pred_i = (codec == MRTC_CODEC_DELTA_RICE && idx > 0) ? prev_i : 0;
        int32_t pred_q = (codec == MRTC_CODEC_DELTA_RICE && idx > 0) ? prev_q : 0;
        uint32_t mapped_i = mrtc_residual_to_mapped((int32_t)i_data[idx] - pred_i);
        uint32_t mapped_q = mrtc_residual_to_mapped((int32_t)q_data[idx] - pred_q);
        if (mrtc_rice_encode_mapped(w, mapped_i, k) != 0) return -1;
        if (mrtc_rice_encode_mapped(w, mapped_q, k) != 0) return -1;
        prev_i = i_data[idx];
        prev_q = q_data[idx];
    }
    return 0;
}

static int write_raw_payload(uint8_t *out, int out_max, const int16_t *i_data, const int16_t *q_data, int n) {
    int need = n * 4;
    if (out_max < need) return -1;
    for (int s = 0; s < n; ++s) {
        put_s16_le(out + 4*s, i_data[s]);
        put_s16_le(out + 4*s + 2, q_data[s]);
    }
    return need;
}

int mrtc_rdtc_encode_block(
    const int16_t *i_data,
    const int16_t *q_data,
    int num_samples,
    const mrtc_block_header_t *header_in,
    int rice_mode,
    int fixed_k,
    uint8_t *out_bytes,
    int out_max_bytes,
    int *out_num_bytes,
    mrtc_block_header_t *header_out
) {
    if (!i_data || !q_data || !out_bytes || !out_num_bytes || !header_out) return -1;
    if (num_samples <= 0 || out_max_bytes < MRTC_HEADER_BYTES) return -2;
    mrtc_block_header_t h;
    if (header_in) h = *header_in; else mrtc_init_block_mode_a_header(&h);
    int codec = h.codec_mode;
    if (codec == MRTC_CODEC_RLE_RICE) return -20;
    if (codec != MRTC_CODEC_RAW && codec != MRTC_CODEC_ZERO_RICE && codec != MRTC_CODEC_DELTA_RICE) return -3;

    uint32_t raw_bytes = (uint32_t)(num_samples * 4);
    uint64_t est_bits = 0;
    int selected_k = fixed_k;
    if (codec != MRTC_CODEC_RAW) selected_k = select_k(i_data, q_data, num_samples, codec, rice_mode, fixed_k, &est_bits);
    uint32_t comp_payload_bytes = (uint32_t)((est_bits + 7u) / 8u);
    int use_raw = (codec == MRTC_CODEC_RAW) || ((uint32_t)MRTC_HEADER_BYTES + comp_payload_bytes >= raw_bytes);

    h.magic = MRTC_MAGIC;
    h.version = MRTC_VERSION;
    h.header_len = MRTC_HEADER_BYTES;
    h.sample_format = MRTC_SAMPLE_I16Q16;
    h.predictor_mode = (uint8_t)codec;
    h.rice_k = (uint8_t)selected_k;
    h.raw_bytes = raw_bytes;
    h.flags &= (uint16_t)~MRTC_FLAG_RAW_BYPASS;
    h.flags &= (uint16_t)~MRTC_FLAG_SAMPLE_MAJOR_IQ;
    if (rice_mode == MRTC_RICE_BLOCK_ADAPTIVE_K) h.flags |= MRTC_FLAG_BLOCK_ADAPTIVE_K;

    int payload_bytes = 0;
    uint32_t payload_bits = 0;
    if (use_raw) {
        h.flags |= MRTC_FLAG_RAW_BYPASS;
        h.codec_mode = MRTC_CODEC_RAW;
        payload_bytes = write_raw_payload(out_bytes + MRTC_HEADER_BYTES, out_max_bytes - MRTC_HEADER_BYTES, i_data, q_data, num_samples);
        if (payload_bytes < 0) return -4;
        payload_bits = (uint32_t)payload_bytes * 8u;
    } else {
        h.codec_mode = (uint8_t)codec;
        h.flags |= MRTC_FLAG_SAMPLE_MAJOR_IQ;
        h.payload_bytes = comp_payload_bytes;
        if (out_max_bytes < MRTC_HEADER_BYTES + (int)comp_payload_bytes) return -5;
        bit_writer_t w;
        mrtc_bw_init(&w, out_bytes + MRTC_HEADER_BYTES, out_max_bytes - MRTC_HEADER_BYTES);
        if (encode_sample_major(&w, i_data, q_data, num_samples, codec, selected_k) != 0) return -6;
        payload_bits = (uint32_t)w.bit_pos;
        payload_bytes = (int)((payload_bits + 7u) / 8u);
    }

    h.payload_bytes = (uint32_t)payload_bytes;
    h.payload_bits = payload_bits;
    h.crc32 = 0;
    if (mrtc_pack_header_le(&h, out_bytes) != 0) return -8;
    *out_num_bytes = MRTC_HEADER_BYTES + payload_bytes;
    *header_out = h;
    return 0;
}

int mrtc_rdtc_encode_decode_check(
    const int16_t *i_data,
    const int16_t *q_data,
    int num_samples,
    int codec_mode,
    int rice_mode,
    int fixed_k
) {
    uint8_t *buf = (uint8_t*)malloc((size_t)(MRTC_HEADER_BYTES + num_samples * 8 + 8192));
    int16_t *di = (int16_t*)malloc((size_t)num_samples * sizeof(int16_t));
    int16_t *dq = (int16_t*)malloc((size_t)num_samples * sizeof(int16_t));
    if (!buf || !di || !dq) return -1;
    mrtc_block_header_t h;
    mrtc_init_block_mode_a_header(&h);
    h.codec_mode = (uint8_t)codec_mode;
    int nbytes = 0, nsamp = 0;
    int rc = mrtc_rdtc_encode_block(i_data, q_data, num_samples, &h, rice_mode, fixed_k, buf, MRTC_HEADER_BYTES + num_samples * 8 + 8192, &nbytes, &h);
    if (rc == 0) rc = mrtc_rdtc_decode_block(buf, nbytes, di, dq, num_samples, &nsamp, &h);
    if (rc == 0 && nsamp == num_samples) {
        for (int i = 0; i < num_samples; ++i) {
            if (di[i] != i_data[i] || dq[i] != q_data[i]) { rc = -99; break; }
        }
    }
    free(buf); free(di); free(dq);
    return rc;
}
