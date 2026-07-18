#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mrtc_rdtc_ref.h"

#define MAX_SAMPLES 1024
#define MAX_BYTES   8192
#define MAX_FIELDS  16

static int file_exists(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

static void join_path(char *out, size_t out_sz, const char *a, const char *b, const char *c) {
    snprintf(out, out_sz, "%s/%s/%s", a, b, c);
}

static int read_samples(const char *path, int16_t *i_data, int16_t *q_data, int max_samples) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    int n = 0;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -2; }
    while (fgets(line, sizeof(line), f)) {
        int idx = 0, iv = 0, qv = 0;
        if (sscanf(line, "%d,%d,%d", &idx, &iv, &qv) == 3) {
            if (n >= max_samples) { fclose(f); return -3; }
            (void)idx;
            i_data[n] = (int16_t)iv;
            q_data[n] = (int16_t)qv;
            n++;
        }
    }
    fclose(f);
    return n;
}

static int read_hex_bytes(const char *path, uint8_t *bytes, int max_bytes) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[64];
    int n = 0;
    while (fgets(line, sizeof(line), f)) {
        unsigned v = 0;
        if (sscanf(line, "%x", &v) == 1) {
            if (n >= max_bytes) { fclose(f); return -2; }
            bytes[n++] = (uint8_t)(v & 0xffu);
        }
    }
    fclose(f);
    return n;
}

static int parse_header_csv(const char *path, mrtc_block_header_t *h) {
    uint8_t bytes[MRTC_HEADER_BYTES];
    mrtc_init_block_mode_a_header(h);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char names[1024];
    char values[1024];
    if (!fgets(names, sizeof(names), f) || !fgets(values, sizeof(values), f)) {
        fclose(f);
        return -2;
    }
    fclose(f);

    /* The generated CSV contains the same field order as the MATLAB header struct.
       Parsing through pack/unpack keeps the C header defaults sane if optional
       fields are absent in a future vector version. */
    unsigned magic=0, version=0, header_len=0, frame_id=0, block_id=0;
    unsigned ts=0, td=0, tr=0, bs=0, bd=0, br=0, bls=0, bld=0, blr=0;
    unsigned sample_format=0, codec=0, predictor=0, rice_k=0, flags=0, reserved0=0;
    unsigned raw_bytes=0, payload_bytes=0, payload_bits=0, crc32=0;
    int matched = sscanf(values,
        "%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u",
        &magic, &version, &header_len, &frame_id, &block_id, &ts, &td, &tr,
        &bs, &bd, &br, &bls, &bld, &blr, &sample_format, &codec, &predictor,
        &rice_k, &flags, &reserved0, &raw_bytes, &payload_bytes, &payload_bits, &crc32);
    if (matched < 24) return -3;
    h->magic = (uint16_t)magic;
    h->version = (uint8_t)version;
    h->header_len = (uint8_t)header_len;
    h->frame_id = (uint16_t)frame_id;
    h->block_id = (uint16_t)block_id;
    h->tensor_spatial_size = (uint16_t)ts;
    h->tensor_doppler_size = (uint16_t)td;
    h->tensor_range_size = (uint16_t)tr;
    h->block_spatial_start = (uint16_t)bs;
    h->block_doppler_start = (uint16_t)bd;
    h->block_range_start = (uint16_t)br;
    h->block_spatial_len = (uint8_t)bls;
    h->block_doppler_len = (uint8_t)bld;
    h->block_range_len = (uint16_t)blr;
    h->sample_format = (uint8_t)sample_format;
    h->codec_mode = (uint8_t)codec;
    h->predictor_mode = (uint8_t)predictor;
    h->rice_k = (uint8_t)rice_k;
    h->flags = (uint16_t)flags;
    h->reserved0 = (uint16_t)reserved0;
    h->raw_bytes = (uint32_t)raw_bytes;
    h->payload_bytes = (uint32_t)payload_bytes;
    h->payload_bits = (uint32_t)payload_bits;
    h->crc32 = (uint32_t)crc32;
    return mrtc_pack_header_le(h, bytes);
}

