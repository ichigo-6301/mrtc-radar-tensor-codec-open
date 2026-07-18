# 寄存器映射

控制寄存器包含 enable、soft reset、clear status、encoder/decoder enable 和 codec 配置。状态寄存器包含 busy、sticky done/error、字节计数、block 计数、错误码和 IRQ 状态。

`CAPABILITY` 仅声明当前实现的 RAW、ZERO_RICE 和 DELTA_RICE。RLE_RICE 与 PointCloud capability 均不在 RDTC v1 公开范围内。
