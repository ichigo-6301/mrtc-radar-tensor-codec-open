# Stream Timing And Packet Service

[中文](../zh-CN/stream_timing.md) · [Back to README](../../README.en.md)

This page is for IP integration and digital-IC review. It separates AXIS protocol contracts, one fixed-regression observation, and historical throughput results. It adds no RTL behavior and does not turn one functional trace into a universal latency guarantee.

<a id="protocol-timing-contract"></a>

## Protocol Timing Contract

The bounded Direct-AXIS profile is a fixed dual-Engine wrapper: one input block contains `256` fully populated AXIS128 beats, descriptors rotate through Engine `0 -> 1`, and output selection follows job order while locking a packet through `TLAST`. The producer must reserve a descriptor and send data only in the wrapper's legal ready window.

![Bounded Direct-AXIS fixed functional stream trace](../assets/rdtc_stream_timing.svg)

The figure is generated deterministically from the published nominal/backpressure CSVs and shows real event ordering in one fixed ModelSim functional regression. Absolute cycles exist for auditability, not as a frequency, duty, or throughput claim. The contractual sequence is:

```text
input:       256 accepted AXIS128 beats; input TLAST on beat 255
prefix:      first 32 AXIS beats = 128 samples; selected_k becomes valid
ring:        legal capture writes, then ordered read requests after k
source II:   one ring/Bitpacker source request per cycle when legal
response:    fixed two-clock request-to-response contract
output:      4 header beats, then variable payload beats, then packet TLAST
backpressure: TVALID/TUSER/TDATA/TLAST hold while TREADY is low
```

`II=1` describes only the ring/Bitpacker source-request cadence: one 128-bit source word can be accepted per cycle when legal. It does not mean `m_axis_comp_tvalid` is `1` every cycle. Rice-token accumulation and output-word alignment create legal payload bubbles; a fail-stop halt is the explicit exception to ordinary AXIS hold behavior.

<a id="direct-engine0-trace"></a>

## Direct Engine 0 / Block 0 Trace

The public [Evidence](../../evidence/rdtc_v1_direct_stream_timing_trace.yaml) binds fixed commit `99dbd4b`, ModelSim 2020.4, testbench/filelist/runner identities, the [nominal CSV](../../evidence/data/rdtc_v1_direct_stream_timing_nominal.csv), and the [backpressure CSV](../../evidence/data/rdtc_v1_direct_stream_timing_backpressure.csv). Each curated trace spans cycles `6..603` in `598` rows. Full simulator logs and local paths remain unpublished; only their SHA256 identities are recorded.

The observation is specifically an **Engine 0 / Block 0 slice inside the dual-Engine wrapper**. It is not a `NUM_ENGINES=1` run and not isolated single-Engine system throughput. The nominal scenario keeps output `TREADY=1` to expose input fire, prefix completion, ring requests, four header beats, payload bubbles, and packet `TLAST`. The backpressure scenario applies fixed stalls to one header and one payload beat to check that packet data and boundaries hold.

| Engine 0 / Block 0 event | Fixed nominal observation | Meaning |
|---|---:|---|
| Accepted input beats | `6..261` | 256 beats; the first 32 occupy `6..37` |
| `prefix_done` / `selected_k_valid` | `47 / 48` | `k=0`, before the first ring read |
| Ring-read request / response | `56..311 / 58..313` | addresses `0..255`, request `II=1`, fixed two-cycle response |
| Accepted header | `50..53` | exactly four beats |
| First payload / packet TLAST | `86 / 326` | legal `TVALID` bubbles occur within the payload |

This is only the Engine 0 / Block 0 slice inside the dual-Engine wrapper. The complete two-block trace also verifies Block 1 assignment to Engine 1 and `20/72` packet beats. The testbench samples actual job identity when writing the output FIFO and follows the corresponding FIFO slot to the external AXIS read side, proving shared-output owner lock from P0 to P1. Final beats carry `16/15` valid bytes, giving `320/1151 B` packets; packet data/sideband match and decoder recovery is bit-exact.

<a id="backpressure-hold"></a>

## Backpressure Hold

On the normal non-fatal path, when `m_axis_comp_tvalid=1` and `m_axis_comp_tready=0`, the current `TDATA`, `TUSER`, `TLAST`, and packet owner remain stable until handshake. The fixed backpressure trace holds header beat 1 for cycles `51-52` and payload beat 4 for cycles `86-87`. The validator compares every held field through the following accepted beat and confirms that the accepted packet sequence is identical to nominal. Packet-internal bubbles are legal, but beats from different Engines must not interleave within one packet. Exhausted Direct output credit enters sticky fatal; that fail-stop case must not be presented as a successful ordinary-backpressure hold.

<a id="multi-engine-packet-service"></a>

## Multi-Engine Packet Service

![Fixed two-block Direct packet service](../assets/rdtc_multiengine_packet_timing.svg)

The fixed Direct trace contains exactly two real blocks: B0 is accepted by E0 and emitted as P0; B1 is accepted by E1 and emitted as P1. Shared AXIS keeps owner 0 throughout P0 and changes to owner 1 only after accepted TLAST. `TVALID` bubbles are legal inside a packet, while Engine beats may not interleave. The figure does not invent P2/P3 and does not treat this two-block protocol trace as the historical Multi-Engine scaling workload.

The historical fixed-commit 256-block workload uses the Stage16D2 single-Engine reference at `785 cycles/block`, while 2/4-Engine buffered-wrapper runs reach `397.52 / 197.41 cycles/block` with `98.7368% / 99.4115%` efficiency. The `785` value is an imported reference, not a wrapper `NUM_ENGINES=1` rerun. `8220 -> 785` is historical average packet-completion spacing, distinct from the `7693 -> 721` payload interval.

<a id="measurement-boundaries"></a>

## Measurement Boundaries

- `7693 -> 721 cycles`: the inclusive interval from first payload valid to accepted `TLAST` on the fixed `smoke_zero_sparse` workload; not whole-block latency, Multi-Engine throughput, or current Direct-AXIS sustained throughput.
- `785 / 397.52 / 197.41 cycles/block`: historical buffered-profile RTL simulation projections; not FPGA timing, board DDR, or network measurements.
- The current Direct profile observes approximately `277 cycles/block` of ordered packet service against a `256 cycles/block` zero-gap arrival interval. This remains a scheduler limitation, not a protocol guarantee or sustained-throughput PASS.
- The published trace is a finite ModelSim functional observation, not formal proof or coverage closure across all parameters, code lengths, and backpressure patterns.

Related normative pages: [Interfaces](interfaces.md) · [Bitstream Format](bitstream_format.md) · [Four-way shallow input ring](architecture.md#four-way-shallow-input-ring) · [Verification](verification.md)
