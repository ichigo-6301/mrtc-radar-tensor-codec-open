# ASIC 实现

公开 ASIC 内容按两个独立 profile 组织：`register-expanded` 与 `sram-macro`。两者共享 RDTC v1 RTL、接口、AXI 行为、寄存器映射和码流；区别仅在 prefix buffer 的物理绑定。

## Register-expanded

`register-expanded` 不绑定 SRAM leaf，prefix buffer 由标准单元寄存器实现，因此 SRAM macro count 为 0。NanGate15、Nangate45 和 ICsprout55 的 DC 矩阵均使用 400/600/800 MHz、100 ps setup uncertainty 的内部单时钟约束。NanGate15 的 Liberty 时间单位为 1 ps，flow 通过 `SDC_TIME_SCALE=1000.0` 转换到 ns；45 nm 800 MHz 未闭合，所以 600 MHz mapped netlist 被选作物理 handoff。

公开 45 nm physical profile 使用 OpenROAD/OpenRCX 和 PrimeTime：以 600 MHz DC netlist 为输入，在 400 MHz 重新施加 P&R/STA 约束，完成 placement、CTS、route 和 SPEF。route DRC 与 antenna net/pin 均为 0，PrimeTime setup/hold WNS 为 +0.80/+0.04 ns。该结果是内部 reg-to-reg academic timing，不是完整 IO、OCV/MMMC 或 foundry signoff。

15 nm 只发布 DC 对比结果；55 nm 矩阵保留在私有 delivery，直到库许可证和公开授权确认。移除 SRAM 不会自动提供匹配的寄生技术，因此 15/55 nm 不声明 post-route Fmax。

## SRAM-macro

`sram-macro` 在双 engine 顶层实例化两个 `64x128 1RW1R` OpenRAM macro，并通过 wrapper 保持一拍读延迟、现有 AXI 协议和地址行为。公开固定结果为约 333 MHz：同一次 OpenROAD/OpenRCX run 产生 route、SPEF 和 handoff，PrimeTime 读取相同 netlist、SDC 和 SPEF，setup/hold WNS 为 +0.57/+0.04 ns。

该 profile 整体保持 `partial`，因为宏使用 analytical characterization，保留 256 个未使用 `dout0` endpoint 的 minimum-capacitance waiver，且没有 macro DRC/LVS/PEX、完整 IO timing、OCV/MMMC 或 foundry signoff。SRAM profile 的频率不能扩大为 400 MHz；SRAM 宏面积也不能和 register-expanded 结果直接比较而不说明容量与物理模型差异。

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
