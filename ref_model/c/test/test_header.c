#include <stdio.h>
#include <string.h>
#include "mrtc_block_format.h"

int main(void) {
    uint8_t bytes[MRTC_HEADER_BYTES];
    mrtc_block_header_t h, u;
    mrtc_init_block_mode_a_header(&h);
    h.frame_id = 0x1234;
    h.block_id = 0x5678;
    h.payload_bytes = 0x11223344u;
    h.payload_bits = 0x01020304u;
    if (mrtc_pack_header_le(&h, bytes) != 0) return 1;
    if (bytes[0] != 0x52 || bytes[1] != 0x4d) return 2;
    if (bytes[4] != 0x34 || bytes[5] != 0x12) return 3;
    if (mrtc_unpack_header_le(bytes, &u) != 0) return 4;
    if (u.frame_id != h.frame_id || u.block_id != h.block_id) return 5;
    if (u.payload_bytes != h.payload_bytes || u.payload_bits != h.payload_bits) return 6;
    bytes[0] = 0;
    if (mrtc_unpack_header_le(bytes, &u) == 0) return 7;
    printf("test_header PASS\n");
    return 0;
}
