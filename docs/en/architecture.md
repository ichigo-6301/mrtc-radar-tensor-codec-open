# Architecture

The top level combines an AXI4-Lite register block with the RDTC codec top. The encoder unpacks samples, buffers blocks, generates headers, selects Rice parameters, and packs either coded data or raw bypass. The decoder parses headers, checks stream validity, decodes Rice payloads, and emits recovered samples.

The current memory structure retains its existing asynchronous-read timing semantics. Synchronous SRAM retiming is a separate implementation task and is not a functional or timing claim of this release.
