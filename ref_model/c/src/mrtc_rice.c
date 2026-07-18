#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t *buf;
    int max_bytes;
    int bit_pos;
} bit_writer_t;

typedef struct {
    const uint8_t *buf;
    int num_bits;
    int bit_pos;
} bit_reader_t;

uint32_t mrtc_residual_to_mapped(int32_t r) {
    return (r >= 0) ? (uint32_t)(2 * r) : (uint32_t)(-2 * r - 1);
}

int32_t mrtc_mapped_to_residual(uint32_t m) {
    return (m & 1u) ? -(int32_t)((m + 1u) >> 1) : (int32_t)(m >> 1);
}

void mrtc_bw_init(bit_writer_t *w, uint8_t *buf, int max_bytes) {
    w->buf = buf;
    w->max_bytes = max_bytes;
    w->bit_pos = 0;
    if (buf && max_bytes > 0) memset(buf, 0, (size_t)max_bytes);
}

int mrtc_bw_put_bit(bit_writer_t *w, int bit) {
    int byte_idx = w->bit_pos >> 3;
    int bit_idx = 7 - (w->bit_pos & 7);
    if (byte_idx >= w->max_bytes) return -1;
    if (bit) w->buf[byte_idx] |= (uint8_t)(1u << bit_idx);
    w->bit_pos++;
    return 0;
}

int mrtc_bw_put_bits(bit_writer_t *w, uint32_t v, int nbits) {
    for (int i = nbits - 1; i >= 0; --i) {
        if (mrtc_bw_put_bit(w, (v >> i) & 1u) != 0) return -1;
    }
    return 0;
}

int mrtc_rice_encode_mapped(bit_writer_t *w, uint32_t mapped, int k) {
    uint32_t q = mapped >> k;
    uint32_t r = (k == 0) ? 0u : (mapped & ((1u << k) - 1u));
    for (uint32_t i = 0; i < q; ++i) {
        if (mrtc_bw_put_bit(w, 1) != 0) return -1;
    }
    if (mrtc_bw_put_bit(w, 0) != 0) return -1;
    return mrtc_bw_put_bits(w, r, k);
}

void mrtc_br_init(bit_reader_t *r, const uint8_t *buf, int num_bits) {
    r->buf = buf;
    r->num_bits = num_bits;
    r->bit_pos = 0;
}

int mrtc_br_get_bit(bit_reader_t *r, int *bit) {
    if (r->bit_pos >= r->num_bits) return -1;
    int byte_idx = r->bit_pos >> 3;
    int bit_idx = 7 - (r->bit_pos & 7);
    *bit = (r->buf[byte_idx] >> bit_idx) & 1u;
    r->bit_pos++;
    return 0;
}

int mrtc_rice_decode_mapped(bit_reader_t *r, int k, uint32_t *mapped) {
    uint32_t q = 0;
    int bit = 0;
    while (1) {
        if (mrtc_br_get_bit(r, &bit) != 0) return -1;
        if (!bit) break;
        q++;
    }
    uint32_t rem = 0;
    for (int i = 0; i < k; ++i) {
        if (mrtc_br_get_bit(r, &bit) != 0) return -1;
        rem = (rem << 1) | (uint32_t)bit;
    }
    *mapped = (q << k) | rem;
    return 0;
}

uint64_t mrtc_rice_count_bits_for_mapped(uint32_t mapped, int k) {
    return (uint64_t)(mapped >> k) + 1u + (uint64_t)k;
}
