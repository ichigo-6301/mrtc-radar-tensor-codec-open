# 架构

顶层由 AXI4-Lite 控制块和 RDTC codec top 组成。编码路径完成样本解包、块缓存、header 生成、Rice 参数选择、码流打包或 raw bypass；解码路径完成 header 解析、格式检查、Rice 解码和原始样本输出。

当前存储结构保留既有异步读时序语义。同步 SRAM retiming 是独立的后续实现工作，不属于本版本的功能或时序 claim。
