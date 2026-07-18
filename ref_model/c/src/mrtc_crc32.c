#include <stdint.h>

uint32_t mrtc_crc32(const uint8_t *data, int nbytes) {
    uint32_t crc = 0xffffffffu;
    for (int i = 0; i < nbytes; ++i) {
        crc ^= data[i];
        for (int b = 0; b < 8; ++b) {
            uint32_t mask = (uint32_t)-(int)(crc & 1u);
            crc = (crc >> 1) ^ (0xedb88320u & mask);
        }
    }
    return ~crc;
}
