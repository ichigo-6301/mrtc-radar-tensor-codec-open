# 限制

- 不包含 PointCloud RTL、RLE_RICE RTL、AXI-MM 或 DMA descriptor integration；
- 不声明 board PASS、完整 top-level IO timing closure 或 silicon readiness；
- 不声明 CDC/RDC、clock-gating、DFT/ATPG、LEC、GLS/SDF 或 foundry signoff closure；
- `register-expanded` 只把 prefix buffer 映射为标准单元寄存器，不代表 SRAM macro PPA；
- 15 nm 和 55 nm 的 DC-only profile 只提供 ideal-clock internal reg-to-reg 综合边界。移除 SRAM 不等于存在匹配寄生技术，DC closure 也不等于 P&R closure，因此不从这些结果推导 post-route Fmax；
- 55 nm 使用 Apache-2.0 ICsprout55 public-preview PDK；公开仓只记录来源、版本、哈希和允许发布的数值摘要，不分发 PDK/Liberty/DB 或商业工具原始报告；
- 55 nm 的 600 MHz 点虽 setup 闭合，但留有 2 个 max-transition net 和 3 个 max-capacitance net，不能称为完全 constraint-clean；
- ICS55/ECOS 完整 RDTC 400 MHz 尝试已完成至 legalization，但默认 detailed routing 未完成。route 到达 1,058/4,761 个 box 时 violation 增长，并在已记录的内存保护阈值下停止；它不提供 routed netlist、GDS、SPEF、route-stage timing 或 P&R/Fmax claim；
- 45 nm register-expanded 的最新 550 MHz 结果是 internal reg-to-reg academic timing。它使用 700 MHz setup-closed DC mapped netlist、OpenRCX SPEF 和 PrimeTime；setup/hold coverage 为 100%，但 1756 个异步 reset pin 不在 max-delay coverage 内，也不覆盖完整 IO、reset recovery/removal、OCV/MMMC、macro DRC/LVS/PEX 或 foundry signoff；
- 45 nm `sram-macro` 的 333 MHz 结果使用两个 `64x128 1RW1R` OpenRAM macro。其 analytical characterization、256 个未使用 `dout0` endpoint 的 minimum-cap waiver 和宏视图验证边界必须保留；
- SRAM 333 MHz 结果不能扩大为 400 MHz；SRAM 宏面积和 register-expanded 面积不能在未说明物理容量与模型差异时直接比较；
- 公共结果中的 route DRC/antenna 计数属于指定 academic platform run，不等同于 foundry DRC/LVS；
- `DC timing estimate`、内部 post-route reg-to-reg timing 和完整 IO timing closure 是三个不同层次，不能互相替代；
- PDK、Liberty/DB、LEF/GDS、SPEF、许可证、绝对路径、原始 EDA 工作目录和未授权来源不随公开仓库发布。
