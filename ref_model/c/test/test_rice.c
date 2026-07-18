#include <stdint.h>
#include <stdio.h>

uint32_t mrtc_residual_to_mapped(int32_t r);
int32_t mrtc_mapped_to_residual(uint32_t m);
uint64_t mrtc_rice_count_bits_for_mapped(uint32_t mapped, int k);

int main(void) {
    for (int r = -1024; r <= 1024; ++r) {
        uint32_t m = mrtc_residual_to_mapped(r);
        int32_t rr = mrtc_mapped_to_residual(m);
        if (rr != r) {
            fprintf(stderr, "map mismatch %d -> %u -> %d\n", r, m, rr);
            return 1;
        }
    }
    if (mrtc_rice_count_bits_for_mapped(0, 0) != 1) return 2;
    if (mrtc_rice_count_bits_for_mapped(5, 2) != 4) return 3;
    printf("test_rice PASS\n");
    return 0;
}
