# MRTC-RDTC 可扩展雷达张量无损编解码 IP

[English](README.en.md)

MRTC-RDTC 面向 OFDM 通感与毫米波雷达的连续 Range-Doppler 张量：以 block 为单位压缩 I16Q16 样本，在保持 bit-exact 恢复的同时降低片外带宽，并把算法、可综合 RTL、Multi-Engine 调度、验证和 ASIC 实现连接成一条可审计工程链。

![MRTC-RDTC Multi-Engine architecture](docs/assets/multi_engine_wrapper.svg)

## 背景与算法

连续感知谱既要求实时吞吐，也会快速放大片外 DDR 和互连压力。RDTC 支持按 block 配置 `RAW_BYPASS`、`ZERO_RICE` 或 `DELTA_RICE`；ZERO/DELTA 路径中的预测残差经过有符号映射、block-level `k` 选择和 Rice bit packing。支持 payload-cost fallback 的 encoder path 可在压缩无收益时回退到 RAW，避免更大的 coded payload。

MATLAB synthetic study 用受控合成数据比较模式并检查无损恢复。下图只表示该合成数据集上的压缩趋势，不是实测雷达数据，也不代表 PointCloud RTL。

![Synthetic compression ratio versus SNR](docs/assets/compression_vs_snr.svg)

数据来源：[MATLAB evidence](evidence/rdtc_v1_matlab_algorithm_study.yaml) · [公开 CSV](evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## 从单 Engine 到 Multi-Engine

单 Engine 处理 `1024` 个 I16Q16 sample 的 block，原始数据为 `4096` byte；编码器生成 `64`-byte self-describing header，并通过 128-bit AXI-Stream 输出。内部流水包含 ping-pong block buffer、预测/残差映射、prefix 与 `k` 计算、lane-parallel bitpacker，以及与输入解耦的 packet buffer。

参数化 Multi-Engine wrapper 以 Round-Robin 分发 block，为每个 Engine 配置独立 feeder、codec 和 packet buffer，再用 packet-locked arbiter 保证一个 packet 内没有 beat interleaving。完成顺序不保证；Frame/Block metadata 支持软件按索引恢复顺序，但本仓库不声明软件 reorder 程序 PASS。

![Multi-Engine RTL simulation scaling](docs/assets/engine_scaling.svg)

历史 fixed-commit 256-block RTL workload 的 `1/2/4` Engine 结果为 `785 / 397.52 / 197.41 cycles/block`；2/4 Engine 扩展效率为 `0.987368 / 0.994115`。该记录把一个 beam 定义为 256 个 block；在假设 200 MHz 下，由 CSV 中未舍入的 `estimated_cycles_per_beam` 得到 `1965.3022 / 3957.4642 beam/s`，不能仅从展示到两位小数的 cycles/block 精确反推。这些是 RTL simulation projection，不是 FPGA timing closure 或板级吞吐结果；当前公开 adaptation 仅以 2-Engine、2-block smoke 检查依赖闭包与 packet/loopback 正确性，不重算该性能矩阵。

数据来源：[Multi-Engine evidence](evidence/rdtc_v1_multiengine_rtl.yaml) · [公开 CSV](evidence/data/rdtc_v1_multiengine_scaling.csv)

## 验证与 FPGA

验证链覆盖 MATLAB、C/DPI-C、SystemVerilog RTL、loopback、随机 backpressure、packet 边界和 malformed-stream 条件。

**FPGA emulation verified.** 在固定 source commit `43deb9f` 上，Vivado 2018.3 的 AXIS32 wrapper 在 XSim 中 `3/3` block-level case 通过，覆盖真实编码路径、decoder golden comparison、宽度转换、可变长 packet、`tkeep/tlast`、输入间隙与输出 backpressure。公开 wrapper 与 testbench 是该历史 source 的 Icarus-compatible adaptation，不构成新的 Vivado 2018.3 结果。XSim testbench 只驱动 `s0`；双 Engine 扩展与仲裁来自另一组固定 commit RTL regression。历史 Zynq-7000 trial copy 使用 Vivado-2018.3-compatible copied RTL 完成 RTL elaboration，并完成 SDK/ELF build；当前公开 RTL 不声明可直接在 Vivado 2018.3 elaboration，也不声明 bitstream、板上 console PASS、MCDMA/DDR runtime、FPGA timing 或资源结果。

数据来源：[XSim evidence](evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## ASIC 结果

| Profile | 固定 verified closure point | 结果成熟度 |
|---|---|---|
| `rdtc_v1_register_nangate45_550` (`register-expanded`) | 550 MHz OpenROAD P&R + same-run OpenRCX SPEF + PrimeTime；core area `421,120 um2`；route DRC `0`，antenna net/pin `0/0`；setup/hold WNS `+0.26/+0.04 ns` | 内部 reg-to-reg 实现与时序 verified |
| `rdtc_v1_sram_nangate45_333` (OpenRAM `sram-macro`) | 333 MHz 芯片级 P&R + same-run SPEF + internal PT；route DRC `0`，antenna net/pin `0/0`；setup/hold WNS `+0.57/+0.04 ns` | 实现链 verified；整体 profile 因 analytical macro model 与 macro DRC/LVS/PEX 未闭合而保持 partial；精确审核的 256-endpoint waiver 继续单独披露 |

频率是对应 profile 的固定已验证 closure point，不是 maximum frequency。结果属于 academic implementation evidence，不声明完整 top-level IO timing、OCV/MMMC、foundry signoff 或 silicon readiness。

ASIC evidence：[register-expanded](evidence/rdtc_v1_register_expanded.yaml) · [SRAM macro](evidence/rdtc_v1_sram_macro_333m.yaml)

## 快速检查

```bash
make rdtc_v1_public_preflight_defconfig
make showconfig
make -C ref_model/c test
make rtl-smoke
make multiengine-smoke
make fpga-wrapper-smoke
make showcase-assets-check
```

Questa/ModelSim 环境可继续运行 `make sim` 与 `make sim-full`。商业工具、PDK、library 和 macro 路径仅允许出现在 ignored `flows/local/`。

## 深入阅读

- [算法与 synthetic study](docs/zh-CN/algorithm.md)
- [单 Engine 与 Multi-Engine 架构](docs/zh-CN/architecture.md)
- [验证链与结果边界](docs/zh-CN/verification.md)
- [FPGA emulation 与 Zynq 集成](docs/zh-CN/fpga_implementation.md)
- [完整结果矩阵](docs/zh-CN/results.md)
- [ASIC 实现细节](docs/zh-CN/asic_implementation.md)
- [限制与明确未声明项](docs/zh-CN/limitations.md)
- [公开发行与完整性模型](docs/zh-CN/release_model.md)

当前 `main` 包含 RC3 之后的展示与说明更新；不可变 annotated tag `rdtc-v1-register550-rc3` 仍固定原始 RC3 发行，不因这些 post-RC3 文档变化而移动或重建。
