# MRTC-RDTC 可扩展雷达张量无损编解码 IP

[![Public preflight](https://github.com/ichigo-6301/mrtc-radar-tensor-codec-open/actions/workflows/public-preflight.yml/badge.svg)](https://github.com/ichigo-6301/mrtc-radar-tensor-codec-open/actions/workflows/public-preflight.yml) ![RTL](https://img.shields.io/badge/RTL-SystemVerilog-2f6f9f) [![License](https://img.shields.io/github/license/ichigo-6301/mrtc-radar-tensor-codec-open)](LICENSE)

[English](README.en.md) · [算法](docs/zh-CN/algorithm.md) · [架构](docs/zh-CN/architecture.md) · [验证](docs/zh-CN/verification.md) · [结果](docs/zh-CN/results.md) · [不可变 RC3](docs/zh-CN/release_model.md)

**面向 OFDM 通感与毫米波雷达 Range-Doppler 张量的流式无损压缩器：从 MATLAB 算法、可综合 RTL 和 Multi-Engine 调度，一直验证到 FPGA emulation 与 ASIC post-route STA。**

RDTC 以 block 为单位压缩 I16Q16 样本，在保持 bit-exact 恢复的同时降低片外 DDR 与链路流量；64-byte self-describing header 保留模式、长度和 Frame/Block 身份，使 packet 可独立存储、传输与恢复。

![MRTC-RDTC end-to-end overview](docs/assets/rdtc_overview.svg)

<a id="resume-results"></a>

## 60 秒总览

| 结果 | 已核验内容与适用范围 | 直接 Evidence |
|---|---|---|
| 编解码与验证 | `RAW_BYPASS`、`ZERO_RICE`、`DELTA_RICE` 三模式；`1024` 个 I16Q16 sample/block、64-byte header、128-bit AXI-Stream；MATLAB/C/DPI-C/RTL 有限向量 bit-exact | [Reference validation](evidence/rdtc_v1_reference_validation.yaml) · [验证矩阵](docs/zh-CN/verification.md) |
| 单 Engine 流水 A/B | 固定 256-block ZERO_RICE 历史 RTL stream；平均 packet-completion spacing `8220 -> 785 cycles/block`，提升 `10.47×`；另一项固定 `smoke_zero_sparse` 测量中，首个 payload valid 到 accepted `TLAST` 为 `7693 -> 721 cycles`、`10.67×` | [YAML](evidence/rdtc_v1_bitpacker_pipeline_ab.yaml) · [CSV](evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv) |
| Multi-Engine 扩展 | 固定 256-block 历史 RTL workload；同 workload 的 Stage16D2 单 Engine reference 与 2/4-Engine buffered-wrapper run 分别为 `785 / 397.52 / 197.41 cycles/block`，扩展效率 `98.7368% / 99.4115%` | [YAML](evidence/rdtc_v1_multiengine_rtl.yaml) · [CSV](evidence/data/rdtc_v1_multiengine_scaling.csv) |
| Bounded Direct 双 Engine | 单路 AXIS128、严格 Engine `0 -> 1` block 轮转、有序 packet mux；双 block regression 的 packet/sideband/selected-k 一致且 decoder bit-exact；`~277 > 256 cycles/block`，不声明持续零间隔调度 | [Direct RTL evidence](evidence/rdtc_v1_bounded_direct_rtl.yaml) |
| Direct-AXIS DC A/B | 同一 Nangate45 library、315 MHz SDC、双 Engine、全寄存器、禁止 retime；cell area/count 减少 `72.53% / 71.98%`，仅为 DC-only 架构 A/B | [DC A/B evidence](evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml) |
| ASIC post-route STA | Direct register-expanded / 8-macro OpenRAM profile 分别在 `600/300 MHz` 完成 fixed academic post-route PrimeTime setup/hold 闭合；不是 Fmax 或 foundry signoff | [ASIC evidence](evidence/rdtc_v1_bounded_direct_asic.yaml) · [结果矩阵](docs/zh-CN/results.md) |
| FPGA OOC | Direct-AXIS 在 `xc7z100ffg900-2` 上完成 Vivado 2022.2 OOC post-route 200 MHz；WNS `+0.001/+0.062 ns`，`32,672 LUT / 18,519 FF / 0 BRAM`；不声明 bitstream 或板级吞吐 | [FPGA evidence](evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml) |

<p align="center">
  <a href="evidence/rdtc_v1_bitpacker_pipeline_ab.yaml"><img src="docs/assets/bitpacker_pipeline_ab.svg" width="760" alt="Single-Engine steady-state RTL pipeline A/B"></a>
</p>
<p align="center">
  <a href="evidence/rdtc_v1_multiengine_rtl.yaml"><img src="docs/assets/engine_scaling.svg" width="760" alt="Historical buffered Multi-Engine average block-interval scaling"></a>
</p>

<a id="rtl-reading-path"></a>

## 10 分钟代码阅读路径

| 顺序 | 文件 | 阅读重点 |
|---:|---|---|
| 1 | [`mrtc_top.sv`](rtl/top/mrtc_top.sv) | 从 AXI4-Lite 配置、状态寄存器和双向 AXIS128 端口理解完整 IP 边界。 |
| 2 | [`mrtc_rdtc_codec_top.sv`](rtl/rdtc/mrtc_rdtc_codec_top.sv) | 查看单 Engine encoder/decoder 如何共享配置并形成 loopback datapath。 |
| 3 | [`mrtc_prefix_k_accum_stream.sv`](rtl/rdtc/mrtc_prefix_k_accum_stream.sv) | 跟踪 ZERO/DELTA 预测、signed residual 映射、16 个候选代价累加与 `k` reduction。 |
| 4 | [`mrtc_rice_bitpacker_lane_axis.sv`](rtl/rdtc/mrtc_rice_bitpacker_lane_axis.sv) | 阅读 lane-parallel quotient/remainder token 生成、归一化和 AXIS128 拼接流水。 |
| 5 | [`mrtc_header_gen.sv`](rtl/rdtc/mrtc_header_gen.sv) · [`mrtc_header_axis_streamer.sv`](rtl/rdtc/mrtc_header_axis_streamer.sv) · [`mrtc_rdtc_decoder_top.sv`](rtl/rdtc/mrtc_rdtc_decoder_top.sv) | 串起 64-byte header、header/payload framing 与 bit-exact 解码恢复。 |
| 6 | [`mrtc_rdtc_ddr_multiengine_wrapper.sv`](rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) · [`mrtc_axis_packet_buffer.sv`](rtl/rdtc/mrtc_axis_packet_buffer.sv) | 定位 block dispatcher、per-Engine packet buffer 与锁定到 `tlast` 的输出仲裁。 |
| 7 | [`mrtc_rdtc_bounded_axis_multiengine_wrapper.sv`](rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv) | 对照最终 Direct-AXIS 双 Engine job table、有序 packet mux 和有限 output credit。 |
| 8 | [`mrtc_dpi_pkg.sv`](tb/dpi/mrtc_dpi_pkg.sv) · [`tb_rdtc_dpi_smoke.sv`](sv/tb_rdtc_dpi_smoke.sv) · [`tb_rdtc_codec_top_smoke.sv`](tb/sv/tb_rdtc_codec_top_smoke.sv) | 查看 C/DPI-C 函数边界以及公开 RTL AXIS128 encode/decode smoke。 |

### 选择集成入口

| 目标 | Canonical top | Filelist / 检查 |
|---|---|---|
| 完整 AXI4-Lite + AXIS128 IP | [`mrtc_top`](rtl/top/mrtc_top.sv) | [`rdtc_v1.f`](flows/manifests/rdtc_v1.f) · `make integration-smoke` |
| 单 Engine codec datapath | [`mrtc_rdtc_codec_top`](rtl/rdtc/mrtc_rdtc_codec_top.sv) | [`rdtc_v1.f`](flows/manifests/rdtc_v1.f) · `make integration-smoke` |
| Descriptor/DDR Multi-Engine | [`mrtc_rdtc_ddr_multiengine_wrapper`](rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) | [`rdtc_v1_multiengine_smoke.f`](flows/manifests/rdtc_v1_multiengine_smoke.f) · `make multiengine-smoke` |
| Bounded Direct-AXIS 双 Engine（opt-in） | [`mrtc_rdtc_bounded_axis_multiengine_wrapper`](rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv) | [`rdtc_v1_bounded_direct.f`](flows/manifests/rdtc_v1_bounded_direct.f) · `make bounded-direct-rtl-smoke` |
| 历史 Zynq AXIS32 adaptation | [`mrtc_rdtc_axis32_wrapper`](rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) | [`rdtc_v1_fpga_wrapper_smoke.f`](flows/manifests/rdtc_v1_fpga_wrapper_smoke.f) · `make fpga-wrapper-smoke` |

[查看参数、端口、transaction 和 ordering contract](docs/zh-CN/interfaces.md)

<a id="technical-review-path"></a>

## 技术审阅快速路径（无需商业 EDA）

```bash
make rdtc_v1_public_preflight_defconfig
make codec-demo
make -C ref_model/c test
make rtl-smoke
make multiengine-smoke
make bitpacker-pipeline-ab-validate
make bounded-dc-ab-validate
```

首项生成 public-safe 配置，随后四项编译或运行公开 C/RTL 入口；末两项只校验脱敏的公开 Evidence、身份和计算合同，不会重新执行 Design Compiler、P&R 或 PrimeTime。

<a id="public-scope-provenance"></a>

## Public Scope / Provenance

本仓包含可综合 RTL、公开适配、验证入口与脱敏 Evidence；不包含合作方数据、商业工具产物、PDK 或私有系统集成资产。公开边界由 [Public Scope](PUBLIC_SCOPE.md)、[Claims](provenance/claims.yaml)、[Evidence](provenance/evidence.yaml) 与 [Nonclaims](provenance/nonclaims.yaml) 共同约束。

## 1. 算法：为什么选择 RDTC

ZERO/DELTA 路径把预测残差映射为非负整数，在 block 内评估候选 Rice `k`，再由 lane-parallel bitpacker 输出变长 payload。支持 fallback 的 encoder path 会在编码无收益时保留 RAW payload；模式与 fallback 边界由具体集成路径决定，不被包装成未经证明的自动算法选择器。

MATLAB synthetic study 在受控 Range-Doppler-like 场景中比较 ZERO_RICE 与 DELTA_RICE，并对记录用例检查 `NMSE=0`、`max_abs_error=0` 和 point-cloud match ratio `1`。这些数据不是实测雷达采集，PointCloud 也不是 RTL 功能。

数据与边界：[算法理论及 MATLAB 原图](docs/zh-CN/algorithm.md) · [MATLAB evidence](evidence/rdtc_v1_matlab_algorithm_study.yaml) · [Multi-Engine evidence](evidence/rdtc_v1_multiengine_rtl.yaml)

## 2. 架构：从单 Engine 到 Multi-Engine

单 Engine 由 ping-pong block buffer、predictor/residual mapper、prefix cost 与 `k` selection、lane-parallel bitpacker、header generator、packet buffer 和 decoder 构成。输入捕获可与当前 block 计算重叠，packet buffer 则隔离变长编码与 AXI backpressure。

参数化 Multi-Engine wrapper 按 block Round-Robin 分发任务，并锁定一个输出 packet 直到 `tlast`，因此 packet 内不会发生 beat interleaving。完成顺序由数据相关压缩延迟决定且不保证；Frame/Block metadata 只提供 indexed software reconstruction 接口，本仓库不声明软件 reorder 程序 PASS，也没有把未直接观察到的乱序事件写成验证结果。

新的 opt-in Direct-AXIS profile 去掉 DDR feeder 与每 Engine payload commit store，只保留双 Engine 的 `4 x 32x128` 1RW way-ring、两项 job table 与全局 16-beat output FIFO。它固定为 `ZERO_RICE + prefix-128 adaptive-k`，每个 Rice word 必须 `<=128 bit`；output credit 耗尽会 sticky fatal，可能留下外部半包。记录的有序 packet service 约 `277 cycles/block`，大于零间隔输入的 `256 cycles/block`，因此不声明持续零停顿。

[查看单 Engine pipeline、Multi-Engine wrapper 与 ordering contract](docs/zh-CN/architecture.md)

## 3. 验证：同一个码流合同贯穿各层

```text
MATLAB synthetic study
        -> C reference model
        -> DPI-C / SystemVerilog bit-exact comparison
        -> Multi-Engine packet and backpressure regression
        -> FPGA emulation boundary
        -> ASIC P&R / same-run SPEF / PrimeTime
```

公开 smoke 覆盖 C reference、RTL loopback、packet 边界、`tkeep/tlast`、随机 backpressure、Multi-Engine 仲裁以及 AXIS32 wrapper。公开 Icarus-compatible 检查是 portability/elaboration 门禁，不能替代 ModelSim 或 Vivado evidence。有限向量与 regression PASS 不等于形式穷尽或 coverage closure。

固定可见 demo 真实调用公开 C encoder/decoder：1024-sample `delta_smooth` 输入选择 `DELTA_RICE` 与 `k=0`，从 4096 raw bytes 生成 360-byte self-describing packet，再逐字节恢复原始 I/Q，结果为 `RDTC_CODEC_DEMO_PASS`。输入、packet 和解码输出哈希见 [codec demo evidence](evidence/rdtc_v1_codec_demo.yaml)。

[查看验证矩阵与可复现入口](docs/zh-CN/verification.md)

## 4. FPGA：分层陈述成熟度

**FPGA emulation verified** 仍专指固定 source commit `43deb9f` 的 Vivado 2018.3 AXIS32 XSim `3/3`，且为 single-`s0` testbench。独立的 Direct-AXIS profile 已在 `xc7z100ffg900-2` 上完成 Vivado 2022.2 OOC post-route 200 MHz：setup/hold WNS 为 `+0.001/+0.062 ns`，结构为 2 Engine、8 way、`1024 x RAM32X1S`，资源为 `32,672 LUT / 18,519 FF / 0 BRAM`。这是内部 OOC fixed closure point，不是 Fmax，也不声明 bitstream、板上 console PASS、MCDMA/DDR runtime 或实测吞吐。

[查看 FPGA emulation 与 Zynq 集成边界](docs/zh-CN/fpga_implementation.md)

## 5. ASIC：架构 DC A/B 与布局布线后 STA

### 同约束架构 A/B（DC-only）

在同一 Nangate45 typical library、315 MHz 同步边界 SDC、双 Engine、全寄存器存储、`compile_ultra` 且禁止 retime 的条件下，buffered wrapper 为 `1,529,495.20 um2 / 786,342 cells`，Direct-AXIS 为 `420,208.44 um2 / 220,298 cells`。移除 DDR feeder 与 per-Engine payload commit 后，DC cell area 减少 `72.53%`、cell count 减少 `71.98%`。这是架构级综合对比，不代表 SRAM 宏面积、post-route 面积、功耗或 Fmax。

### 布局布线后闭合点

**以下频率闭合点来自 route 后的 PrimeTime setup/hold STA，不是上述 DC A/B 估计。** STA 使用 matching routed netlist、SDC 与同次 OpenRCX SPEF；DC 只提供进入物理实现的 mapped netlist。

| Profile | Verified implementation result | Maturity boundary |
|---|---|---|
| `rdtc_v1_register_nangate45_550` | 550 MHz OpenROAD P&R + same-run OpenRCX SPEF + PrimeTime；configured die/core 为 `1200 x 1200 um` / `1159.72 x 1155.20 um`；core area `421,120 um2`；route DRC `0`；antenna net/pin `0/0`；setup/hold WNS `+0.26/+0.04 ns` | internal reg-to-reg implementation/timing verified |
| `rdtc_v1_sram_nangate45_333` | 双 `64x128 1RW1R` OpenRAM macro；333 MHz 芯片级 P&R + same-run SPEF + internal PT；configured die/core 为 `1200 x 1200 um` / `1159.72 x 1155.20 um`；route DRC `0`；antenna net/pin `0/0`；setup/hold WNS `+0.57/+0.04 ns` | 芯片级 P&R 与内部时序 verified；academic Nangate45/OpenRAM 平台不声明生产 PDK、macro signoff 或 silicon readiness；256-endpoint exact-set waiver 单独披露 |
| `rdtc_v1_bounded_direct_register_expanded` | Direct-AXIS、双 Engine、`32,768 bit` ring 展开为寄存器、0 宏；600 MHz P&R + OpenRCX + PT；route DRC/antenna `0/0`；setup/hold WNS `+0.03/+0.02 ns` | fixed academic internal closure point；不是 Fmax 或持续零停顿证据 |
| `rdtc_v1_bounded_direct_sram_macro` | Direct-AXIS、8 个 `32x128 1RW` OpenRAM 宏；300 MHz P&R + OpenRCX + PT；route DRC/antenna `0/0`；setup/hold WNS `+0.16/+0.02 ns` | 顶层实现与内部时序 verified；macro DRC/LVS/PEX 未闭合；600 MHz 为 `MACRO_MODEL_BLOCKED` |

这些频率是对应 profile 的 fixed verified closure point，不是 maximum frequency。结果处于 academic PDK/OpenRAM 实现范围，不声明完整 top-level IO timing、OCV/MMMC、foundry signoff 或 silicon readiness。

[查看 ASIC flow contract](docs/zh-CN/asic_implementation.md) · [DC A/B evidence](evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml) · [完整结果矩阵](docs/zh-CN/results.md) · [限制与未声明项](docs/zh-CN/limitations.md)

## 完整公开门禁

```bash
make rdtc_v1_public_preflight_defconfig
make public-preflight
make bounded-dc-ab-validate
```

该门禁聚合公开 C/RTL smoke、文档、schema、identity、checksum、asset 与泄漏扫描；`bounded-dc-ab-validate` 仍只验证 Evidence。配置完整的 Questa/ModelSim 环境可继续运行 `make sim` 与 `make sim-full`。商业工具、PDK、library 和 macro 路径仅允许出现在 ignored `flows/local/`。

## 文档与发行边界

[接口](docs/zh-CN/interfaces.md) · [码流格式](docs/zh-CN/bitstream_format.md) · [寄存器](docs/zh-CN/register_map.md) · [公开发行模型](docs/zh-CN/release_model.md) · [Evidence 索引](provenance/evidence.yaml) · [Claims](provenance/claims.yaml)

当前 showcase 是 RC3 之后的展示更新；不可变 annotated tag `rdtc-v1-register550-rc3` 仍固定原始 `register550-rc3` 发行，不因文档和公开适配更新而移动或重建。
