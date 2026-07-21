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
| `register-expanded` | ICS55 H7CR RVT TT/1.2 V/25 C | DC-only | 400/600/800 MHz setup 均闭合；800 MHz WNS/TNS 0.00/0.00 ns，cell area 566,341.71 um2；600 MHz 留有 2/3 个 transition/capacitance 违例 | verified（800 MHz）/ partial（600 MHz） |
| `register-expanded` | ICS55/ECOS preview | 完整设计 400 MHz P&R 尝试 | floorplan 至 legalization 已完成；detailed route 在 1,058/4,761 个 box 后因 violation 增长和 OOM 保护停止；没有 routed handoff 或 STA | 未完成 |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | 双 `64x128 1RW1R` 宏；333 MHz P&R、同次 SPEF 与 PT 内部时序 | route DRC/antenna 为 0/0；PT setup/hold WNS +0.57/+0.04 ns，constraint violation 0 | 芯片级实现结果 verified；整体 profile 因 analytical SRAM 模型及 macro DRC/LVS/PEX 未闭合而保持 partial |

NanGate15 Liberty 使用 `1ps` 时间单位，DC profile 显式应用 `SDC_TIME_SCALE=1000.0`。最新 45 nm register-expanded 后端使用已闭合的 700 MHz DC netlist，在 550 MHz 进行物理实现；handoff netlist、SDC 与 SPEF 的 SHA256 在 evidence 中一致记录。PrimeTime setup/hold coverage 为 100%；1756 个未约束 max-delay endpoint 属于 internal-only profile 下的异步 reset pin。

SRAM-macro 的 333 MHz 结果已完成并验证芯片级 OpenROAD P&R、OpenRCX 同次 SPEF 及 PrimeTime 内部 setup/hold 时序；route DRC 和 antenna net/pin 均为 0，setup/hold WNS 为 +0.57/+0.04 ns。整体 SRAM profile 仍保持 `partial`，因为 OpenRAM 时序模型采用 analytical characterization，两个宏上共 256 个未使用 `dout0[127:0]` minimum-capacitance endpoint 采用精确审核 waiver，且 macro 级 DRC/LVS/PEX 尚未闭合。该 waiver 是 profile-specific、exact-set matched，不允许 missing 或 extra object，不是 setup/hold waiver，也不适用于功能性 read data。333 MHz 是当前 macro profile 的固定 verified closure point，不得扩大为 400 MHz claim。

ICS55 DC profile 使用 ICsprout55 public-preview `v1.10.100` 的 H7CR RVT Liberty，Liberty/DB SHA256 与输入 filelist、RTL manifest、SDC、各点 mapped netlist/输出 SDC 的身份均记录在 evidence 中。该结果只证明 ideal-clock internal reg-to-reg DC estimate；498 个顶层输入没有 clock-relative input delay，672 个顶层输出 endpoint 没有 max-delay 约束。

ICS55/ECOS 完整设计尝试不能与 DC-only profile 混淆。默认 detailed router 未完成，未生成 routed DEF/GDS/netlist、same-run SPEF/SDF 或 post-route timing。记录的停止是资源保护边界，不是物理实现或频率 claim。

## 结果解释

- `DC timing estimate` 只说明给定 Liberty、ideal clock 和 synthesis constraint 下的内部时序；
- `internal reg-to-reg post-route timing` 使用 routed netlist、matching SDC 和 same-run SPEF，但不覆盖未建模的系统 IO；
- `top-level IO timing closure` 与 `foundry signoff` 均未声明。

公开 evidence 位于 `evidence/`，运行条件和边界位于 `provenance/`。PDK、Liberty/DB、LEF/GDS、SPEF 和原始 EDA 工作目录不随仓库发布。
