# ASIC 实现

公开 ASIC 内容包括历史 wrapper 的 `register-expanded`/`sram-macro` 配对，以及独立的 bounded Direct-AXIS 配对。每一对都保持自己的 RTL 接口与 packet contract，仅替换 bulk-memory leaf binding。历史 Nangate45 profile 使用下文所述的 configured `1200 x 1200 um` die 与 `1159.72 x 1155.20 um` core；Direct profile 根据自身综合面积和宏几何使用独立 floorplan。Configured geometry 不是未发布 GDS 的事后测量。

## 同约束架构 A/B（DC-only）

Buffered 与 Direct-AXIS wrapper 使用 Design Compiler `O-2018.06-SP1`、同一 SHA256 绑定的 Nangate45 typical DB、统一 315 MHz 同步边界 SDC、双 Engine、全寄存器存储、`compile_ultra`、一次 design-rule repair 且禁止 retime。已发布四点在 `as_run_flow_commit=db2660c` 下运行，加载该版本要求的本地 `RDTC_DC_SETUP`，随后由 run script 校验实际 target DB 哈希。公开复现 runner 在证据采集后继续加固，现直接由审计 DB 绑定 target/link library，不执行本地 setup Tcl；四点未在这一新版 setup-free runner 下重跑，因此既有指标不附带 setup-free 声明。唯一预期架构差异是 Direct 删除 DDR feeder 与 per-Engine payload commit store，使审计 bulk storage 从 `180,224` 降至 `32,768 bit`。

两侧均以零 setup violating path 闭合。Buffered 为 `1,529,495.20 um2 / 786,342 cells`，Direct 为 `420,208.44 um2 / 220,298 cells`，cell area 与 cell count 分别减少 `72.53%` 和 `71.98%`。Buffered 的 feeder 与 payload-commit 层次合计 `1,124,835.52 um2`，占顶层面积 `73.54%`；两侧 Engine 汇总面积仅相差 `0.34%`。这将收益归因到 wrapper 存储职责重构，而不是更换 Rice 数据通路或综合设置。该比较分类为 `PASS_DC_ONLY`，不代表 SRAM 宏面积、布线后面积、功耗、Fmax 或 foundry signoff。证据：[bounded buffered versus Direct DC A/B](../../evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml)。

## Register-expanded

`register-expanded` 不绑定 SRAM leaf，prefix buffer 由标准单元寄存器实现，因此 SRAM macro count 为 0。公开主结果使用 NanGate15 与 Nangate45 DC 矩阵；Nangate45 另增加 700 MHz 点。NanGate15 的 Liberty 时间单位为 1 ps，flow 通过 `SDC_TIME_SCALE=1000.0` 转换到 ns；45 nm 700 MHz 闭合而 800 MHz 未闭合，所以 700 MHz mapped netlist 被选作最新 physical handoff。

公开 45 nm physical profile 使用 OpenROAD/OpenRCX 和 PrimeTime：以 700 MHz DC netlist 为输入，在 550 MHz 重新施加 P&R/STA 约束，完成 placement、CTS、route 和 SPEF。route DRC 与 antenna net/pin 均为 0，PrimeTime setup/hold WNS 为 +0.26/+0.04 ns，setup/hold coverage 为 100%。1756 个异步 reset pin 不在 max-delay coverage 内。该结果是内部 reg-to-reg academic timing，不是完整 IO、reset recovery/removal、OCV/MMMC 或 foundry signoff。

## SRAM-macro

`sram-macro` 在双 engine 顶层实例化两个 `64x128 1RW1R` OpenRAM macro，并通过 wrapper 保持一拍读延迟、现有 AXI 协议和地址行为。333 MHz 是固定 verified closure point：芯片级 OpenROAD P&R 已完成，route DRC 与 antenna net/pin 均为 0/0，同一次 run 产生 routed handoff 与 OpenRCX SPEF，PrimeTime 读取匹配的 netlist、SDC 与 SPEF。setup/hold WNS/TNS 为 +0.57/+0.04 ns 与 0/0，constraint violation 为 0。

### Academic 范围与结果解释

