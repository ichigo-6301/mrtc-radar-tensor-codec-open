# ASIC 实现

公开 ASIC 内容按两个独立 profile 组织：`register-expanded` 与 `sram-macro`。两者共享 RDTC v1 RTL、接口、AXI 行为、寄存器映射和码流；区别仅在 prefix buffer 的物理绑定。两个 Nangate45 physical profile 使用相同的 configured floorplan：die 为 `1200 x 1200 um`（`1.4400 mm2`），core 为 `1159.72 x 1155.20 um`（`1.3397 mm2`）。这些是公开 OpenROAD configuration 的几何约束，不是未发布 GDS 的事后测量。

## Register-expanded

`register-expanded` 不绑定 SRAM leaf，prefix buffer 由标准单元寄存器实现，因此 SRAM macro count 为 0。公开主结果使用 NanGate15 与 Nangate45 DC 矩阵；Nangate45 另增加 700 MHz 点。NanGate15 的 Liberty 时间单位为 1 ps，flow 通过 `SDC_TIME_SCALE=1000.0` 转换到 ns；45 nm 700 MHz 闭合而 800 MHz 未闭合，所以 700 MHz mapped netlist 被选作最新 physical handoff。

公开 45 nm physical profile 使用 OpenROAD/OpenRCX 和 PrimeTime：以 700 MHz DC netlist 为输入，在 550 MHz 重新施加 P&R/STA 约束，完成 placement、CTS、route 和 SPEF。route DRC 与 antenna net/pin 均为 0，PrimeTime setup/hold WNS 为 +0.26/+0.04 ns，setup/hold coverage 为 100%。1756 个异步 reset pin 不在 max-delay coverage 内。该结果是内部 reg-to-reg academic timing，不是完整 IO、reset recovery/removal、OCV/MMMC 或 foundry signoff。

## SRAM-macro

`sram-macro` 在双 engine 顶层实例化两个 `64x128 1RW1R` OpenRAM macro，并通过 wrapper 保持一拍读延迟、现有 AXI 协议和地址行为。333 MHz 是固定 verified closure point：芯片级 OpenROAD P&R 已完成，route DRC 与 antenna net/pin 均为 0/0，同一次 run 产生 routed handoff 与 OpenRCX SPEF，PrimeTime 读取匹配的 netlist、SDC 与 SPEF。setup/hold WNS/TNS 为 +0.57/+0.04 ns 与 0/0，constraint violation 为 0。

### Academic 范围与结果解释

芯片级实现链和已测得的内部 post-route timing 是 verified 结果。本项目为学习和工程展示而使用 academic Nangate45/OpenRAM 平台；没有适用于生产的 foundry PDK 或 macro signoff 包，因此不声明 production PDK、macro DRC/LVS/PEX 或 silicon readiness。OpenRAM timing model 为 analytical characterization，但这不改变匹配 routed netlist、SDC 与 same-run SPEF 的 PrimeTime setup/hold 结果。minimum-capacitance waiver 是针对两个宏上共 256 个未使用 `dout0[127:0]` endpoint 的 profile-specific、exact-set 审核对象；不允许 missing 或 extra object，不是 setup/hold waiver，也不适用于功能性 read data。

route-tool DRC 0 在 academic platform 与 macro abstract view 范围内验证了顶层 routed implementation；它不验证 OpenRAM macro 的晶体管级内部。完整 IO timing、OCV/MMMC、foundry signoff 和 silicon readiness 均不声明，因为它们不属于本项目可获得的 academic PDK 环境。该频率由 macro-integrated implementation 与现有 analytical timing model 共同约束；不声明 400 MHz 因果失败，也不提出 400 MHz macro-profile claim。

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
