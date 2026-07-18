# 概览

RDTC v1 是 MRTC 框架中的流式无损压缩 IP，面向按块组织的 Range-Doppler 复数样本。当前发布范围仅包括 RAW_BYPASS、ZERO_RICE 和 DELTA_RICE 编解码、流接口、控制状态和已发布的验证资产。

输入来自雷达感知数据通路，输出可连接存储、传输或后级处理模块。RDTC 不定义上游雷达处理算法，也不包含 PointCloud、DMA descriptor 或 AXI-MM 系统集成。
