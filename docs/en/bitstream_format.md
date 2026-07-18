# Bitstream Format

Each compressed block contains a 64-byte little-endian header followed by a payload. RAW_BYPASS preserves sample byte order. ZERO_RICE and DELTA_RICE use the mode and payload-bit count carried by the header.

The compressed stream emits the header first and the payload second. `tlast` marks the end of a block. A partial final beat uses `tuser[3:0]` as valid-byte-count minus one.