static int bytes_equal(const uint8_t *a, const uint8_t *b, int n) {
    for (int i = 0; i < n; ++i) if (a[i] != b[i]) return 0;
    return 1;
}

static int split_csv_fields(char *line, char **fields, int max_fields) {
    int n = 0;
    char *p = line;
    while (*p != '\0' && n < max_fields) {
        fields[n++] = p;
        while (*p != '\0' && *p != ',' && *p != '\r' && *p != '\n') {
            ++p;
        }
        if (*p == ',') {
            *p = '\0';
            ++p;
            continue;
        }
        if (*p == '\r' || *p == '\n') {
            *p = '\0';
            break;
        }
    }
    return n;
}

static void trim_quotes(char *s) {
    size_t n;
    if (!s) return;
    n = strlen(s);
    if (n >= 2 && s[0] == '"' && s[n - 1] == '"') {
        memmove(s, s + 1, n - 2);
        s[n - 2] = '\0';
    }
}

static int run_block_check(
    FILE *summary,
    const char *case_name,
    const char *block_name,
    int requested_codec,
    const char *sample_path,
    const char *hex_path,
    const char *header_path
) {
    int16_t i_data[MAX_SAMPLES], q_data[MAX_SAMPLES], di[MAX_SAMPLES], dq[MAX_SAMPLES];
    uint8_t matlab_bytes[MAX_BYTES], c_bytes[MAX_BYTES];
    mrtc_block_header_t h, hout, dh;
    int n = read_samples(sample_path, i_data, q_data, MAX_SAMPLES);
    int matlab_n = read_hex_bytes(hex_path, matlab_bytes, MAX_BYTES);
    int header_ok = parse_header_csv(header_path, &h) == 0;
    int c_n = 0, d_n = 0;
    int rice_mode = (h.flags & MRTC_FLAG_BLOCK_ADAPTIVE_K) ? MRTC_RICE_BLOCK_ADAPTIVE_K : MRTC_RICE_FIXED_K;
    h.codec_mode = (uint8_t)requested_codec;
    h.predictor_mode = (uint8_t)requested_codec;
    int rc = (n > 0 && matlab_n > 0 && header_ok) ? mrtc_rdtc_encode_block(i_data, q_data, n, &h, rice_mode, h.rice_k,
        c_bytes, MAX_BYTES, &c_n, &hout) : -1;
    int drc = (rc == 0) ? mrtc_rdtc_decode_block(c_bytes, c_n, di, dq, MAX_SAMPLES, &d_n, &dh) : -1;
    int comp_eq = (rc == 0 && c_n == matlab_n) ? bytes_equal(c_bytes, matlab_bytes, c_n) : 0;
    int header_eq = (rc == 0 && matlab_n >= MRTC_HEADER_BYTES) ? bytes_equal(c_bytes, matlab_bytes, MRTC_HEADER_BYTES) : 0;
    int payload_eq = (rc == 0 && c_n == matlab_n && c_n > MRTC_HEADER_BYTES) ?
        bytes_equal(c_bytes + MRTC_HEADER_BYTES, matlab_bytes + MRTC_HEADER_BYTES, c_n - MRTC_HEADER_BYTES) : 0;
    int dec_eq = 0;
    if (drc == 0 && d_n == n) {
        dec_eq = 1;
        for (int s = 0; s < n; ++s) {
            if (di[s] != i_data[s] || dq[s] != q_data[s]) { dec_eq = 0; break; }
        }
    }
    if (!comp_eq) {
        fprintf(stderr,
            "crosscheck mismatch %s/%s | matlab codec=%u pred=%u k=%u flags=%u payload_bytes=%u payload_bits=%u | c codec=%u pred=%u k=%u flags=%u payload_bytes=%u payload_bits=%u\n",
            case_name, block_name,
            (unsigned)h.codec_mode, (unsigned)h.predictor_mode, (unsigned)h.rice_k, (unsigned)h.flags,
            (unsigned)h.payload_bytes, (unsigned)h.payload_bits,
            (unsigned)hout.codec_mode, (unsigned)hout.predictor_mode, (unsigned)hout.rice_k, (unsigned)hout.flags,
            (unsigned)hout.payload_bytes, (unsigned)hout.payload_bits);
    }
    fprintf(summary, "%s,%s,%d,%d,%d,%d,%d,%d,%d\n", case_name, block_name, matlab_n, c_n,
        comp_eq, dec_eq, header_eq, payload_eq, comp_eq && dec_eq);
    return (comp_eq && dec_eq) ? 0 : 1;
}

