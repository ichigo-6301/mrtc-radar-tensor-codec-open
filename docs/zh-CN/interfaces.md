# 接口

RDTC v1 使用 128-bit AXI-Stream 原始输入和压缩输出。每拍包含四个 I16Q16 complex sample，`tlast` 标记 block 边界。压缩输入和解码原始输出遵循相同的 block 级 `tlast` 与尾拍有效字节规则。

AXI4-Lite 提供 enable、soft reset、状态清除、codec 配置、tensor metadata、计数器、IRQ 和 capability 访问。接口信号语义以当前 RTL 与公开 register map 为准。
