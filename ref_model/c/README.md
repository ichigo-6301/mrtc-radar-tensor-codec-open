# RDTC C Reference Model

This directory contains the bit-exact C reference for the MRTC v1 RDTC lossless codec.

## Build

```sh
make
make test
```

The model is intentionally standalone C99. It is used by both standalone tests and the DPI-C simulation wrapper.

## Scope

- I16Q16 samples
- BLOCK_MODE_A, 1024 samples, 4096 raw bytes
- RAW_BYPASS
- ZERO_RICE
- DELTA_RICE
- RLE_RICE enum/stub
- Block-adaptive Rice k
- Little-endian 64-byte block header
