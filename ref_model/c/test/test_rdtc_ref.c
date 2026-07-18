#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mrtc_rdtc_ref.h"

static void fill_zero_sparse(int16_t *i, int16_t *q, int n) {
    memset(i, 0, (size_t)n * sizeof(int16_t));
    memset(q, 0, (size_t)n * sizeof(int16_t));
    i[100] = 7; q[100] = -3; i[512] = -12; q[700] = 9;
}

static void fill_noise(int16_t *i, int16_t *q, int n) {
    uint32_t s = 1;
    for (int k = 0; k < n; ++k) {
        s = 1664525u * s + 1013904223u;
        i[k] = (int16_t)(s >> 16);
        s = 1664525u * s + 1013904223u;
        q[k] = (int16_t)(s >> 16);
    }
}

static void fill_delta(int16_t *i, int16_t *q, int n) {
    for (int k = 0; k < n; ++k) {
        i[k] = (int16_t)(k / 8);
        q[k] = (int16_t)(-k / 16);
    }
}

static int run_case(FILE *csv, const char *name, int codec, void (*fill)(int16_t*, int16_t*, int)) {
    const int n = MRTC_BLOCK_MODE_A_SAMPLES;
    int16_t *i = (int16_t*)malloc(n * sizeof(int16_t));
    int16_t *q = (int16_t*)malloc(n * sizeof(int16_t));
    uint8_t *buf = (uint8_t*)malloc(MRTC_HEADER_BYTES + n * 8 + 8192);
    int16_t *di = (int16_t*)malloc(n * sizeof(int16_t));
    int16_t *dq = (int16_t*)malloc(n * sizeof(int16_t));
    if (!i || !q || !buf || !di || !dq) return 2;
    fill(i, q, n);
    mrtc_block_header_t h, hout;
    mrtc_init_block_mode_a_header(&h);
    h.codec_mode = (uint8_t)codec;
    int nbytes = 0, nsamp = 0;
    int rc = mrtc_rdtc_encode_block(i, q, n, &h, MRTC_RICE_BLOCK_ADAPTIVE_K, 0, buf, MRTC_HEADER_BYTES + n * 8 + 8192, &nbytes, &hout);
    if (rc == 0) rc = mrtc_rdtc_decode_block(buf, nbytes, di, dq, n, &nsamp, &h);
    int equal = (rc == 0 && nsamp == n);
    for (int k = 0; equal && k < n; ++k) equal = (i[k] == di[k] && q[k] == dq[k]);
    if (csv) fprintf(csv, "%s,%d,%d,%u,%d,%d,%d,%d,%d\n", name, codec, n, hout.raw_bytes, nbytes, (hout.flags & MRTC_FLAG_RAW_BYPASS) ? 1 : 0, hout.rice_k, equal, equal);
    free(i); free(q); free(buf); free(di); free(dq);
    return equal ? 0 : 1;
}

int main(int argc, char **argv) {
    FILE *csv = NULL;
    if (argc > 1) csv = fopen(argv[1], "a");
    int rc = 0;
    rc |= run_case(csv, "zero_sparse", MRTC_CODEC_ZERO_RICE, fill_zero_sparse);
    rc |= run_case(csv, "random_noise_raw_bypass", MRTC_CODEC_ZERO_RICE, fill_noise);
    rc |= run_case(csv, "delta_smooth", MRTC_CODEC_DELTA_RICE, fill_delta);
    if (csv) fclose(csv);
    printf("test_rdtc_ref %s\n", rc ? "FAIL" : "PASS");
    return rc;
}
