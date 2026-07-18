#ifndef MRTC_DPI_H
#define MRTC_DPI_H

#include "svdpi.h"

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
);

int dpi_mrtc_rdtc_decode_block(
    const svOpenArrayHandle in_bytes,
    int in_num_bytes,
    const svOpenArrayHandle out_i,
    const svOpenArrayHandle out_q,
    int max_samples,
    int *out_num_samples
);

#endif
