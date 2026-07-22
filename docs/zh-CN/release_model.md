# 发行模型

[English](../en/release_model.md)

## RC3 与当前 main

`rdtc-v1-register550-rc3` 是不可变 annotated public release tag，固定 RC3 的源码、公开 evidence、provenance 与 checksum 身份。当前 `main` 是 post-RC3 开发线，可以增加展示、说明和后续受审内容，但不得移动、删除、重建或让 RC3 tag 指向新的 main。

因此应区分：

- **RC3 release**：不可变、可独立 checkout 和验证的历史发行；
- **current main**：包含 RC3 之后的 presentation/clarification 更新，不自动成为新 release；
- **future release**：只有经独立授权、审核与新 tag 才成立。

## 分层来源

RDTC 公开发行将功能源码、私有交付元数据和公开包装明确分层：

- `rtl_source_commit` 固定 RTL、reference model、MATLAB 资产和公开接口的功能来源；
- `private_delivery_commit` 固定 claim/evidence 审阅和白名单导出配置；
- public packaging commit 包含公开仓结构、CI、文档和复现脚本；
- annotated public release tag 是最终不可变发行身份，通过 `git rev-list -n 1 <tag>` 解析对应 commit。

Manifest 不在同一 commit 内嵌自指的最终 public commit SHA；tag 提供最终 release identity。当前 main 的文档可以链接并解释既有 evidence，但不能仅凭文字引入新的 `verified` 技术事实。

## Result 与 Profile 成熟度

成熟度必须按维度解释：

- `verified` result 表示记录的 configuration、工具、输入身份和 evidence 支持该明确结果；
- `partial` 必须说明 partial 的对象，不能把已完成的 P&R 或 timing stage 模糊成 partial；
- `experimental` 是不支持公开 verified claim 的探索配置；
- `planned` 只表示路线图；
- `not_claimed` 表示材料或执行不足，不能由相邻 stage 推导。

SRAM 333 MHz 是典型例子：chip-level P&R、routed handoff、same-run OpenRCX SPEF 与内部 PT setup/hold result 均为 verified；macro timing model 为 analytical characterization，macro DRC/LVS/PEX 未闭合，因此 overall profile maturity 保持 `partial`。精确审核的 256-endpoint minimum-capacitance waiver 必须披露，但它不是 setup/hold waiver，也不会把已验证 timing result 自动降为 partial。

FPGA 同样按 simulation、elaboration、software build、implementation、timing、bitstream、board smoke 和 workload validation 分层。当前公开 claim 是 AXIS32 XSim `3/3`，以及历史 Zynq trial copy 使用 compatibility-copied RTL 的 elaboration 与 SDK/ELF build。当前公开 RTL 的直接 Vivado 2018.3 elaboration、bitstream、board execution、MCDMA runtime、timing 和 resources 为 `not_claimed`。

## 完整性

`provenance/checksums.sha256` 按 Git tree 的 bytewise path 顺序记录 mode 和 Git blob 内容 SHA256，不依赖 Windows 或 Linux checkout 行尾。当前 main 必须使用 main 内自己的 checksum manifest；immutable RC3 必须在独立 RC3 checkout 中使用 RC3 内自己的 manifest 验证。

`provenance/verify_release.py` 校验 tag、三层来源引用、profile/claim/evidence schema、canonical checksum 和公开泄漏边界。Presentation SVG 与文档是 public packaging 内容；它们不能替代 evidence，也不能改变原始数值、哈希、PVT、工具身份或 caveat。

RC3 增加已验证的 ICS55 RVT DC-only evidence，并记录独立且未完成的 ECOS 完整 RDTC routing 尝试。后者没有生成 routed handoff，因而不是 physical profile 或 timing claim。

`verified` internal reg-to-reg timing 只覆盖已记录的单时钟内部路径。它不等于完整 top-level IO timing、reset recovery/removal、OCV/MMMC、foundry DRC/LVS/PEX、foundry signoff 或 silicon readiness。
