# 功能验证

[English](../en/verification.md)

## 验证链

RDTC 使用逐层收敛的验证链，而不是只依赖单一 RTL testbench：

| 层次 | 检查内容 | 公开成熟度 |
|---|---|---|
| MATLAB | synthetic 数据、模式趋势、向量生成、无损重构观察 | recorded synthetic study |
| C reference | packet、payload、`selected_k` 与解码结果的 bit-exact oracle | verified for published vectors |
| DPI-C / SystemVerilog | reference model 与 RTL 的逐 block 比较 | verified finite regression |
| RTL protocol | AXI backpressure、`tkeep/tlast`、多 block、loopback、malformed stream | verified finite regression |
| Multi-Engine RTL | 分发、独立 packet buffer、packet-locked arbitration、packet identity | verified finite workload |
| FPGA emulation simulation | 固定 commit 的单 active-input AXIS32 wrapper XSim | `3/3` cases verified |
| 历史 Zynq build layers | trial-copy compatibility RTL elaboration 与 SDK/ELF build | 仅对应 build layer verified |

公开结果适用于记录的 source/configuration/vector 身份，不是形式穷尽证明、functional coverage closure 或所有参数组合的证明。

## Bit-exact 与协议检查

公开 legal-vector 覆盖 `RAW_BYPASS`、`ZERO_RICE`、`DELTA_RICE`、多 block、AXI packing、encoder-decoder loopback、输入间隙、随机输出 backpressure 与 malformed-stream 负向条件。核心 acceptance 条件包括：

- 解码后的 I/Q sample 与 reference 完全一致；
- `selected_k`、payload bit/byte count 和 compression choice 一致；
- 最后一个 beat 的 `tkeep/tlast` 正确；
- stall 前后 packet 内容和边界不变；
- 非法 header、mode 或长度能够产生明确错误状态。

MATLAB 脚本用于向量和算法 study；公开 C cross-check 的权威入口是：

```bash
make -C ref_model/c test
```

MATLAB 页面中的 point-cloud comparison 不是 PointCloud RTL，也不是替代 C executable cross-check 的证据。

## Multi-Engine Regression

历史 fixed-commit 256-block prefix workload 检查 payload byte-exact、`selected_k`、压缩比、packet 完整性与无 beat interleaving。该记录把一个 beam 定义为 256 个 block，`beam/s` 由未舍入的 beam 总周期计算。性能结果为：

| Engines | Cycles/block | Scaling efficiency | Beam/s at assumed 200 MHz |
|---:|---:|---:|---:|
| 1 | 785 | baseline | - |
| 2 | 397.52 | 0.987368 | 1965.3022 |
| 4 | 197.41 | 0.994115 | 3957.4642 |

这些数字是 simulated DDR model 下的 RTL simulation projection，不是 FPGA 时序或板上吞吐。当前公开 adaptation 另有 2-Engine、2-block correctness smoke，以及 packet-buffer overlength fail-stop/reset recovery、双 slot 同周期 queue push/pop、单 slot turnover、completion 同周期状态清零和 `OUTPUT_IN_ORDER=1` fail-fast 边界测试，但不重算该性能矩阵。Arbiter 保证 packet atomic、无 beat interleaving，但完成顺序不保证。现有记录验证 block identity，没有直接观察到一次实际乱序事件；metadata 允许软件按 Frame/Block index 重建，不声明软件 reorder PASS。

公开 evidence 摘要与数据：[Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [公开 CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## FPGA Emulation

**FPGA emulation verified.** 在固定 source commit `43deb9f` 上，Vivado 2018.3 XSim 中的 AXIS32 wrapper `3/3` block-level cases 通过：ZERO_RICE、DELTA_RICE，以及 mixed two-block。检查覆盖真实 encoder path、decoder golden comparison、宽度转换、可变长 packet、`tkeep/tlast`、输入 gap 与输出 backpressure。当前公开 adaptation 另有 Icarus smoke，不构成新的 Vivado 结果。

该 AXIS32 testbench 只驱动 `s0`，因此不能作为双 Engine scaling 或双输入并发验证；双 Engine / Multi-Engine claim 来自独立 RTL regression。历史 Zynq-7000 trial copy 使用经过 Vivado 2018.3 兼容处理的 copied RTL 完成 `synth_design -rtl`，并完成 SDK/ELF build。当前公开 RTL 保留 `parameter string`，不声明可直接在 Vivado 2018.3 elaboration；matching bitstream、板上 console PASS、MCDMA/DDR/cache runtime、FPGA timing 与资源结果也均未声明。

公开 evidence 摘要与数据：[XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

![Zynq FPGA emulation evidence layers](../assets/zynq_emulation_path.svg)

## 公开检查入口

```bash
make rdtc_v1_public_preflight_defconfig
make showconfig
make -C ref_model/c test
make rtl-smoke
make multiengine-smoke
make fpga-wrapper-smoke
make showcase-assets-check
```

在配置完整的 Questa/ModelSim 环境中，可运行：

```bash
make sim
make sim-full
```

工具存在、脚本可加载或工程可 elaboration 只证明对应层次，不自动提升为 implementation、timing、bitstream 或 board workload PASS。完整未声明项见[限制](limitations.md)。
