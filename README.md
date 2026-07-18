# MRTC RDTC

[English](README.en.md)

MRTC RDTC 是一个面向 OFDM 感知和毫米波雷达 Range-Doppler 张量的流式无损压缩数字 IP。

## 当前公开版本

当前公开版本为 **RDTC v1 lossless codec IP**。RDTC 位于雷达感知数据生成模块与存储、传输或后级处理模块之间，在当前支持模式下提供逐比特可恢复的流式压缩与解压缩。

## 功能特性

- RAW_BYPASS、ZERO_RICE 和 DELTA_RICE 编码模式；
- 对应的流式解码路径；
- AXI-Stream 数据接口与 backpressure 支持；
- AXI4-Lite 配置与状态接口；
- malformed-stream 错误检测；
- C/DPI-C bit-exact reference model；
- 文件向量、loopback 与负向验证环境。

## 实现 Profiles

两个 profile 保持相同的 RTL 外部接口、AXI 行为、寄存器映射和码流格式。差异仅在 prefix buffer 的物理实现。

| Profile | Prefix buffer | 公开工艺范围 | 当前状态 |
|---|---|---|---|
| `register-expanded` | 标准单元寄存器，SRAM macro 数为 0 | 15 nm DC；45 nm DC + OpenROAD/OpenRCX + PrimeTime | 15 nm 800 MHz DC internal timing 通过；45 nm 使用 600 MHz closed DC netlist，在 400 MHz 完成 route 与 internal reg-to-reg STA |
| `sram-macro` | 每个 engine 一个 `64x128 1RW1R` OpenRAM macro，共两个 | 45 nm DC + OpenROAD/OpenRCX + PrimeTime | 333 MHz route 与 internal reg-to-reg STA 通过；整体保持 `partial` |

55 nm register-expanded 综合矩阵保留为私有结果；许可证与公开授权确认前不发布指标，也不声明 15/55 nm post-route Fmax。

## 输入输出与系统位置

RDTC 接收按块组织的 Range-Doppler 复数样本流，输出带 block header 的压缩 AXI-Stream 数据包。解码器恢复相同格式的样本流。接口、header 和 payload 规则见 [接口文档](docs/zh-CN/interfaces.md) 与 [码流格式](docs/zh-CN/bitstream_format.md)。

## 验证状态

| 阶段 | 状态 | 当前结果 |
|---|---|---|
| C reference model 与公开向量 | verified | RAW/ZERO/DELTA 测试通过 |
| RTL elaboration 与 Questa regression | verified | Icarus PASS；公开 full regression PASS |
| SpyGlass Lint | partial | 0 fatal、0 error、225 warnings |
| Register-expanded 15/45 nm DC | verified | 400/600/800 MHz 矩阵有记录；45 nm 的 800 MHz 点未闭合 |
| Register-expanded 45 nm P&R/PT | verified | 400 MHz；route DRC/antenna 为 0；setup/hold WNS +0.80/+0.04 ns |
| SRAM-macro 45 nm P&R/PT | partial | 333 MHz；setup/hold WNS +0.57/+0.04 ns；保留 analytical SRAM 与 min-cap waiver caveat |

已核验结果、约束条件和未声明项见 [结果](docs/zh-CN/results.md) 与 [限制](docs/zh-CN/limitations.md)。这些结果是 academic implementation evidence，不构成完整 top-level IO timing closure 或 foundry signoff。

## 快速开始

开源 preflight：

```bash
make rdtc_v1_45nm_defconfig
make -C ref_model/c test
make rtl-smoke
```

Questa/ModelSim 回归：

```bash
make sim
make sim-full
```

Profile 通过 `make rdtc_v1_register_45nm_dc600_pnr400_cap60_defconfig` 或 `make rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig` 选择。商业工具、PDK、library 和 macro 路径只允许写入 ignored `flows/local/`；完整契约见 [验证说明](docs/zh-CN/verification.md) 与 [实现流程](flows/README.md)。

## 文档导航

- [架构](docs/zh-CN/architecture.md)
- [算法](docs/zh-CN/algorithm.md)
- [验证](docs/zh-CN/verification.md)
- [FPGA 实现](docs/zh-CN/fpga_implementation.md)
- [ASIC 实现](docs/zh-CN/asic_implementation.md)
- [实现流程](flows/README.md)
- [路线图](docs/zh-CN/roadmap.md)