芯片级实现链和已测得的内部 post-route timing 是 verified 结果。本项目为学习和工程展示而使用 academic Nangate45/OpenRAM 平台；没有适用于生产的 foundry PDK 或 macro signoff 包，因此不声明 production PDK、macro DRC/LVS/PEX 或 silicon readiness。OpenRAM timing model 为 analytical characterization，但这不改变匹配 routed netlist、SDC 与 same-run SPEF 的 PrimeTime setup/hold 结果。minimum-capacitance waiver 是针对两个宏上共 256 个未使用 `dout0[127:0]` endpoint 的 profile-specific、exact-set 审核对象；不允许 missing 或 extra object，不是 setup/hold waiver，也不适用于功能性 read data。

route-tool DRC 0 在 academic platform 与 macro abstract view 范围内验证了顶层 routed implementation；它不验证 OpenRAM macro 的晶体管级内部。完整 IO timing、OCV/MMMC、foundry signoff 和 silicon readiness 均不声明，因为它们不属于本项目可获得的 academic PDK 环境。该频率由 macro-integrated implementation 与现有 analytical timing model 共同约束；不声明 400 MHz 因果失败，也不提出 400 MHz macro-profile claim。

## Bounded Direct-AXIS Profiles

Direct physical top 为 [`mrtc_rdtc_bounded_axis_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv)。两种 binding 都使用双 Engine、每 Engine 四个 `32x128` 1RW way、总计 `32,768 bit` bulk ring，以及一个小型 16-beat registered output queue；均不包含 DDR feeder 或 payload commit store。

### Register-Expanded 600 MHz

全寄存器 profile 将 8 个 way 全部展开为标准单元，SRAM macro count 为 0。Design Compiler 在禁止 retime 的条件下闭合 630 MHz mapping target，随后 mapped netlist 在固定 600 MHz physical target 完成 OpenROAD route 与 same-run OpenRCX。Route DRC、antenna net/pin 与 unrouted count 均为 0。PrimeTime 读取匹配 routed netlist、SDC 和 SPEF，setup/hold WNS 为 `+0.03/+0.02 ns`，constraint violation 为 0，setup/hold coverage 均为 `50972/50972`。Final standard-cell area 为 `476,320 um2`。这是 fixed academic internal closure point，不是 Fmax。

### Eight-Macro SRAM 300 MHz

全 SRAM profile 精确绑定 8 个 `32x128 1RW` OpenRAM 宏，每 Engine 四个；控制与 output queue 仍使用寄存器。300 MHz 下 OpenROAD route 完成，DRC、antenna 与 unrouted count 均为 0；same-run OpenRCX 与匹配 PrimeTime 的 setup/hold WNS 为 `+0.16/+0.02 ns`，minimum-period、pulse-width、max-transition 和 max-capacitance violation 均为 0，setup/hold coverage 均为 `18276/18276`。

完整表征的 WPR2 宏 governing period 为 `2.656 ns`，minimum high/low pulse 为 `1.328 ns`；WPR1 为 `2.500/1.250 ns`，WPR4 不受 pinned OpenRAM generator 支持。它们都不满足 600 MHz 的 `1.666667 ns` period 与 `0.833333 ns` pulse 门禁，因此 SRAM 600 MHz 为 `MACRO_MODEL_BLOCKED`，不作为可执行公开闭合配置。

300 MHz SRAM point 的顶层 P&R 与内部 post-route timing 均为 verified；overall macro maturity 仍为 partial，因为 timing model 属于 academic analytical characterization，晶体管级 macro DRC/LVS/PEX 未闭合。物理结果也不会消除 `277 > 256 cycles/block` scheduler 限制。

证据：[bounded Direct ASIC summary](../../evidence/rdtc_v1_bounded_direct_asic.yaml)。

## Flow Contract

标准流程为：

```text
RTL/C verification
-> profile-specific DC synthesis
-> mapped-netlist identity check
-> OpenROAD placement/CTS/route (45 nm register-expanded or SRAM profile)
-> OpenRCX SPEF
-> PrimeTime setup/hold checks
```

DC、P&R 和 STA 必须记录 profile、source commit、clock period、PVT、工具版本、RC mode、netlist/SDC/SPEF hash 和 caveat。使用不同综合与物理频率时，DC period、P&R period 和 STA period 必须分别记录并由工具对象校验；低频 P&R 不等于 DC guardband。

商业工具、PDK、library、macro 和生成视图路径只允许出现在 ignored `flows/local/`。公开仓只提供通用 wrapper、配置契约、脚本入口、双语文档和允许公开的 evidence 摘要。
