# 路线图

当前公开仓以两个 implementation profile 为稳定边界：

- `register-expanded`：15 nm DC 对比、45 nm OpenROAD/OpenRCX/PrimeTime academic physical profile；
- `sram-macro`：45 nm、两个 `64x128 1RW1R` 宏、约 333 MHz 的固定对照结果。

后续工作按 profile 独立推进：IO timing constraints、CDC/RDC、clock gating、scan DFT、LEC、统一电压角的 SRAM characterization、macro DRC/LVS/PEX，以及与工艺匹配的 signoff extraction technology。只有脚本、配置、实际工具输出和 evidence 完整后，阶段状态才会更新。

15/55 nm 不在本候选中承诺 post-route Fmax；只有获得授权且与节点/层栈匹配的寄生技术后，才恢复这些 profile 的物理实现。SRAM profile 不继续进行新的高频扫描，333 MHz 作为当前公开物理对照边界。
