# 接口与集成入口

## 应该实例化哪个模块

| 使用场景 | Canonical top | Filelist | 公开检查 |
|---|---|---|---|
| 完整受控 IP，AXI4-Lite 配置 + AXIS128 codec | [`mrtc_top`](../../rtl/top/mrtc_top.sv) | [`rdtc_v1.f`](../../flows/manifests/rdtc_v1.f) | `make integration-smoke` |
| 单 Engine 编码器 + 解码器 | [`mrtc_rdtc_codec_top`](../../rtl/rdtc/mrtc_rdtc_codec_top.sv) | [`rdtc_v1.f`](../../flows/manifests/rdtc_v1.f) | `make integration-smoke`；实例参考 [`tb_rdtc_codec_top_smoke`](../../tb/sv/tb_rdtc_codec_top_smoke.sv) |
| Descriptor/DDR feeder 驱动的 N Engine 压缩 | [`mrtc_rdtc_ddr_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) | [`rdtc_v1_multiengine_smoke.f`](../../flows/manifests/rdtc_v1_multiengine_smoke.f) | `make multiengine-smoke` |
| 历史 Zynq trial 的 AXIS32 adaptation | [`mrtc_rdtc_axis32_wrapper`](../../rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) | [`rdtc_v1_fpga_wrapper_smoke.f`](../../flows/manifests/rdtc_v1_fpga_wrapper_smoke.f) | `make fpga-wrapper-smoke` |

新集成默认从 `mrtc_top` 开始；只需要 codec datapath、并由外部逻辑直接提供配置时使用 `mrtc_rdtc_codec_top`。Multi-Engine DDR wrapper 是吞吐扩展接口，并不替代带 AXI4-Lite 控制面的 `mrtc_top`。

## 固定数据合同

| 项目 | RDTC v1 合同 |
|---|---|
| 原始 sample | I16Q16 complex，I/Q 各为 signed 16-bit |
| Block | 1024 complex samples，4096 raw bytes |
| 主 datapath | 128-bit AXI-Stream，每拍 4 个 I16Q16 sample |
| Packet | 64-byte little-endian header + variable-length payload |
| Codec mode | `RAW_BYPASS`、`ZERO_RICE`、`DELTA_RICE` |
| Tail bytes | `tuser[3:0] = valid_byte_count - 1` |

## Clock 与 Reset

公开 RTL 使用单一 `clk` 和低有效同步 datapath reset `rst_n`。`i_clear_status` 只清除 sticky status/counter，不替代 reset，也不应被用来中断正在握手的 AXI-Stream transaction。所有 `tvalid/tready` 传输都在 `clk` 上升沿完成。

## AXI-Stream 编码 transaction

1. 在 block 第一个 beat 前锁定 codec、Rice 和 tensor metadata 配置。
2. 仅当 `s_axis_raw_tvalid && s_axis_raw_tready` 时提交输入 beat。
3. 第 256 个 AXIS128 beat 置 `s_axis_raw_tlast=1`；该 beat 仍包含 4 个有效 I16Q16 sample。
4. Encoder 先发送 64-byte header，再发送 payload。
5. 最后一个输出 beat 置 `m_axis_comp_tlast=1`，`m_axis_comp_tuser[3:0]` 给出有效字节数减一。
6. 下游可以任意拉低 `m_axis_comp_tready`；packet 内容和边界必须保持稳定。

Decoder 在 `s_axis_comp_*` 接收同一 packet 合同，并在 `m_axis_raw_*` 恢复 1024 个 I16Q16 sample。固定示例可运行 `make codec-demo`，其输入、packet 和解码输出 SHA256 记录在 [codec demo evidence](../../evidence/rdtc_v1_codec_demo.yaml)。

## 关键参数

| Module | Parameter | 含义 |
|---|---|---|
| `mrtc_top` | `AXIS_DATA_W=128` | 公开主数据宽度；当前 RDTC v1 合同固定为 128 bit |
| `mrtc_top` | `AXIL_ADDR_W=12`, `AXIL_DATA_W=32` | 控制面地址与数据宽度 |
| codec/engine | `MRTC_K_POLICY_ARCH` | full-adaptive 或 prefix-fast `k` 选择架构 |
| codec/engine | `PREFIX_SAMPLES=256` | prefix-fast 的公开默认观察长度 |
| DDR wrapper | `NUM_ENGINES=2` | Engine 数量；公开回归覆盖 2/4 Engine 历史矩阵与 2 Engine adaptation smoke |
| DDR wrapper | `OUTPUT_IN_ORDER=0` | 唯一支持值；设为 `1` 会 fail-fast |

## Multi-Engine descriptor 与输出顺序

DDR wrapper 通过 `s_desc_*` 接收 raw address、Frame/Block ID、Range 起点、codec mode 和 tensor shape。每个 Engine 拥有独立 feeder、codec 和 packet buffer；输出 arbiter 一旦选中 packet，就保持该 Engine 直到 `tlast`，因此 packet 内不会 beat interleaving。

不同 block 的完成顺序不保证。Header 中的 Frame/Block metadata 提供 indexed software reconstruction 所需身份，但本仓库不声明软件 reorder 程序 PASS。`OUTPUT_IN_ORDER=1` 未实现并显式 fail-fast。

## AXI4-Lite 控制面

`mrtc_top` 的 AXI4-Lite 接口提供 enable、soft reset、状态清除、codec 配置、tensor metadata、计数器、IRQ 和 capability。地址、位域和读写属性见 [寄存器表](register_map.md)；RTL [`mrtc_axi_lite_reg_block`](../../rtl/top/mrtc_axi_lite_reg_block.sv) 是最终接口权威。

## 集成检查清单

- 固定配置在一个 block transaction 内保持不变。
- 输入 `tlast` 与 1024-sample block 边界一致。
- 下游完整支持 `tready` backpressure 和尾拍有效字节规则。
- Packet 以 `tlast` 为原子边界，不按 block ID 假设天然有序。
- 使用所选 top 对应的 tracked filelist，不手工遗漏 package 或 helper module。
- 在交付前运行对应 smoke，并确认工作树在 ignored build 产物之外保持干净。
