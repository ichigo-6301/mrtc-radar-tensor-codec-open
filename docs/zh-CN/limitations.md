# 限制与未声明项

[English](../en/limitations.md)

## 算法与功能范围

- MATLAB compression-vs-SNR 结果来自受控 synthetic Range-Doppler-like 数据，不是实测 radar capture，不能代表真实场景分布或最终 compression bound；
- MATLAB point-cloud comparison 只是模型结果检查，不包含或暗示 PointCloud RTL；
- 不包含 PointCloud RTL、RLE_RICE RTL、AXI-MM 或 DMA descriptor integration；
- bit-exact PASS 适用于记录的 finite vector/regression set，不是 formal exhaustive proof 或 coverage closure；
- ZERO_RICE 或 DELTA_RICE 按 block 配置；内部 policy 选择 `k`，不选择 predictor mode。只有实现 payload-cost fallback 的 encoder path 才具备 RAW fallback；
- 在支持 RAW fallback 的路径上，它可避免更大的 coded payload，但 packet 仍携带 `64`-byte header，不能把 payload ratio 直接当作完整链路带宽比。

## Multi-Engine 与顺序

- `785 / 397.52 / 197.41 cycles/block`、`0.987368 / 0.994115` efficiency 和假设 200 MHz 下的 `1965.3022 / 3957.4642 beam/s` 均为 simulated DDR feeder 下的 RTL simulation projection；一个 beam 在该记录中是 256 个 block，吞吐使用未舍入总周期计算，不是 FPGA timing、board DDR 或 network measurement；
- arbiter 保证 packet atomic 与无 beat interleaving，但不保证输入 block 顺序输出；
- Frame/Block metadata 支持软件 indexed reconstruction，但没有软件 reorder program PASS；记录场景也没有直接证明一次实际乱序事件；
- `OUTPUT_IN_ORDER` 不是已实现模式，不得作为硬件 Reorder Buffer 或严格保序 claim。

## FPGA 边界

- **FPGA emulation verified** 仅指 Vivado 2018.3 AXIS32 wrapper `3/3` XSim cases；
- 历史 Zynq trial copy 使用 compatibility-copied RTL 的 elaboration 与 SDK/ELF build 属于独立的 build-layer maturity result；当前公开 RTL 不声明可直接在 Vivado 2018.3 elaboration；
- AXIS32 testbench 只驱动 `s0`，不能作为双 Engine scaling、双输入并发或乱序行为证据；
- 不声明 matching FPGA bitstream、board PASS、console marker PASS、MCDMA/DDR/cache runtime、FPGA timing closure 或 LUT/FF/BRAM/DSP 资源结果；
- 早期 Block Design 与 SDK 工程只能支持结构/构建层说明，不能把预期回环流程写成已执行的板上 workload；
- 任何未来 FPGA 频率或资源 claim 必须绑定器件、工具版本、约束、bitstream hash、软件 hash 和可读测试结果。

## ASIC 与 signoff 边界

- 不声明完整 top-level IO timing closure 或 silicon readiness；
- 不声明 CDC/RDC、clock-gating、DFT/ATPG、LEC、GLS/SDF 或 foundry-signoff closure；
- `register-expanded` 只把 prefix buffer 映射为标准单元寄存器，不代表 SRAM macro PPA；
- 15 nm DC-only profile 只提供 ideal-clock internal reg-to-reg 综合边界。DC closure 不等于 P&R closure，因此不从该结果推导 post-route Fmax；
- 45 nm register-expanded 的最新 550 MHz 结果是 fixed verified internal reg-to-reg academic closure point，而不是 maximum frequency。它使用 700 MHz setup-closed DC mapped netlist、OpenRCX SPEF 和 PrimeTime；setup/hold coverage 为 100%，但 1756 个异步 reset pin 不在 max-delay coverage 内，也不覆盖完整 IO、reset recovery/removal、OCV/MMMC、macro DRC/LVS/PEX 或 foundry signoff；
- 45 nm `sram-macro` 的 333 MHz 结果已完成并验证芯片级 P&R、同次 SPEF 与内部 PrimeTime setup/hold timing。整体 profile 因 OpenRAM characterization 为 analytical 且 macro DRC/LVS/PEX 未闭合而保持 partial；
- 审核 waiver 只适用于两个宏上共 256 个未使用 `dout0[127:0]` minimum-capacitance endpoint，属于 profile-specific、exact-set matched 对象，不允许 missing 或 extra object。它不是 blanket capacitance、setup/hold 或 functional read data waiver；
- SRAM 333 MHz 是固定 verified closure point，不能扩大为 400 MHz 或 exact SRAM Fmax claim；没有受控 400 MHz failure run 与 critical-path evidence，不能声称 SRAM 是唯一限制因素；
- SRAM 宏面积和 register-expanded 面积不能在未说明物理容量、读延迟和模型差异时直接比较；
- 公共结果中的 route DRC/antenna 计数属于指定 academic platform run，不等同于 foundry DRC/LVS。route-tool DRC 0 覆盖 routed 顶层实现与 macro abstract view，不覆盖 macro 晶体管级 DRC/LVS/PEX；
- `DC timing estimate`、内部 post-route reg-to-reg timing 和完整 IO timing closure 是三个不同层次，不能互相替代。

## 公开边界

PDK、Liberty/DB、LEF/GDS、SPEF、许可证、绝对路径、原始 EDA 工作目录、生成的 Vivado project/BD/IP、bitstream、SDK workspace 和未授权来源不随公开仓库发布。当前 `main` 的 post-RC3 展示更新不改变 immutable RC3 的结果身份或发行边界。
