#include <stdint.h>
#include "mrtc_rdtc_ref.h"

typedef struct { const uint8_t *buf; int num_bits; int bit_pos; } bit_reader_t;
void mrtc_br_init(bit_reader_t *r, const uint8_t *buf, int num_bits);
int mrtc_rice_decode_mapped(bit_reader_t *r, int k, uint32_t *mapped);
int32_t mrtc_mapped_to_residual(uint32_t m);

static int16_t get_s16_le(const uint8_t *p) {
    uint16_t u = (uint16_t)p[0] | ((uint16_t)p[1] << 8);
    return (int16_t)u;
}

static int read_raw_payload(const uint8_t *p, int nbytes, int16_t *i_data, int16_t *q_data, int max_samples) {
    int n = nbytes / 4;
    if (n > max_samples) return -1;
    for (int s = 0; s < n; ++s) {
        i_data[s] = get_s16_le(p + 4*s);
        q_data[s] = get_s16_le(p + 4*s + 2);
    }
    return n;
}

static int decode_channel(bit_reader_t *r, int16_t *x, int n, int codec, int k) {
    for (int i = 0; i < n; ++i) {
        uint32_t mapped = 0;
        if (mrtc_rice_decode_mapped(r, k, &mapped) != 0) return -1;
        int32_t residual = mrtc_mapped_to_residual(mapped);
        int32_t pred = (codec == MRTC_CODEC_DELTA_RICE && i > 0) ? x[i-1] : 0;
        int32_t v = pred + residual;
        if (v < -32768 || v > 32767) return -2;
        x[i] = (int16_t)v;
    }
    return 0;
}

static int decode_sample_major(bit_reader_t *r, int16_t *out_i, int16_t *out_q, int n, int codec, int k) {
    int16_t prev_i = 0;
    int16_t prev_q = 0;
    for (int idx = 0; idx < n; ++idx) {
        uint32_t mapped_i = 0;
        uint32_t mapped_q = 0;
        int32_t residual_i;
        int32_t residual_q;
        int32_t pred_i = (codec == MRTC_CODEC_DELTA_RICE && idx > 0) ? prev_i : 0;
        int32_t pred_q = (codec == MRTC_CODEC_DELTA_RICE && idx > 0) ? prev_q : 0;
        int32_t value_i;
        int32_t value_q;

        if (mrtc_rice_decode_mapped(r, k, &mapped_i) != 0) return -1;
        if (mrtc_rice_decode_mapped(r, k, &mapped_q) != 0) return -1;

        residual_i = mrtc_mapped_to_residual(mapped_i);
        residual_q = mrtc_mapped_to_residual(mapped_q);
        value_i = pred_i + residual_i;
        value_q = pred_q + residual_q;
        if (value_i < -32768 || value_i > 32767) return -2;
        if (value_q < -32768 || value_q > 32767) return -2;

        out_i[idx] = (int16_t)value_i;
        out_q[idx] = (int16_t)value_q;
        prev_i = out_i[idx];
        prev_q = out_q[idx];
    }
    return 0;
}

int mrtc_rdtc_decode_block(
    const uint8_t *in_bytes,
    int in_num_bytes,
    int16_t *out_i,
    int16_t *out_q,
    int max_samples,
    int *out_num_samples,
    mrtc_block_header_t *header_out
) {
    if (!in_bytes || !out_i || !out_q || !out_num_samples || !header_out) return -1;
    if (in_num_bytes < MRTC_HEADER_BYTES) return -2;
    int rc = mrtc_unpack_header_le(in_bytes, header_out);
    if (rc != 0) return rc;
    if (header_out->sample_format != MRTC_SAMPLE_I16Q16) return -5;
    if (header_out->payload_bytes + MRTC_HEADER_BYTES > (uint32_t)in_num_bytes) return -6;
    int num_samples = (int)(header_out->raw_bytes / 4u);
    if (num_samples > max_samples) return -7;

    const uint8_t *payload = in_bytes + MRTC_HEADER_BYTES;
    if (header_out->flags & MRTC_FLAG_RAW_BYPASS) {
        int n = read_raw_payload(payload, (int)header_out->payload_bytes, out_i, out_q, max_samples);
        if (n < 0) return -8;
        *out_num_samples = n;
        return 0;
    }

    int codec = header_out->codec_mode;
    if (codec != MRTC_CODEC_ZERO_RICE && codec != MRTC_CODEC_DELTA_RICE) return -9;
    bit_reader_t br;
    mrtc_br_init(&br, payload, (int)header_out->payload_bits);
    if (header_out->flags & MRTC_FLAG_SAMPLE_MAJOR_IQ) {
        if (decode_sample_major(&br, out_i, out_q, num_samples, codec, header_out->rice_k) != 0) return -10;
    } else {
        if (decode_channel(&br, out_i, num_samples, codec, header_out->rice_k) != 0) return -10;
        if (decode_channel(&br, out_q, num_samples, codec, header_out->rice_k) != 0) return -11;
    }
    *out_num_samples = num_samples;
    return 0;
}
