# Stream Timing And Packet Service

[中文](../zh-CN/stream_timing.md) · [Back to README](../../README.en.md)

This page is for IP integration and digital-IC review. It separates AXIS protocol contracts, one fixed-regression observation, and historical throughput results. It adds no RTL behavior and does not turn one functional trace into a universal latency guarantee.

<a id="protocol-timing-contract"></a>

## Protocol Timing Contract

The bounded Direct-AXIS profile is a fixed dual-Engine wrapper: one input block contains `256` fully populated AXIS128 beats, descriptors rotate through Engine `0 -> 1`, and output selection follows job order while locking a packet through `TLAST`. The producer must reserve a descriptor and send data only in the wrapper's legal ready window.

![Bounded Direct-AXIS fixed functional stream trace](../assets/rdtc_stream_timing.svg)

The figure is generated deterministically from the published nominal/backpressure CSVs and shows real event ordering in one fixed ModelSim functional regression. Absolute cycles exist for auditability, not as a frequency, duty, or throughput claim. Read the protocol relationship first through the monospaced diagram below. It is a protocol schematic, not a measured waveform, and horizontal spacing is not a cycle scale.

```text
input fire   [beat 0 ... beat 31 ........ beat 255/TLAST]
prefix       < 32 beats = 128 samples > -> selected k
ring write   [accepted source words; a read-cleared slot can be reused]
ring read                         [req 0, 1, ... 255]  II=1
response                            [rsp 0, 1, ... 255]  +2 clocks
output       [H0 H1 H2 H3] ... [payload + legal bubbles] -> TLAST
stall        TVALID=1, TREADY=0 -> hold TDATA/TUSER/TLAST
```

<a id="ii1-vs-output-tvalid"></a>

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

The fixed nominal trace has the following event order. Every cycle shown comes from the public CSV; horizontal length is not to scale.

```text
event                 first / observed range              last
input B0 -> E0        beat 0 @6  =============== beat 255 @261
ring write            addr 0 @7  =============== addr 255 @262
prefix / k            32 input beats end @37
                      prefix_done @47 -> k=0 valid @48
header P0             H0 @50, H1 @51, H2 @52, H3 @53
ring read request     addr 0 @56 =============== addr 255 @311
ring read response    addr 0 @58 =============== addr 255 @313
payload P0            PL0 @86, PL1 @102, ... PL15/TLAST @326
```

```text
Fixed P0 nominal event sets
  ring request : every cycle 56..311, address = cycle - 56
  output header: cycles 50, 51, 52, 53
  output data  : cycle 86 + 16*n, n = 0..15
  packet end   : n = 15, cycle 326, TLAST = 1
```

The internal source therefore issues 256 consecutive requests in cycles `56..311`, while external P0 `TVALID` is asserted only for the 20 packet beats in the observed `50..326` window. This is an auditable asserted-cycle count, not a percentage or a general duty, latency, or throughput claim.

This is only the Engine 0 / Block 0 slice inside the dual-Engine wrapper. The complete two-block trace also verifies Block 1 assignment to Engine 1 and `20/72` packet beats. The testbench samples actual job identity when writing the output FIFO and follows the corresponding FIFO slot to the external AXIS read side, verifying shared-output owner lock from P0 to P1 in this two-block regression. Final beats carry `16/15` valid bytes, giving `320/1151 B` packets; packet data/sideband match and decoder recovery is bit-exact.

<a id="backpressure-hold"></a>

## Backpressure Hold

On the normal non-fatal path, when `m_axis_comp_tvalid=1` and `m_axis_comp_tready=0`, the current `TDATA`, `TUSER`, `TLAST`, and packet owner remain stable until handshake. The fixed backpressure trace holds header beat 1 for cycles `51-52` and packet beat 4 (the first payload beat, `PL0` below) for cycles `86-87`. The validator compares every held field through the following accepted beat and confirms that the accepted packet sequence is identical to nominal. Packet-internal bubbles are legal, but beats from different Engines must not interleave within one packet. Exhausted Direct output credit enters sticky fatal; that fail-stop case must not be presented as a successful ordinary-backpressure hold.

```text
header hold       cycle 50  51  52  53  54  55
  TVALID                  1   1   1   1   1   1
  TREADY                  1   0   0   1   1   1
  presented beat         H0  H1  H1  H1  H2  H3
  accepted                ^           ^   ^   ^

payload hold      cycle 86  87  88
  TVALID                  1   1   1
  TREADY                  0   0   1
  presented beat        PL0 PL0 PL0
  accepted                        ^
```

<a id="multi-engine-packet-service"></a>

## Multi-Engine Packet Service

![Fixed two-block Direct packet service](../assets/rdtc_multiengine_packet_timing.svg)

```text
Fixed two-block nominal trace (windows are not to scale)

input fire       B0 -> E0 [6........261]
                 B1 -> E1 [262.......517]

Engine 0 ring       req[0..255] [56........311]
Engine 1 ring                          req[0..255] [333....588]

shared AXIS      P0 / owner E0 [50........326]
                 20 accepted beats, TLAST @326
                                              |
                 P1 / owner E1                [327........603]
                 72 accepted beats,              TLAST @603

packet lock      owner changes only after accepted TLAST
```

The fixed Direct trace contains exactly two real blocks: B0 is accepted by E0 and emitted as P0; B1 is accepted by E1 and emitted as P1. Shared AXIS keeps owner 0 throughout P0 and changes to owner 1 only after accepted TLAST. `TVALID` bubbles are legal inside a packet, while Engine beats may not interleave. The figure does not invent P2/P3 and does not treat this two-block protocol trace as the historical Multi-Engine scaling workload.

The historical fixed-commit 256-block workload uses the Stage16D2 single-Engine reference at `785 cycles/block`, while 2/4-Engine buffered-wrapper runs reach `397.52 / 197.41 cycles/block` with `98.7368% / 99.4115%` efficiency. The `785` value is an imported reference, not a wrapper `NUM_ENGINES=1` rerun. `8220 -> 785` is historical average packet-completion spacing, distinct from the `7693 -> 721` payload interval.

<a id="measurement-boundaries"></a>

## Measurement Boundaries

- `7693 -> 721 cycles`: the inclusive interval from first payload valid to accepted `TLAST` on the fixed `smoke_zero_sparse` workload; not whole-block latency, Multi-Engine throughput, or current Direct-AXIS sustained throughput.
- `785 / 397.52 / 197.41 cycles/block`: historical buffered-profile RTL simulation projections; not FPGA timing, board DDR, or network measurements.
- The current Direct profile observes approximately `277 cycles/block` of ordered packet service against a `256 cycles/block` zero-gap arrival interval. This remains a scheduler limitation, not a protocol guarantee or sustained-throughput PASS.
- The published trace is a finite ModelSim functional observation, not formal proof or coverage closure across all parameters, code lengths, and backpressure patterns.

Related normative pages: [Interfaces](interfaces.md) · [Bitstream Format](bitstream_format.md) · [Four-way shallow input ring](architecture.md#four-way-shallow-input-ring) · [Verification](verification.md)
