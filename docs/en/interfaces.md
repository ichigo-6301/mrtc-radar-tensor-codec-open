# Interfaces

RDTC v1 uses 128-bit AXI-Stream raw input and compressed output. Each beat contains four I16Q16 complex samples, and `tlast` marks a block boundary. Decoder compressed input and raw output use the same block-level `tlast` and final-beat byte-valid convention.

AXI4-Lite provides enable, soft reset, status clear, codec configuration, tensor metadata, counters, IRQ, and capability access. Signal semantics are defined by the published RTL and register map.
