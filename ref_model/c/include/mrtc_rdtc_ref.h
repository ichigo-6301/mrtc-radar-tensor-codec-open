#ifndef MRTC_RDTC_REF_H
#define MRTC_RDTC_REF_H

#include <stdint.h>
#include "mrtc_block_format.h"

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
);

int mrtc_rdtc_decode_block(
    const uint8_t *in_bytes,
    int in_num_bytes,
    int16_t *out_i,
    int16_t *out_q,
    int max_samples,
    int *out_num_samples,
    mrtc_block_header_t *header_out
);

int mrtc_rdtc_encode_decode_check(
    const int16_t *i_data,
    const int16_t *q_data,
    int num_samples,
    int codec_mode,
    int rice_mode,
    int fixed_k
);

#endif
