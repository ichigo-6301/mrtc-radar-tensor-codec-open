#include "mrtc_dpi.h"
#include "mrtc_rdtc_ref.h"

static int16_t *short_array_ptr(const svOpenArrayHandle h) {
    return (int16_t *)svGetArrayPtr(h);
}

static const int16_t *short_array_cptr(const svOpenArrayHandle h) {
    return (const int16_t *)svGetArrayPtr(h);
}

static uint8_t *byte_array_ptr(const svOpenArrayHandle h) {
    return (uint8_t *)svGetArrayPtr(h);
}

static const uint8_t *byte_array_cptr(const svOpenArrayHandle h) {
    return (const uint8_t *)svGetArrayPtr(h);
}

static int array_len_or_zero(const svOpenArrayHandle h) {
    return h ? svSize(h, 1) : 0;
}

int dpi_mrtc_rdtc_encode_block(
    const svOpenArrayHandle i_data,
    const svOpenArrayHandle q_data,
    int num_samples,
    int codec_mode,
    int rice_mode,
    int fixed_k,
    int frame_id,
    int block_id,
    int spatial_start,
    int doppler_start,
    int range_start,
    const svOpenArrayHandle out_bytes,
    int out_max_bytes,
    int *out_num_bytes,
    int *raw_bypass,
    int *selected_k
) {
    const int16_t *i_ptr = short_array_cptr(i_data);
    const int16_t *q_ptr = short_array_cptr(q_data);
    uint8_t *out_ptr = byte_array_ptr(out_bytes);
    int i_len = array_len_or_zero(i_data);
    int q_len = array_len_or_zero(q_data);
    int out_len = array_len_or_zero(out_bytes);

    if (!i_ptr || !q_ptr || !out_ptr || !out_num_bytes) return -100;
    if (num_samples < 0 || num_samples > i_len || num_samples > q_len) return -101;
    if (out_max_bytes < 0 || out_max_bytes > out_len) return -102;

    mrtc_block_header_t h, hout;
    mrtc_init_block_mode_a_header(&h);
    h.codec_mode = (uint8_t)codec_mode;
    h.frame_id = (uint16_t)frame_id;
    h.block_id = (uint16_t)block_id;
    h.block_spatial_start = (uint16_t)spatial_start;
    h.block_doppler_start = (uint16_t)doppler_start;
    h.block_range_start = (uint16_t)range_start;
    int rc = mrtc_rdtc_encode_block(i_ptr, q_ptr, num_samples,
        &h, rice_mode, fixed_k, out_ptr, out_max_bytes, out_num_bytes, &hout);
    if (raw_bypass) *raw_bypass = (hout.flags & MRTC_FLAG_RAW_BYPASS) ? 1 : 0;
    if (selected_k) *selected_k = hout.rice_k;
    return rc;
}

int dpi_mrtc_rdtc_decode_block(
    const svOpenArrayHandle in_bytes,
    int in_num_bytes,
    const svOpenArrayHandle out_i,
    const svOpenArrayHandle out_q,
    int max_samples,
    int *out_num_samples
) {
    const uint8_t *in_ptr = byte_array_cptr(in_bytes);
    int16_t *out_i_ptr = short_array_ptr(out_i);
    int16_t *out_q_ptr = short_array_ptr(out_q);
    int in_len = array_len_or_zero(in_bytes);
    int out_i_len = array_len_or_zero(out_i);
    int out_q_len = array_len_or_zero(out_q);

    if (!in_ptr || !out_i_ptr || !out_q_ptr || !out_num_samples) return -110;
    if (in_num_bytes < 0 || in_num_bytes > in_len) return -111;
    if (max_samples < 0 || max_samples > out_i_len || max_samples > out_q_len) return -112;

    mrtc_block_header_t h;
    return mrtc_rdtc_decode_block(in_ptr, in_num_bytes, out_i_ptr, out_q_ptr,
        max_samples, out_num_samples, &h);
}
