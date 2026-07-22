# 算法

[English](../en/algorithm.md)

## 问题定义

RDTC v1 面向按 block 组织的 Range-Doppler 复数样本。一个公开基准 block 包含 `1024` 个 I16Q16 sample，即 `4096` byte 原始数据。目标是在不改变样本值的前提下减少 packet payload，同时让每个 packet 可以独立描述模式、长度、序号和解码参数。

![OFDM sensing and RDTC system context](../assets/system_context.svg)

## 三种编码路径

| 模式 | 预测与编码 | 使用边界 |
|---|---|---|
| `RAW_BYPASS` | 直接封装原始 I/Q sample | 可由 block 配置；支持 payload-cost fallback 的 encoder variant 也可在 Rice payload 无尺寸收益时回退 |
| `ZERO_RICE` | 以 0 为预测值，对 I/Q 分量分别编码 | 适合大量接近零的稀疏谱 |
| `DELTA_RICE` | 以同一通道前一个 sample 为预测值 | 利用相邻 sample 的相关性 |

`ZERO_RICE` 与 `DELTA_RICE` 由每个 block 的 descriptor 或 configuration 指定；内部 policy 只选择 `k`，不在 predictor mode 之间自动切换。ZERO/DELTA 路径先计算有符号残差，再使用 zig-zag 风格映射转换为非负整数。对候选 `k` 统计 block 级 prefix cost，选定参数后，由 lane-parallel bitpacker 生成 unary quotient、分隔零和 MSB-first remainder。Decoder 严格使用 header 中的 payload bit count，尾部 AXI padding 不参与解码。

在实现 RAW fallback 的 encoder variant 中，比较的是 payload 代价；packet 仍保留 `64`-byte header，以维持统一 framing、metadata 和错误检查。并非所有公开 wrapper path 都启用该 fallback，具体边界见[架构](architecture.md)。

## MATLAB synthetic study

算法选择使用受控 synthetic Range-Doppler-like 数据做趋势研究。该数据不是实测 radar capture，不用于建立现实场景的统计分布或最终压缩率上界。

![Synthetic compression ratio versus SNR](../assets/compression_vs_snr.svg)

| Synthetic SNR (dB) | -20 | -10 | 0 | 10 | 20 | 30 |
|---|---:|---:|---:|---:|---:|---:|
| ZERO_RICE ratio | 1.5817 | 1.8774 | 2.3470 | 3.0979 | 4.3915 | 7.5588 |
| DELTA_RICE ratio | 1.4997 | 1.7871 | 2.1852 | 2.8083 | 3.9669 | 6.1779 |

在记录的 synthetic cases 中，ZERO_RICE 与 DELTA_RICE 的重构误差为 0，所选 point-cloud comparison 的 match ratio 为 1。这里的 point-cloud comparison 是 MATLAB 结果检查，不表示仓库包含 PointCloud RTL。

公开 evidence 摘要与数据：[MATLAB evidence](../../evidence/rdtc_v1_matlab_algorithm_study.yaml) · [公开 CSV](../../evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## 从模型到码流

算法合同由以下不变量连接到 RTL：

- I/Q 样本必须 bit-exact 恢复；
- `selected_k`、payload bit count 和 packet byte count 必须与 reference model 一致；
- `tkeep` 与 `tlast` 必须精确标记最后一个 beat；
- backpressure 只能暂停传输，不能改变 packet 内容；
- malformed header、非法 mode 或越界长度必须被检测，而不是静默解码。

MATLAB 用于向量生成和算法观察；C reference model 是公开 bit-exact cross-check 的权威可执行入口。有限向量 PASS 不等于形式穷尽证明，完整边界见[验证](verification.md)与[限制](limitations.md)。
