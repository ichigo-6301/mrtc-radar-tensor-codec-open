# 路线图

当前公开仓记录四个相互独立的 academic physical comparison boundary：

- 历史 `register-expanded`：15 nm DC 对比与 Nangate45 550 MHz 固定 OpenROAD/OpenRCX/PrimeTime 点；
- 历史 `sram-macro`：两个 `64x128 1RW1R` 宏与 Nangate45/OpenRAM 333 MHz 固定点；
- bounded Direct `register-expanded`：双 Engine、`32,768 bit` 展开 way-ring 与 Nangate45 600 MHz 固定点；
- bounded Direct `sram-macro`：8 个 `32x128 1RW` 宏与 Nangate45/OpenRAM 300 MHz 固定点。

Direct profile 继续保持 opt-in，`mrtc_top` 仍是 canonical integration top。下一项架构工作是把有序 packet service 从约 `277 cycles/block` 降到不高于零间隔输入的 `256-cycle` 周期，或验证新的 Engine/bank 调度几何。在此之前，即使有限两 block regression 与固定 FPGA/ASIC timing point 已通过，也不声明持续零停顿。

后续实现工作按 profile 独立推进：完整 IO timing、CDC/RDC、gated P&R/CTS power、scan DFT、LEC、macro DRC/LVS/PEX、OCV/MMMC，以及与节点和层栈匹配的 signoff extraction。Direct SRAM 600 MHz 为 `MACRO_MODEL_BLOCKED`；只有获得合法且完整表征的新宏组织后才能重启，而不是放宽时钟检查。FPGA 后续必须生成 bitstream 并执行板级 workload 才能形成 board claim。只有脚本、配置、实际工具输出和 evidence 完整后才更新阶段状态，所有已发布固定点都不是 Fmax claim。
