# 已核验结果

[English](../en/results.md)

## 算法与功能验证

| Result | Profile | Status | Caveat |
|---|---|---|---|
| MATLAB synthetic ZERO/DELTA lossless reconstruction | 受控 synthetic study | verified for recorded cases | 不是实测 radar dataset；不表示 PointCloud RTL。 |
| MATLAB/C/DPI-C/RTL legal-vector bit-exact agreement | RDTC v1 public release | verified | 有限向量与 regression 集，不是形式穷尽证明。 |
| Dual-AXIS128 wrapper VCS regression, 10 required cases | RDTC v1 public release | verified | 有限 wrapper regression，不是 coverage closure。 |

Synthetic SNR 从 `-20` 到 `30 dB` 时，ZERO_RICE compression ratio 为 `1.5817 / 1.8774 / 2.3470 / 3.0979 / 4.3915 / 7.5588`，DELTA_RICE 为 `1.4997 / 1.7871 / 2.1852 / 2.8083 / 3.9669 / 6.1779`。完整解释见[算法](algorithm.md)。

![Synthetic compression ratio versus SNR](../assets/compression_vs_snr.svg)

来源：[MATLAB evidence](../../evidence/rdtc_v1_matlab_algorithm_study.yaml) · [公开 CSV](../../evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## Multi-Engine RTL Scaling

历史 fixed-commit 256-block prefix workload 使用 simulated DDR feeder，检查 payload byte-exact、`selected_k`、compression ratio、packet 完整性和无 beat interleaving。该记录把一个 beam 定义为 256 个 block；`beam/s` 由公开 CSV 中未舍入的 `estimated_cycles_per_beam` 计算，不能仅由表中两位小数的 cycles/block 精确反推。

| Engines | Cycles/block | Scaling efficiency | Beam/s at assumed 200 MHz |
|---:|---:|---:|---:|
| 1 | 785 | baseline | - |
| 2 | 397.52 | 0.987368 | 1965.3022 |
| 4 | 197.41 | 0.994115 | 3957.4642 |

![Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

这些是 RTL simulation projection，不是 FPGA timing closure、implemented clock 或板级 DDR 吞吐。当前公开 adaptation 另有 2-Engine、2-block correctness smoke，但不重算该性能矩阵。输出 packet 保持 atomic，不同 packet 的 beat 不交织；完成顺序不保证。Frame/Block metadata 支持软件 indexed reconstruction，但没有软件 reorder PASS claim，记录场景也没有直接证明一次实际乱序事件。

来源：[Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [公开 CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## FPGA Emulation

| Scope | Result | Status | Boundary |
|---|---|---|---|
| 固定 commit 的 Vivado 2018.3 AXIS32 wrapper XSim | ZERO_RICE、DELTA_RICE、mixed two-block，`3/3` PASS | FPGA emulation verified | 当前公开 adaptation 另有 Icarus smoke；XSim 只驱动 `s0`，不作为双 Engine scaling 证据 |
| 历史 Zynq-7000 trial copy | compatibility-copied RTL elaboration 与 SDK/ELF build | verified at trial-build layer | 当前公开 RTL 不声明直接 Vivado 2018.3 elaboration；不声明 matching bitstream 或 board execution |
| Bitstream/board/MCDMA runtime/timing/resources | 未提供匹配结果 | not claimed | 不从 simulation 或 build 状态推导 |

FPGA XSim 覆盖真实 encoder path、decoder golden comparison、width conversion、可变长 packet、`tkeep/tlast`、输入 gap 和输出 backpressure。双 Engine 分发与仲裁来自独立 RTL regression，不与该单输入 XSim scope 合并。

来源：[XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## 实现 Profile 矩阵

所有频率结果仅针对 `mrtc_rdtc_wb_wrapper` 的内部单时钟 reg-to-reg 约束，setup uncertainty 为 100 ps，未设置完整 top-level IO timing。

| Memory profile | Technology | Scope | Result | Status |
|---|---|---|---|---|
| `register-expanded` | NanGate15 TT/0.8 V/25 C | DC-only | 400/600/800 MHz 均闭合；800 MHz WNS +0.22945 ns，cell area 99,064.13 um2 | verified |
| `register-expanded` | Nangate45 TT/1.1 V/25 C | DC matrix | 400/600/700 MHz 闭合；700 MHz WNS/TNS 0.00/0.00 ns；800 MHz WNS/TNS -0.14/-858.86 ns | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 400 MHz | route DRC 0，antenna net/pin 0/0，area 418,007 um2，utilization 31.2108%；PT setup/hold WNS +0.80/+0.04 ns，constraint violation 0 | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | fixed verified P&R + PT closure point at 550 MHz | 使用 700 MHz DC mapped netlist；route DRC 0，antenna net/pin 0/0，area 421,120 um2，utilization 31.4432%；PT setup/hold WNS +0.26/+0.04 ns，constraint violation 0 | verified |
| `register-expanded` | ICS55 H7CR RVT TT/1.2 V/25 C | DC-only | 400/600/800 MHz setup 均闭合；800 MHz WNS/TNS 0.00/0.00 ns，cell area 566,341.71 um2；600 MHz 留有 2/3 个 transition/capacitance 违例 | verified（800 MHz）/ partial（600 MHz） |
| `register-expanded` | ICS55/ECOS preview | 完整设计 400 MHz P&R 尝试 | floorplan 至 legalization 已完成；detailed route 在 1,058/4,761 个 box 后因 violation 增长和 OOM 保护停止；没有 routed handoff 或 STA | 未完成 |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | 双 `64x128 1RW1R` 宏；fixed verified 333 MHz P&R、同次 SPEF 与 PT 内部时序 closure point | route DRC 为 0，antenna net/pin 为 0/0；PT setup/hold WNS +0.57/+0.04 ns，constraint violation 0 | 芯片级实现结果 verified；整体 profile 因 analytical SRAM 模型及 macro DRC/LVS/PEX 未闭合而保持 partial |

NanGate15 Liberty 使用 `1ps` 时间单位，DC profile 显式应用 `SDC_TIME_SCALE=1000.0`。最新 45 nm register-expanded 后端使用已闭合的 700 MHz DC netlist，在 550 MHz 进行物理实现；handoff netlist、SDC 与 SPEF 的 SHA256 在 evidence 中一致记录。PrimeTime setup/hold coverage 为 100%；1756 个未约束 max-delay endpoint 属于 internal-only profile 下的异步 reset pin。

SRAM-macro 的 333 MHz 结果已完成并验证芯片级 OpenROAD P&R、OpenRCX 同次 SPEF 及 PrimeTime 内部 setup/hold 时序；route DRC 和 antenna net/pin 均为 0，setup/hold WNS 为 +0.57/+0.04 ns。整体 SRAM profile 仍保持 `partial`，因为 OpenRAM 时序模型采用 analytical characterization，且 macro 级 DRC/LVS/PEX 尚未闭合。两个宏上共 256 个未使用 `dout0[127:0]` minimum-capacitance endpoint 采用精确审核 waiver；该 waiver 必须披露，但不是 profile partial 的原因。它是 profile-specific、exact-set matched，不允许 missing 或 extra object，不是 blanket capacitance、setup/hold waiver，也不适用于功能性 read data。333 MHz 是当前 macro profile 的固定 verified closure point，不得扩大为 400 MHz claim。

ICS55 DC profile 使用 ICsprout55 public-preview `v1.10.100` 的 H7CR RVT Liberty，Liberty/DB SHA256 与输入 filelist、RTL manifest、SDC、各点 mapped netlist/输出 SDC 的身份均记录在 evidence 中。该结果只证明 ideal-clock internal reg-to-reg DC estimate；498 个顶层输入没有 clock-relative input delay，672 个顶层输出 endpoint 没有 max-delay 约束。

ICS55/ECOS 完整设计尝试不能与 DC-only profile 混淆。默认 detailed router 未完成，未生成 routed DEF/GDS/netlist、same-run SPEF/SDF 或 post-route timing。记录的停止是资源保护边界，不是物理实现或频率 claim。

## 结果解释

- `verified closure point` 只说明该明确配置与频率完成记录的 checks，不等于 maximum frequency；
- `DC timing estimate` 只说明给定 Liberty、ideal clock 和 synthesis constraint 下的内部时序；
- `internal reg-to-reg post-route timing` 使用 routed netlist、matching SDC 和 same-run SPEF，但不覆盖未建模的系统 IO；
- route-tool DRC 0 与 foundry DRC/LVS/PEX 是不同 scope；
- `top-level IO timing closure`、`OCV/MMMC` 与 `foundry signoff` 均未声明。

ASIC evidence：[register-expanded](../../evidence/rdtc_v1_register_expanded.yaml) · [SRAM macro](../../evidence/rdtc_v1_sram_macro_333m.yaml) · [ICS55 DC](../../evidence/rdtc_v1_register_ics55_rvt_dc.yaml)

公开 evidence 位于 `evidence/`，运行条件和边界位于 `provenance/`。PDK、Liberty/DB、LEF/GDS、SPEF 和原始 EDA 工作目录不随仓库发布。
