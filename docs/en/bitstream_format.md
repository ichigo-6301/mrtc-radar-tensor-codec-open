# Bitstream Format

[中文](../zh-CN/bitstream_format.md) · [Back to README](../../README.en.md)

An RDTC packet contains a 64-byte little-endian header followed by a payload. This page defines the public RDTC v1 byte, bit, and length contracts. See [Algorithm](algorithm.md) for the Rice derivation and [Interfaces](interfaces.md) for port handshakes.

## Raw Input Block

The public producer-side tensor contract is `S[spatial, doppler, range]`, with `spatial_idx` currently interpreted as `beam_id`. Flattening proceeds spatial/beam -> Doppler -> Range, with Range changing fastest. RTL consumes the resulting flat sample sequence; it does not derive tensor coordinates.

The default block is `1 beam x 64 Doppler x 16 Range = 1024` complex samples. I and Q are signed 16-bit components. Each 32-bit sample word is `{Q[15:0], I[15:0]}`, and its memory bytes are `I[7:0]`, `I[15:8]`, `Q[7:0]`, and `Q[15:8]`.

| AXIS128 lane | `tdata` bits | Sample |
|---|---|---|
| 0 | `[31:0]` | `sample[4n+0]` |
| 1 | `[63:32]` | `sample[4n+1]` |
| 2 | `[95:64]` | `sample[4n+2]` |
| 3 | `[127:96]` | `sample[4n+3]` |

One block is therefore `4096` raw bytes and `256` fully populated AXIS128 beats. With zero-based indexing, input `s_axis_raw_tlast` is asserted on beat 255.

## Packet Composition

```text
packet = 64-byte header + variable-length payload
header-length packet beats = 4 + ceil(header.payload_bytes / 16)
physical packet beats = 4 + ceil(observed_payload_bytes / 16)
```

For a header-length packet, `header.payload_bytes` is the physical payload length. For a TLAST-length packet, the observed physical length must be counted from the stream because the header field may be zero. The Encoder emits the fixed four-beat header before the payload. `m_axis_comp_tlast` marks the physical packet's final beat. On that beat, `m_axis_comp_tuser[3:0]` equals `valid_byte_count - 1`; a full 16-byte final beat carries `15`. TUSER is interpreted for the byte count on TLAST. The main AXIS128 contract does not export TKEEP.

<a id="header-layout"></a>

## 64-Byte Header

All multi-byte integers are little-endian. The magic value is `0x4D52`, serialized as packet bytes `52 4D`.

| Offset | Bytes | Field | Contract |
|---|---:|---|---|
| `0x00-0x01` | 2 | `magic` | `0x4D52` |
| `0x02` | 1 | `version` | `1` for RDTC v1 |
| `0x03` | 1 | `header_len` | fixed at `64` |
| `0x04-0x05` | 2 | `frame_id` | Frame identity |
| `0x06-0x07` | 2 | `block_id` | Block identity |
| `0x08-0x09` | 2 | `tensor_spatial_size` | tensor spatial/beam dimension |
| `0x0A-0x0B` | 2 | `tensor_doppler_size` | tensor Doppler dimension |
| `0x0C-0x0D` | 2 | `tensor_range_size` | tensor Range dimension |
| `0x0E-0x0F` | 2 | `block_spatial_start` | block spatial/beam origin |
| `0x10-0x11` | 2 | `block_doppler_start` | block Doppler origin |
| `0x12-0x13` | 2 | `block_range_start` | block Range origin |
| `0x14` | 1 | `block_spatial_len` | default `1` |
| `0x15` | 1 | `block_doppler_len` | default `64` |
| `0x16-0x17` | 2 | `block_range_len` | default `16` |
| `0x18` | 1 | `sample_format` | `1` for I16Q16 |
| `0x19` | 1 | `codec_mode` | RAW/ZERO_RICE/DELTA_RICE |
| `0x1A` | 1 | `predictor_mode` | predictor identity |
| `0x1B` | 1 | `rice_k` | selected Rice `k` |
| `0x1C-0x1D` | 2 | `flags` | bit flags defined below |
| `0x1E-0x1F` | 2 | `reserved0` | reserved; no new semantics may be assigned |
| `0x20-0x23` | 4 | `raw_bytes` | `4096` for the default block |
| `0x24-0x27` | 4 | `payload_bytes` | payload bytes for a header-length packet |
| `0x28-0x2B` | 4 | `payload_bits` | valid Rice bits for a header-length packet |
| `0x2C-0x2F` | 4 | `crc32` | defined field; zero in current public profiles |
| `0x30-0x3F` | 16 | `reserved` | reserved; no new semantics may be assigned |

