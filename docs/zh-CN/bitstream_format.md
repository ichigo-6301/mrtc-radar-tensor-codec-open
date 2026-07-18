# 码流格式

每个压缩 block 由 64-byte little-endian header 和 payload 组成。RAW_BYPASS payload 保持样本字节序；ZERO_RICE 和 DELTA_RICE payload 使用 header 指定的模式和 bit count。

压缩输出先发送 header，随后发送 payload，`tlast` 标记 block 结束。部分最后一拍的有效字节数由 `tuser[3:0]` 以 valid-byte-count-minus-one 编码。
