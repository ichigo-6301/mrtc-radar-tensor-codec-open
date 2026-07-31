# FPGA Emulation、Direct OOC 与 Zynq 集成

[English](../en/fpga_implementation.md)

## 结论

**FPGA emulation verified** 专指历史 Vivado 2018.3 AXIS32 XSim `3/3` 结果。独立的 bounded Direct-AXIS 双 Engine top 已在 `xc7z100ffg900-2` 上获得 Vivado 2022.2 OOC post-route 200 MHz 内部 timing/resource verified point。两者都不声明 bitstream 或板上运行，历史 AXIS32 结果仍不包含 timing/resource claim。

![Zynq FPGA emulation evidence layers](../assets/zynq_emulation_path.svg)

## AXIS32 Wrapper XSim

Vivado 2018.3 XSim 的 `3/3` block-level cases 通过：

- ZERO_RICE block；
- DELTA_RICE block，并覆盖输出 backpressure；
- mixed two-block sequence，并检查 packet boundary。

Testbench 经过真实 RDTC encoder path，并用 decoder golden comparison 检查恢复数据。覆盖范围包括 AXIS32 width conversion、可变长 packet serialization、最后 beat 的 `tkeep/tlast`、输入 gap 和输出 stall。

该 testbench 只驱动 `s0`，`s1` 未作为并发输入使用。因此这里不声称 XSim 已验证双 Engine scaling、双输入并发或乱序输出。Multi-Engine scaling 和 packet arbitration 由独立 RTL regression 支撑。

## Bounded Direct-AXIS OOC 200 MHz

Direct profile 使用当前 AXIS128 top、两个 bounded Engine、8 个 distributed-RAM way 与一个 16-beat output FIFO。Vivado 2022.2 在 `xc7z100ffg900-2` 上 fresh 执行 OOC implementation，并通过固定 5.000 ns 内部时序门禁：

| Post-route 项目 | 结果 |
|---|---:|
| Setup WNS/TNS/failing endpoints | `+0.001 ns / 0 / 0` |
| Hold WNS/TNS/failing endpoints | `+0.062 ns / 0 / 0` |
| Pulse-width WNS/TNS/failing endpoints | `+1.732 ns / 0 / 0` |
| Slice LUT / registers | `32,672 / 18,519` |
| RAMB18 / RAMB36 | `0 / 0` |
| Ring primitives | 8 个 way 内精确 `1024 x RAM32X1S` |
| DDR feeder / payload commit / legacy packet buffer | `0 / 0 / 0` |

旧 payload512 对照为 `53,235 LUT / 85,269 FF / 4 RAMB36`；在该固定配置下，Direct point 减少 `20,563 LUT`、`66,750 FF` 并删除全部 4 个 RAMB36。这是结构对比，不是板级功耗或应用吞吐结果。

1 ps setup margin 按原值披露，不能扩大为更高频率 claim。OOC constraint 覆盖 internal endpoint，不包含 board-level IO delay；worst path 仍是 Engine error state 经过 global fatal/output-ready control 到 width-packer 的 routing-dominated 控制路径。该结果不推导 Fmax、bitstream、board 或持续零间隔结论。

证据：[bounded Direct FPGA OOC summary](../../evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml)。

## Zynq-7000 平台路径

早期 Vivado/SDK trial copy 包含 Zynq PS、Block Design、MCDMA/DDR 连接与软件测试程序，可用于构建 SoC 回环验证路径。Vivado 2018.3 不接受仓库中的 `parameter string`，因此记录的成功 `synth_design -rtl` 使用经过兼容处理的 copied RTL。当前公开且受 evidence 边界约束的结论限定为：

| 层次 | 状态 | 可以说明什么 |
|---|---|---|
| 当前公开 RTL source and wrapper | verified input | 可进入现代 SystemVerilog 仿真；不等于 Vivado 2018.3 直接 elaboration |
| Trial-copy RTL elaboration | verified with compatibility copy | 历史 trial copy 的结构、端口和依赖完成 `synth_design -rtl` |
| SDK/ELF build | verified | 平台软件工程能够构建 |
| Matching bitstream | not claimed | 未声明当前双 Engine wrapper 生成匹配 bitstream |
| Board execution / console PASS | not claimed | 未声明板上 workload 或 console marker PASS |
| MCDMA/DDR/cache runtime | not claimed | 未声明 DMA descriptor、cache coherency 或实测 DDR 行为 |
| 历史 AXIS32 timing/resources | not claimed | 该 profile 未发布器件绑定的 WNS、Fmax、LUT/FF/BRAM/DSP；Direct OOC 结果是独立 profile |

因此推荐的完整表述是：

> FPGA emulation 结果：AXIS32 datapath XSim suite `3/3` verified。独立的 Zynq trial-copy 成熟度结果：compatibility-copied RTL elaboration 与 SDK/ELF build verified；当前公开 RTL 的直接 elaboration 和板上硬件执行均未声明。

历史平台包含 BD/MCDMA 结构与软件接口，但这里的 verified 层次只到 trial-copy elaboration 和 SDK/ELF build，不等于当前公开 RTL 的直接 Vivado 2018.3 elaboration，也不等于 MCDMA runtime PASS。

公开 evidence 摘要与数据：[XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## 与 Multi-Engine 结果的关系

FPGA 页面与 Multi-Engine RTL evidence 解决不同问题：

- FPGA XSim 证明 AXIS32 adapter、真实 codec path 和 loopback checker 在记录的三组 case 中工作；
- Multi-Engine RTL regression 证明 block distribution、独立 packet buffer、packet-locked output 和扩展性；
- Direct OOC 在一个固定 FPGA point 验证独立 bounded 双 Engine 结构与内部时序；
- 这些层次不能合并成“双 Engine bitstream 板级验证通过”的 claim。

假设 200 MHz 的 `1965.3022 / 3957.4642 beam/s` 只是 2/4 Engine RTL simulation projection；一个 beam 在该记录中是 256 个 block，吞吐由未舍入总周期计算，不是 FPGA implementation frequency。任何未来板级结果必须绑定器件、Vivado version、constraints、bitstream hash、software hash、测试向量和 console/result marker。