| Flag | Value | Meaning |
|---|---:|---|
| `MRTC_FLAG_RAW_BYPASS` | `0x0001` | payload is a RAW sample-major byte stream |
| `MRTC_FLAG_LAST_BLOCK` | `0x0002` | final item in an upper-layer block sequence |
| `MRTC_FLAG_CRC_ENABLE` | `0x0004` | CRC-field enable definition; not enabled by the recorded public profiles |
| `MRTC_FLAG_BLOCK_ADAPTIVE_K` | `0x0008` | block-adaptive `k` |
| `MRTC_FLAG_RLE_ENABLE` | `0x0010` | defined but outside the current three-mode public claim |
| `MRTC_FLAG_SAMPLE_MAJOR_IQ` | `0x0020` | Rice symbols use sample-major I/Q order |
| `MRTC_FLAG_PREFIX_K_FAST` | `0x0040` | prefix-fast `k` selection |
| `MRTC_FLAG_STREAM_LENGTH_BY_TLAST` | `0x0080` | physical payload length comes from TLAST/TUSER |

The CRC32 field and enable flag are defined, but the recorded public profiles leave CRC disabled and write `crc32=0`; published decoders do not validate CRC. No CRC-protection claim is made. Encoders currently write reserved bytes as zero, but parsers do not treat nonzero values as a documented extension. Reserved bytes must not receive new semantics in documentation.

<a id="payload-order"></a>

## Payload Order

### RAW_BYPASS

An interoperable RAW packet sets both `codec_mode=RAW` and `MRTC_FLAG_RAW_BYPASS`. Its payload is a sample-major byte stream:

```text
I0 little-endian, Q0 little-endian,
I1 little-endian, Q1 little-endian, ...
```

### ZERO_RICE And DELTA_RICE

For ZERO_RICE, the residual equals the current sample component. DELTA_RICE keeps independent predictor state for I and Q: the first I/Q pair predicts zero, later I values predict from the preceding I, and later Q values predict from the preceding Q.

Rice symbols are ordered `Rice(I0), Rice(Q0), Rice(I1), Rice(Q1), ...`. A signed residual `r` maps to `2*r` when `r >= 0` and `-2*r-1` otherwise. One Rice word contains `q` one-bits, one zero terminator, and a `k`-bit remainder. Remainders and bits within each byte are written MSB first. See [Algorithm](algorithm.md#signed-mapping-and-rice-coding) for the derivation.

<a id="packet-length-contracts"></a>

## Two Length Contracts

### Header-Length Packet

`payload_bytes` and `payload_bits` are valid in the header. This is the current C reference encoder/decoder contract and the conventional self-describing packet form.

### STREAM_LENGTH_BY_TLAST Packet

The bounded Direct-AXIS encoder sets `MRTC_FLAG_STREAM_LENGTH_BY_TLAST`, and header `payload_bytes/payload_bits` may be zero. Physical packet extent and final-byte count come from TLAST/TUSER. The RTL decoder uses the fixed block shape to determine how many coded symbols must be reconstructed.

| Implementation | Header-length | TLAST-length Direct |
|---|---|---|
| C encoder | emits | does not emit |
| C decoder | supported | **not supported** |
| RTL decoder | supported | supported |
| Bounded Direct encoder | not used | emits |

The current C header does not define the RTL `0x0040` and `0x0080` flags, and the C decoder initializes its bit reader directly from header `payload_bits`. It therefore cannot directly consume a bounded Direct packet whose header payload length is zero. This is a published functional gap, not changed on this documentation branch; support requires a separate C-code change and test update.

## Fixed Packet And Link-Occupancy Examples

| Case | Raw | Payload | Packet | AXIS128 beats | Final valid bytes | Packet ratio | Idealized link occupancy |
|---|---:|---:|---:|---:|---:|---:|---:|
| RAW | 4096 B | 4096 B | 4160 B | 260 | 16 | `4096/4160` | `260/256 = 101.5625%` |
| DELTA `delta_smooth` | 4096 B | 2365 bits / 296 B | 360 B | 23 | 8 | `4096/360` | `23/256 = 8.984375%` |
| ZERO `smoke_zero_sparse` | 4096 B | 2158 bits / 270 B | 334 B | 21 | 14 | `4096/334` | `21/256 = 8.203125%` |

`packet beat footprint = ceil(packet_bytes/16)`. The idealized link occupancy in the table is `packet_beats/256`, comparing packet beats with the 256-cycle input interval. It is not a measured duty cycle.

Measured TVALID duty would be `count(TVALID)/measurement_cycles`; accepted-beat duty would be `count(TVALID && TREADY)/measurement_cycles`. This page publishes no new trace measurement. A low packet beat footprint also does not prove that internal block service is below the input-arrival interval: existing bounded Direct evidence still records approximately `277` packet-service cycles versus a `256`-cycle zero-gap block arrival.
