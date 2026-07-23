#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "mrtc_rdtc_ref.h"

static int write_iq_le(const char *path, const int16_t *i_data, const int16_t *q_data, int n) {
    FILE *file = fopen(path, "wb");
    if (!file) return -1;
    for (int index = 0; index < n; ++index) {
        uint16_t i_word = (uint16_t)i_data[index];
        uint16_t q_word = (uint16_t)q_data[index];
        uint8_t bytes[4] = {
            (uint8_t)(i_word & 0xffu), (uint8_t)(i_word >> 8),
            (uint8_t)(q_word & 0xffu), (uint8_t)(q_word >> 8),
        };
        if (fwrite(bytes, 1, sizeof(bytes), file) != sizeof(bytes)) {
            fclose(file);
            return -1;
        }
    }
    return fclose(file) == 0 ? 0 : -1;
}

static int write_bytes(const char *path, const uint8_t *data, int size) {
    FILE *file = fopen(path, "wb");
    if (!file) return -1;
    int ok = fwrite(data, 1, (size_t)size, file) == (size_t)size;
    return fclose(file) == 0 && ok ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s INPUT_IQ PACKET DECODED_IQ RESULT_CSV\n", argv[0]);
        return 2;
    }

    const int n = MRTC_BLOCK_MODE_A_SAMPLES;
    int16_t *i_data = (int16_t *)malloc((size_t)n * sizeof(int16_t));
    int16_t *q_data = (int16_t *)malloc((size_t)n * sizeof(int16_t));
    int16_t *decoded_i = (int16_t *)malloc((size_t)n * sizeof(int16_t));
    int16_t *decoded_q = (int16_t *)malloc((size_t)n * sizeof(int16_t));
    uint8_t *packet = (uint8_t *)malloc(MRTC_HEADER_BYTES + (size_t)n * 8u + 8192u);
    if (!i_data || !q_data || !decoded_i || !decoded_q || !packet) return 3;

    for (int index = 0; index < n; ++index) {
        i_data[index] = (int16_t)(index / 8);
        q_data[index] = (int16_t)(-index / 16);
    }

    mrtc_block_header_t header_in;
    mrtc_block_header_t header_out;
    mrtc_block_header_t decoded_header;
    mrtc_init_block_mode_a_header(&header_in);
    header_in.codec_mode = MRTC_CODEC_DELTA_RICE;
    header_in.frame_id = 7;
    header_in.block_id = 3;

    int packet_bytes = 0;
    int decoded_samples = 0;
    int rc = mrtc_rdtc_encode_block(
        i_data, q_data, n, &header_in, MRTC_RICE_BLOCK_ADAPTIVE_K, 0,
        packet, MRTC_HEADER_BYTES + n * 8 + 8192, &packet_bytes, &header_out
    );
    if (rc == 0) {
        rc = mrtc_rdtc_decode_block(
            packet, packet_bytes, decoded_i, decoded_q, n,
            &decoded_samples, &decoded_header
        );
    }

    int equal = rc == 0 && decoded_samples == n;
    for (int index = 0; equal && index < n; ++index) {
        equal = i_data[index] == decoded_i[index] && q_data[index] == decoded_q[index];
    }
    if (!equal) return 4;

    if (write_iq_le(argv[1], i_data, q_data, n) != 0 ||
        write_bytes(argv[2], packet, packet_bytes) != 0 ||
        write_iq_le(argv[3], decoded_i, decoded_q, n) != 0) {
        return 5;
    }

    FILE *csv = fopen(argv[4], "w");
    if (!csv) return 6;
    fprintf(csv, "case_name,codec_mode,num_samples,raw_bytes,packet_bytes,payload_bytes,payload_bits,raw_bypass,selected_k,bit_exact\n");
    fprintf(csv, "delta_smooth,DELTA_RICE,%d,%u,%d,%u,%u,%d,%u,PASS\n",
            n, header_out.raw_bytes, packet_bytes, header_out.payload_bytes,
            header_out.payload_bits,
            (header_out.flags & MRTC_FLAG_RAW_BYPASS) ? 1 : 0,
            header_out.rice_k);
    if (fclose(csv) != 0) return 7;

    printf("RDTC_CODEC_DEMO_PASS mode=DELTA_RICE samples=%d packet_bytes=%d selected_k=%u\n",
           n, packet_bytes, header_out.rice_k);
    free(i_data);
    free(q_data);
    free(decoded_i);
    free(decoded_q);
    free(packet);
    return 0;
}