int main(int argc, char **argv) {
    const char *vec_root = (argc > 1) ? argv[1] : "../../vectors/rdtc_v1";
    const char *out = (argc > 2) ? argv[2] : "../results/summary_matlab_c_crosscheck.csv";
    const char *cases[] = {
        "smoke_zero_sparse",
        "smoke_single_peak",
        "smoke_random_noise",
        "smoke_raw_bypass",
        "smoke_delta",
        "smoke_multi_block",
        "smoke_axis_packing"
    };
    FILE *summary = fopen(out, "w");
    if (!summary) return 1;
    fprintf(summary, "case_name,block_name,matlab_compressed_bytes,c_compressed_bytes,compressed_equal,decoded_equal,header_equal,payload_equal,pass_flag\n");

    int overall_rc = 0;

    for (size_t ci = 0; ci < sizeof(cases)/sizeof(cases[0]); ++ci) {
        char case_dir[512], block_summary_path[512];
        snprintf(case_dir, sizeof(case_dir), "%s/%s", vec_root, cases[ci]);
        join_path(block_summary_path, sizeof(block_summary_path), vec_root, cases[ci], "block_summary.csv");
        if (file_exists(block_summary_path)) {
            FILE *f = fopen(block_summary_path, "r");
            char line[2048];
            if (!f || !fgets(line, sizeof(line), f)) {
                if (f) fclose(f);
                fprintf(summary, "%s,manifest_missing,0,0,0,0,0,0,0\n", cases[ci]);
                overall_rc = 1;
                continue;
            }
            while (fgets(line, sizeof(line), f)) {
                char *fields[MAX_FIELDS];
                char work[2048];
                char sample_path[512], hex_path[512], header_path[512];
                snprintf(work, sizeof(work), "%s", line);
                int nf = split_csv_fields(work, fields, MAX_FIELDS);
                if (nf < 14) {
                    fprintf(summary, "%s,manifest_parse_error,0,0,0,0,0,0,0\n", cases[ci]);
                    overall_rc = 1;
                    continue;
                }
                trim_quotes(fields[1]);
                trim_quotes(fields[11]);
                trim_quotes(fields[12]);
                trim_quotes(fields[13]);
                snprintf(sample_path, sizeof(sample_path), "%s/%s", case_dir, fields[11]);
                snprintf(hex_path, sizeof(hex_path), "%s/%s", case_dir, fields[12]);
                snprintf(header_path, sizeof(header_path), "%s/%s", case_dir, fields[13]);
                if (!file_exists(sample_path) || !file_exists(hex_path) || !file_exists(header_path)) {
                    fprintf(summary, "%s,%s,0,0,0,0,0,0,0\n", cases[ci], fields[1]);
                    overall_rc = 1;
                    continue;
                }
                overall_rc |= run_block_check(summary, cases[ci], fields[1], atoi(fields[2]), sample_path, hex_path, header_path);
            }
            fclose(f);
            continue;
        }
        {
            char sample_path[512], hex_path[512], header_path[512];
            join_path(sample_path, sizeof(sample_path), vec_root, cases[ci], "input_samples.csv");
            join_path(hex_path, sizeof(hex_path), vec_root, cases[ci], "axis_comp_expected.hex");
            join_path(header_path, sizeof(header_path), vec_root, cases[ci], "block_headers.csv");
            if (!file_exists(sample_path) || !file_exists(hex_path) || !file_exists(header_path)) {
                fprintf(summary, "%s,legacy_missing,0,0,0,0,0,0,0\n", cases[ci]);
                overall_rc = 1;
                continue;
            }
            overall_rc |= run_block_check(summary, cases[ci], "legacy_block0", 0, sample_path, hex_path, header_path);
        }
    }
    fclose(summary);
    printf("test_cross_vectors: generated %s\n", out);
    return overall_rc;
}
