# Verification

[中文](../zh-CN/verification.md)

## Verification Chain

RDTC uses a layered convergence chain instead of relying on one RTL testbench:

| Layer | What it checks | Public maturity |
|---|---|---|
| MATLAB | Synthetic data, mode trends, vector generation, and lossless-reconstruction study | recorded synthetic study |
| C reference | Bit-exact oracle for packets, payloads, `selected_k`, and decoded samples | verified for published vectors |
| DPI-C / SystemVerilog | Block-by-block comparison between the reference model and RTL | verified finite regression |
| RTL protocol | main-AXIS128 `tuser/tlast`, historical AXIS32 `tkeep/tlast`, backpressure, multiple blocks, loopback, and malformed streams | verified finite regression |
| Multi-Engine RTL | Distribution, independent packet buffers, packet-locked arbitration, and packet identity | verified finite workload |
| Bounded Direct-AXIS RTL | Two-block packet/selected-k equivalence, `II=1` ring reads, decoder loopback, and fatal boundaries | verified finite regression |
| FPGA emulation simulation | Fixed-commit AXIS32 wrapper XSim with one active external input | `3/3` cases verified |
| FPGA OOC implementation | Direct-AXIS dual Engine on `xc7z100ffg900-2` with structure and internal timing gates | fixed 200 MHz post-route point verified |
| Historical Zynq build layers | Trial-copy compatibility-RTL elaboration and SDK/ELF build | verified at those build layers only |

Published results apply to recorded source, configuration, and vector identities. They are not exhaustive formal proof, functional coverage closure, or proof of every parameter combination.

## Bit-Exact And Protocol Checks

Published legal vectors cover `RAW_BYPASS`, `ZERO_RICE`, `DELTA_RICE`, multiple blocks, AXI packing, encoder-decoder loopback, input gaps, randomized output backpressure, and malformed-stream negative conditions. Core acceptance conditions include:

- reconstructed I/Q samples exactly match the reference;
- `selected_k`, payload bit/byte counts, and compression choice agree;
- the main AXIS128 final beat carries the correct `tuser/tlast`; historical AXIS32 `tkeep/tlast` is checked separately;
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

## Bitpacker Pipeline A/B

Fresh ModelSim 2020.4 replay at the fixed historical commits runs Stage16C3 latency/loopback plus Stage16D2 lane4 latency, packet-compare, and loopback smoke. Both points use the same `smoke_zero_sparse` vector and the same latency monitor with Git blob `f994a0b4...`. The cycle metric is defined identically at both points:

```text
payload_stream_cycles = packet_last_cycle - payload_first_valid_cycle + 1
```

The baseline endpoints are `1169 -> 8861`, yielding `7693 cycles`; the optimized endpoints are `706 -> 1426`, yielding `721 cycles`. The gate also fixes `selected_k=0`, `payload_bits=2158`, `payload_bytes=270`, `packet_bytes=334`, zero input/output stalls, packet byte exactness, and decoder loopback. The public validator checks the input, manifest, expected packet, historical CSV, and fresh replay summary hashes.

Separate 256-block streams measure single-Engine steady-state throughput from adjacent packet-completion spacing: `8220 cycles/block` at Stage16C3 and `785 cycles/block` at Stage16D2. Public evidence binds the relevant `throughput_summary.csv`, common `smoke_zero_sparse` source vector/manifest, and repeated-stream generator by Git blob and SHA256; it also checks the public Multi-Engine CSV's 1-Engine row against the same `785` value. This metric is average packet-completion spacing, not one-block latency or the independently measured `smoke_zero_sparse` payload interval, and both revisions retain prefix-during-capture.

