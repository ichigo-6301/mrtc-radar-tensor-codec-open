# MRTC RDTC

[English](README.en.md)

MRTC RDTC 是一个面向 OFDM 感知和毫米波雷达 Range-Doppler 张量的流式无损压缩数字 IP。

## 当前公开版本

当前公开发行是 **RDTC v1 lossless codec IP `register550-rc3`**。该发行增加已验证的 ICS55 RVT DC-only evidence 和对未完成 ECOS route 尝试的边界记录，不改变 RTL、reference behavior、码流、接口、寄存器映射或已发布实现指标。

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

| Profile ID | Maturity | 范围 | 当前结果 |
|---|---|---|---|
| `rdtc_v1_register_nangate45_550` | verified | register-expanded Nangate45 | 700 MHz DC closed netlist；550 MHz OpenROAD/OpenRCX/PT internal reg-to-reg closure |
| `rdtc_v1_sram_nangate45_333` | partial | 2 x `64x128 1RW1R` SRAM macro | 333 MHz internal reg-to-reg result；保留 analytical SRAM 与 waiver caveat |
| `rdtc_v1_register_ics55_rvt_dc` | verified | register-expanded ICS55 RVT | 400/800 MHz DC 点 constraint-clean；最高 setup-closed 点 800 MHz；DC-only |
| `rdtc_v1_register_ics55_ecos_preview` | planned | ICS55/ECOS preview | full-RDTC 400 MHz 尝试已完成至 detailed route，但因非收敛和资源保护停止；没有 P&R/STA claim |

55 nm 使用 Apache-2.0 的 ICsprout55 `v1.10.100` public-preview PDK，只发布 register-expanded DC 对比；不发布 PDK payload 或商业工具原始报告，也不声明 15/55 nm post-route Fmax。

## 输入输出与系统位置

RDTC 接收按块组织的 Range-Doppler 复数样本流，输出带 block header 的压缩 AXI-Stream 数据包。解码器恢复相同格式的样本流。接口、header 和 payload 规则见 [接口文档](docs/zh-CN/interfaces.md) 与 [码流格式](docs/zh-CN/bitstream_format.md)。

## 验证状态

| 阶段 | 状态 | 当前结果 |
|---|---|---|
| C reference model 与公开向量 | verified | RAW/ZERO/DELTA 测试通过 |
| RTL elaboration 与 Questa regression | verified | Icarus PASS；公开 full regression PASS |
| SpyGlass Lint | partial | 0 fatal、0 error、225 warnings |
| Register-expanded 15/45/55 nm DC | verified | ICS55 RVT 400/800 MHz 点 constraint-clean，最高 setup-closed 点 800 MHz；600 MHz 留有 2/3 个 transition/capacitance 违例 |
| Register-expanded 45 nm P&R/PT | verified | 550 MHz；route DRC/antenna 为 0；setup/hold WNS +0.26/+0.04 ns |
| SRAM-macro 45 nm P&R/PT | partial | 333 MHz；setup/hold WNS +0.57/+0.04 ns；保留 analytical SRAM 与 min-cap waiver caveat |
| Register-expanded ICS55/ECOS P&R | not completed | 400 MHz full-design route 在 detailed router 中因非收敛和资源保护停止；未生成 routed handoff，STA 未运行 |

已核验结果、约束条件和未声明项见 [结果](docs/zh-CN/results.md) 与 [限制](docs/zh-CN/limitations.md)。这些结果是 academic implementation evidence，不构成完整 top-level IO timing closure 或 foundry signoff。

## 快速开始

开源 preflight：

```bash
make rdtc_v1_public_preflight_defconfig
make showconfig
make -C ref_model/c test
make rtl-smoke
```

Questa/ModelSim 回归：

```bash
make sim
make sim-full
```

Profile 通过 `make rdtc_v1_register_45nm_dc700_pnr550_cap60_defconfig` 或 `make rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig` 选择。商业工具、PDK、library 和 macro 路径只允许写入 ignored `flows/local/`；完整契约见 [验证说明](docs/zh-CN/verification.md) 与 [实现流程](flows/README.md)。

## 文档导航

- [架构](docs/zh-CN/architecture.md)
- [算法](docs/zh-CN/algorithm.md)
- [验证](docs/zh-CN/verification.md)
- [FPGA 实现](docs/zh-CN/fpga_implementation.md)
- [ASIC 实现](docs/zh-CN/asic_implementation.md)
- [ICS55 ECOS 实现尝试](docs/zh-CN/ics55_ecos_implementation.md)
- [实现流程](flows/README.md)
- [发行模型](docs/zh-CN/release_model.md)
- [路线图](docs/zh-CN/roadmap.md)
