# 算法

RDTC v1 对 I16Q16 复数样本的 I/Q 分量分别编码。ZERO_RICE 使用零预测器；DELTA_RICE 使用同一通道前一个样本作为预测器；有符号残差映射为非负整数后进行 Rice 编码。

Rice payload 由 unary quotient、分隔零和 MSB-first remainder 组成。码流按 header 中的 payload bit count 恢复，尾部 padding 不参与解码。
