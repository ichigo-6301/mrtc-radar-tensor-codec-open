# Verification

[中文](../zh-CN/verification.md)

## Verification Chain

RDTC uses a layered convergence chain instead of relying on one RTL testbench:

| Layer | What it checks | Public maturity |
|---|---|---|
| MATLAB | Synthetic data, mode trends, vector generation, and lossless-reconstruction study | recorded synthetic study |
| C reference | Bit-exact oracle for packets, payloads, `selected_k`, and decoded samples | verified for published vectors |
| DPI-C / SystemVerilog | Block-by-block comparison between the reference model and RTL | verified finite regression |
| RTL protocol | AXI backpressure, `tkeep/tlast`, multiple blocks, loopback, and malformed streams | verified finite regression |
| Multi-Engine RTL | Distribution, independent packet buffers, packet-locked arbitration, and packet identity | verified finite workload |
| FPGA emulation simulation | Fixed-commit AXIS32 wrapper XSim with one active external input | `3/3` cases verified |
| Historical Zynq build layers | Trial-copy compatibility-RTL elaboration and SDK/ELF build | verified at those build layers only |

Published results apply to recorded source, configuration, and vector identities. They are not exhaustive formal proof, functional coverage closure, or proof of every parameter combination.

## Bit-Exact And Protocol Checks

Published legal vectors cover `RAW_BYPASS`, `ZERO_RICE`, `DELTA_RICE`, multiple blocks, AXI packing, encoder-decoder loopback, input gaps, randomized output backpressure, and malformed-stream negative conditions. Core acceptance conditions include:

- reconstructed I/Q samples exactly match the reference;
- `selected_k`, payload bit/byte counts, and compression choice agree;
- the final beat carries the correct `tkeep/tlast`;
- stalls do not change packet contents or boundaries;
- illegal headers, modes, or lengths produce explicit error status.

MATLAB supports vector generation and algorithm study. The authoritative public C cross-check entrypoint is:

```bash
make -C ref_model/c test
```

The shortest visible path for a first integration is:

```bash
make codec-demo
```

It compiles and invokes the same published C encoder and decoder, emits the fixed input, 360-byte packet, and decoded output under ignored `build/showcase_codec_demo/`, then checks all three SHA256 identities and `RDTC_CODEC_DEMO_PASS` against tracked JSON. This quickstart is a C-reference integration demonstration, not a replacement for RTL regression.

The point-cloud comparison on the MATLAB page is not PointCloud RTL and does not replace the executable C cross-check.

## Multi-Engine Regression

The historical fixed-commit 256-block prefix workload checks byte-exact payloads, `selected_k`, compression ratio, packet completeness, and absence of beat interleaving. One beam is defined as 256 blocks, and `beam/s` is calculated from the unrounded total cycles per beam. Performance is:

| Engines | Cycles/block | Scaling efficiency | Beam/s at assumed 200 MHz |
|---:|---:|---:|---:|
| 1 | 785 | baseline | - |
| 2 | 397.52 | 0.987368 | 1965.3022 |
| 4 | 197.41 | 0.994115 | 3957.4642 |

These values are RTL simulation projections with a simulated DDR model, not FPGA timing or measured board throughput. The current public adaptation has a separate two-Engine, two-block correctness smoke plus packet-buffer overlength fail-stop/reset recovery, two-slot simultaneous queue push/pop, one-slot turnover, completion-coincident status clearing, and `OUTPUT_IN_ORDER=1` fail-fast boundary tests; it does not recompute this matrix. Arbitration guarantees packet atomicity and no beat interleaving, while completion order is not guaranteed. Recorded evidence checks block identity but does not directly observe an actual reordered event. Metadata enables reconstruction by Frame/Block index; no software reorder-program PASS is claimed.

Public evidence summary and data: [Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [public CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## FPGA Emulation

**FPGA emulation verified.** At fixed source commit `43deb9f`, the Vivado 2018.3 AXIS32 wrapper passes `3/3` block-level XSim cases: ZERO_RICE, DELTA_RICE, and mixed two-block. Checks cover the real encoder path, decoder golden comparison, width conversion, variable-length packets, `tkeep/tlast`, input gaps, and output backpressure. The current published adaptation has a separate Icarus smoke and is not a new Vivado result.

The AXIS32 testbench drives only `s0`, so it is not evidence of dual-Engine scaling or concurrent dual-input behavior; the dual-Engine and Multi-Engine claims come from separate RTL regression. A historical Zynq-7000 trial copy completed `synth_design -rtl` with a Vivado-2018.3-compatible copied RTL set and completed its SDK/ELF build. The current public RTL retains `parameter string` and is not claimed to elaborate directly in Vivado 2018.3. No matching bitstream, board-console PASS, MCDMA/DDR/cache runtime, FPGA timing, or resource result is claimed.

Public evidence summary and data: [XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

![Zynq FPGA emulation evidence layers](../assets/zynq_emulation_path.svg)

## Public Check Entrypoints

```bash
make rdtc_v1_public_preflight_defconfig
make showconfig
make codec-demo
make -C ref_model/c test
make integration-smoke
make rtl-smoke
make multiengine-smoke
make fpga-wrapper-smoke
make showcase-assets-check
```

With a configured Questa/ModelSim environment:

```bash
make sim
make sim-full
```

Tool availability, a loadable script, or successful elaboration proves only that layer. It does not automatically promote a result to implementation, timing, bitstream, or board-workload PASS. See [Limitations](limitations.md) for all explicit nonclaims.
