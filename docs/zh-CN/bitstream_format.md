# 码流格式

[English](../en/bitstream_format.md) · [返回首页](../../README.md)

RDTC packet 由 64-byte little-endian header 和 payload 组成。本页给出公开 RDTC v1 的字节、bit 与长度合同；Rice 算法推导见[算法](algorithm.md)，端口握手见[接口](interfaces.md)。

## 原始输入 Block

公开 producer-side tensor 合同为 `S[spatial, doppler, range]`，当前 `spatial_idx` 解释为 `beam_id`。扁平化次序为 spatial/beam -> Doppler -> Range，Range 是最快变化维。RTL 接收扁平 sample 序列，不自行计算 tensor 坐标。

默认 block 为 `1 beam x 64 Doppler x 16 Range = 1024` 个 complex sample。I 与 Q 都是 signed 16-bit；每个 32-bit sample word 为 `{Q[15:0], I[15:0]}`，内存字节顺序依次为 `I[7:0]`、`I[15:8]`、`Q[7:0]`、`Q[15:8]`。

| AXIS128 lane | `tdata` bits | Sample |
|---|---|---|
| 0 | `[31:0]` | `sample[4n+0]` |
| 1 | `[63:32]` | `sample[4n+1]` |
| 2 | `[95:64]` | `sample[4n+2]` |
| 3 | `[127:96]` | `sample[4n+3]` |

因此一个 block 是 `4096` raw byte、`256` 个完全填充的 AXIS128 beat。按零起始编号，输入 `s_axis_raw_tlast` 在 beat 255 置位。

## Packet 组成

```text
packet = 64-byte header + variable-length payload
header-length packet beats = 4 + ceil(header.payload_bytes / 16)
physical packet beats = 4 + ceil(observed_payload_bytes / 16)
```

对 header-length packet，`header.payload_bytes` 就是物理 payload 长度；对 TLAST-length packet，header 字段可以为零，必须从 stream 统计 observed physical length。Encoder 先输出固定四拍 header，再输出 payload。`m_axis_comp_tlast` 标记物理 packet 的最后一拍；该拍的 `m_axis_comp_tuser[3:0]` 等于 `valid_byte_count - 1`，完整 16-byte 尾拍取值为 `15`。TUSER 只在 TLAST 拍用于解释尾拍字节数；主 AXIS128 合同没有导出 TKEEP。

<a id="header-layout"></a>

## 64-Byte Header

所有多字节整数均为 little-endian。Magic 数值是 `0x4D52`，实际 packet 前两个字节为 `52 4D`。

| Offset | Bytes | Field | 合同 |
|---|---:|---|---|
| `0x00-0x01` | 2 | `magic` | `0x4D52` |
| `0x02` | 1 | `version` | RDTC v1 为 `1` |
| `0x03` | 1 | `header_len` | 固定为 `64` |
| `0x04-0x05` | 2 | `frame_id` | Frame 身份 |
| `0x06-0x07` | 2 | `block_id` | Block 身份 |
| `0x08-0x09` | 2 | `tensor_spatial_size` | Tensor spatial/beam 维度 |
| `0x0A-0x0B` | 2 | `tensor_doppler_size` | Tensor Doppler 维度 |
| `0x0C-0x0D` | 2 | `tensor_range_size` | Tensor Range 维度 |
| `0x0E-0x0F` | 2 | `block_spatial_start` | Block spatial/beam 起点 |
| `0x10-0x11` | 2 | `block_doppler_start` | Block Doppler 起点 |
| `0x12-0x13` | 2 | `block_range_start` | Block Range 起点 |
| `0x14` | 1 | `block_spatial_len` | 默认 `1` |
| `0x15` | 1 | `block_doppler_len` | 默认 `64` |
| `0x16-0x17` | 2 | `block_range_len` | 默认 `16` |
| `0x18` | 1 | `sample_format` | I16Q16 为 `1` |
| `0x19` | 1 | `codec_mode` | RAW/ZERO_RICE/DELTA_RICE |
| `0x1A` | 1 | `predictor_mode` | Predictor 身份 |
| `0x1B` | 1 | `rice_k` | 选定的 Rice `k` |
| `0x1C-0x1D` | 2 | `flags` | 下表定义的 bit flags |
| `0x1E-0x1F` | 2 | `reserved0` | 保留；不得赋予新语义 |
| `0x20-0x23` | 4 | `raw_bytes` | 默认 block 为 `4096` |
| `0x24-0x27` | 4 | `payload_bytes` | Header-length packet 的 payload byte 数 |
| `0x28-0x2B` | 4 | `payload_bits` | Header-length Rice packet 的有效 bit 数 |
| `0x2C-0x2F` | 4 | `crc32` | 已定义字段；当前公开 profile 写 `0` |
| `0x30-0x3F` | 16 | `reserved` | 保留；不得赋予新语义 |

