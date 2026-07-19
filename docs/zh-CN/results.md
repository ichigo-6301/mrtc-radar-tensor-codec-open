# 已核验结果

## 功能验证

| Result | Profile | Status | Caveat |
|---|---|---|---|
| MATLAB/C/DPI-C/RTL legal-vector bit-exact agreement | RDTC v1 public release | verified | 有限向量与 regression 集，不是形式穷尽证明。 |
| Dual-AXIS128 wrapper VCS regression, 10 required cases | RDTC v1 public release | verified | 有限 wrapper regression，不是 coverage closure。 |

## 实现 Profile 矩阵

所有频率结果仅针对 `mrtc_rdtc_wb_wrapper` 的内部单时钟 reg-to-reg 约束，setup uncertainty 为 100 ps，未设置完整 top-level IO timing。

| Memory profile | Technology | Scope | Result | Status |
|---|---|---|---|---|
| `register-expanded` | NanGate15 TT/0.8 V/25 C | DC-only | 400/600/800 MHz 均闭合；800 MHz WNS +0.22945 ns，cell area 99,064.13 um2 | verified |
| `register-expanded` | Nangate45 TT/1.1 V/25 C | DC matrix | 400/600/700 MHz 闭合；700 MHz WNS/TNS 0.00/0.00 ns；800 MHz WNS/TNS -0.14/-858.86 ns | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 400 MHz | route DRC 0，antenna net/pin 0/0，area 418,007 um2，utilization 31.2108%；PT setup/hold WNS +0.80/+0.04 ns，constraint violation 0 | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 550 MHz | 使用 700 MHz DC mapped netlist；route DRC 0，antenna net/pin 0/0，area 421,120 um2，utilization 31.4432%；PT setup/hold WNS +0.26/+0.04 ns，constraint violation 0 | verified |
| `register-expanded` | ICsprout55 | DC-only | 结果保留在私有 delivery，公开授权确认前不发布指标 | private/not_claimed |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | 2 x `64x128 1RW1R`; P&R + PT at 333 MHz | route 与 same-run SPEF 完成；PT setup/hold WNS +0.57/+0.04 ns，constraint violation 0 | partial |

NanGate15 Liberty 使用 `1ps` 时间单位，DC profile 显式应用 `SDC_TIME_SCALE=1000.0`。最新 45 nm register-expanded 后端使用已闭合的 700 MHz DC netlist，在 550 MHz 进行物理实现；handoff netlist、SDC 与 SPEF 的 SHA256 在 evidence 中一致记录。PrimeTime setup/hold coverage 为 100%；1756 个未约束 max-delay endpoint 属于 internal-only profile 下的异步 reset pin。

SRAM-macro 的 333 MHz 结果保留 OpenRAM analytical characterization、256 个未使用 `dout0` endpoint 的 minimum-capacitance waiver，以及 macro DRC/LVS/PEX 未闭合的限制。它不能扩大为 400 MHz claim，也不能在未解释 SRAM area 模型差异时与 register-expanded 面积直接比较。

## 结果解释

- `DC timing estimate` 只说明给定 Liberty、ideal clock 和 synthesis constraint 下的内部时序；
- `internal reg-to-reg post-route timing` 使用 routed netlist、matching SDC 和 same-run SPEF，但不覆盖未建模的系统 IO；
- `top-level IO timing closure` 与 `foundry signoff` 均未声明。

公开 evidence 位于 `evidence/`，运行条件和边界位于 `provenance/`。PDK、Liberty/DB、LEF/GDS、SPEF 和原始 EDA 工作目录不随仓库发布。