Public entrypoint: `make bitpacker-pipeline-ab-validate`. See the [Bitpacker A/B evidence](../../evidence/rdtc_v1_bitpacker_pipeline_ab.yaml). Future Direct stream-trace entrypoints are reserved as `make direct-stream-timing-modelsim` (capture) and `make direct-stream-timing-validate` (validate a published trace); the observation scope is defined in [Stream Timing](stream_timing.md#direct-engine0-trace).

## Multi-Engine Regression

The historical fixed-commit 256-block prefix workload uses the same-workload Stage16D2 single-Engine result as a reference and checks the 2/4-Engine wrapper runs for byte-exact payloads, `selected_k`, compression ratio, packet completeness, and absence of beat interleaving. One beam is defined as 256 blocks, and `beam/s` is calculated from the unrounded total cycles per beam. Performance is:

| Engines | Cycles/block | Scaling efficiency | Beam/s at assumed 200 MHz |
|---:|---:|---:|---:|
| 1 (Stage16D2 reference) | 785 | baseline | - |
| 2 | 397.52 | 98.7368% | 1965.3022 |
| 4 | 197.41 | 99.4115% | 3957.4642 |

These values are RTL simulation projections with a simulated DDR model, not FPGA timing or measured board throughput. The `785` row is an imported Stage16D2 reference, not a wrapper `NUM_ENGINES=1` rerun. The current public adaptation has a separate two-Engine, two-block correctness smoke plus packet-buffer overlength fail-stop/reset recovery, two-slot simultaneous queue push/pop, one-slot turnover, completion-coincident status clearing, and `OUTPUT_IN_ORDER=1` fail-fast boundary tests; it does not recompute this matrix. Arbitration guarantees packet atomicity and no beat interleaving, while completion order is not guaranteed. Recorded evidence checks block identity but does not directly observe an actual reordered event. Metadata enables reconstruction by Frame/Block index; no software reorder-program PASS is claimed.

Public evidence summary and data: [Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [public CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## Bounded Direct-AXIS Regression

The register-profile ModelSim regression sends two complete 1024-sample blocks through strict Engine 0/1 rotation. It checks packet data, `tuser/tlast`, selected `k=[0,2]`, 256 ordered ring-read requests and responses per Engine, two-cycle request-to-response latency, and one request per cycle. Packets contain 20 and 72 beats, and the Decoder reconstructs both blocks bit-exactly. The normalized trace SHA256 is recorded in the [Direct RTL evidence](../../evidence/rdtc_v1_bounded_direct_rtl.yaml).

Negative tests cover illegal codec/Rice mode, data before descriptor, early/late `tlast`, a 129-bit Rice word, way conflict, output-credit exhaustion, sticky fatal behavior, and reset recovery. The 64 RTL paths in the Direct filelist are independently checked byte for byte against the fixed evidence source by `make bounded-direct-rtl-identity-check`.

Long zero-gap testing intentionally records the scheduler boundary: ordered packet service is approximately 277 cycles, above the 256-cycle block arrival interval. The resulting `MRTC_ERR_SRAM_WAY_CONFLICT` is an expected architecture-limit failure, not a passing sustained-throughput test.

## FPGA Emulation

**FPGA emulation verified.** At fixed source commit `43deb9f`, the Vivado 2018.3 AXIS32 wrapper passes `3/3` block-level XSim cases: ZERO_RICE, DELTA_RICE, and mixed two-block. Checks cover the real encoder path, decoder golden comparison, width conversion, variable-length packets, `tkeep/tlast`, input gaps, and output backpressure. The current published adaptation has a separate Icarus smoke and is not a new Vivado result.

The AXIS32 testbench drives only `s0`, so it is not evidence of dual-Engine scaling or concurrent dual-input behavior. Its historical profile still makes no timing/resource claim. Separately, the bounded Direct-AXIS top completes Vivado 2022.2 OOC post-route on `xc7z100ffg900-2` at 200 MHz with setup/hold WNS `+0.001/+0.062 ns`, zero failing internal endpoints, `32,672 LUT / 18,519 FF / 0 BRAM`, and exactly `1024 x RAM32X1S` in eight ways. This does not establish a bitstream, board execution, board IO timing, Fmax, or sustained zero-gap throughput.

Public evidence summary and data: [XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Direct OOC evidence](../../evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

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
make bounded-direct-rtl-smoke
make bounded-direct-rtl-identity-check
make bitpacker-pipeline-ab-validate
make showcase-assets-check
```

With a configured Questa/ModelSim environment:

```bash
make sim
make sim-full
make bounded-direct-register-modelsim-regression
```

Tool availability, a loadable script, or successful elaboration proves only that layer. It does not automatically promote a result to implementation, timing, bitstream, or board-workload PASS. See [Limitations](limitations.md) for all explicit nonclaims.