| Flag | Value | 含义 |
|---|---:|---|
| `MRTC_FLAG_RAW_BYPASS` | `0x0001` | Payload 是 RAW sample-major 字节流 |
| `MRTC_FLAG_LAST_BLOCK` | `0x0002` | 上层 block 序列的最后一项 |
| `MRTC_FLAG_CRC_ENABLE` | `0x0004` | CRC 字段 enable 定义；当前记录的公开 profile 未启用 |
| `MRTC_FLAG_BLOCK_ADAPTIVE_K` | `0x0008` | Block-adaptive `k` |
| `MRTC_FLAG_RLE_ENABLE` | `0x0010` | 已定义但不属于当前三模式公开 claim |
| `MRTC_FLAG_SAMPLE_MAJOR_IQ` | `0x0020` | Rice symbol 为 sample-major I/Q 顺序 |
| `MRTC_FLAG_PREFIX_K_FAST` | `0x0040` | Prefix-fast `k` 选择 |
| `MRTC_FLAG_STREAM_LENGTH_BY_TLAST` | `0x0080` | 物理 payload 长度来自 TLAST/TUSER |

CRC32 field 与 enable flag 已定义，但当前记录的公开 profile 均未启用 CRC 且写 `crc32=0`，公开 decoder 也不校验 CRC。本仓不据此声明 CRC 保护。Reserved bytes 当前由 encoder 写零，但 parser 不以非零值作为已定义扩展；文档不得给它们分配语义。

<a id="payload-order"></a>

## Payload 顺序

### RAW_BYPASS

互操作 RAW packet 同时设置 `codec_mode=RAW` 与 `MRTC_FLAG_RAW_BYPASS`。Payload 是 sample-major 字节流：

```text
I0 little-endian, Q0 little-endian,
I1 little-endian, Q1 little-endian, ...
```

### ZERO_RICE 与 DELTA_RICE

ZERO_RICE 的 residual 等于当前 sample 分量。DELTA_RICE 为 I 与 Q 维护独立 predictor state：首个 I/Q 都以零为预测值，后续 I 预测前一个 I，Q 预测前一个 Q。

Rice symbol 顺序固定为 `Rice(I0), Rice(Q0), Rice(I1), Rice(Q1), ...`。Signed residual `r` 映射为非负整数：`r >= 0` 时为 `2*r`，`r < 0` 时为 `-2*r-1`。一个 Rice word 由 `q` 个 `1`、一个 `0` terminator 和 `k`-bit remainder 组成；remainder 与 byte 内 bit 都按 MSB-first 写入。完整推导见[算法](algorithm.md#signed-mapping-与-rice-code)。

<a id="packet-length-contracts"></a>

## 两种长度合同

### Header-Length Packet

`payload_bytes` 与 `payload_bits` 在 header 中有效。这是当前 C reference encoder/decoder 和常规 self-describing packet 的合同。

### STREAM_LENGTH_BY_TLAST Packet

Bounded Direct-AXIS encoder 设置 `MRTC_FLAG_STREAM_LENGTH_BY_TLAST`，header 中 `payload_bytes/payload_bits` 可以为零。物理 packet 终点和尾拍字节数来自 TLAST/TUSER；RTL decoder 根据固定 block shape 判断需要恢复的 coded symbol 数量。

| Implementation | Header-length | TLAST-length Direct |
|---|---|---|
| C encoder | 生成 | 不生成 |
| C decoder | 支持 | **不支持** |
| RTL decoder | 支持 | 支持 |
| Bounded Direct encoder | 不使用 | 生成 |

当前 C header 未定义 RTL 的 `0x0040` 与 `0x0080` flags，C decoder 直接使用 header `payload_bits` 初始化 bit reader，因此不能直接消费 payload length 为零的 bounded Direct packet。该差异是公开功能缺口，不在本次文档分支修改；未来需要独立的 C codec 功能变更与测试。

## 固定 Packet 与链路占用示例

| Case | Raw | Payload | Packet | AXIS128 beats | Final valid bytes | Packet ratio | Idealized link occupancy |
|---|---:|---:|---:|---:|---:|---:|---:|
| RAW | 4096 B | 4096 B | 4160 B | 260 | 16 | `4096/4160` | `260/256 = 101.5625%` |
| DELTA `delta_smooth` | 4096 B | 2365 bit / 296 B | 360 B | 23 | 8 | `4096/360` | `23/256 = 8.984375%` |
| ZERO `smoke_zero_sparse` | 4096 B | 2158 bit / 270 B | 334 B | 21 | 14 | `4096/334` | `21/256 = 8.203125%` |

`packet beat footprint = ceil(packet_bytes/16)`。表中的 idealized link occupancy 是 `packet_beats/256`，只比较 packet beat 数和 256-cycle 输入间隔；它不是测得的 duty cycle。

Measured TVALID duty 应定义为 `count(TVALID)/measurement_cycles`，accepted-beat duty 应定义为 `count(TVALID && TREADY)/measurement_cycles`。本页没有发布新的 trace 测量值。低 packet beat footprint 也不能证明内部 block service 小于输入到达间隔；bounded Direct 的既有 evidence 仍记录约 `277-cycle` packet service 大于 `256-cycle` zero-gap block arrival。
