# 发行模型

RDTC 的公开发行将功能源码、私有交付元数据和公开包装明确分层：

- `rtl_source_commit` 固定 RTL、reference model、MATLAB 资产和公开接口的功能来源；
- `private_delivery_commit` 固定 claim/evidence 审阅和白名单导出配置；
- public packaging commit 包含公开仓结构、CI、文档和复现脚本；
- annotated public release tag 是不可变发行身份，通过 `git rev-list -n 1 <tag>` 获取对应 commit。

`register550-rc2` 的 tag 为 `rdtc-v1-register550-rc2`。manifest 不在同一 commit 内嵌自指的最终 public commit SHA；tag 是最终公开 commit 身份来源。

## 成熟度

- `verified` profile 表示记录的配置、工具、证据和 caveat 足以支持该 profile 的明确 claim；
- `partial` profile 可以包含独立 verified result，但整体仍有模型或实现阶段未闭合；
- `experimental` 是不支持公开 verified claim 的探索配置；
- `planned` 只表示路线图；
- `private_not_claimed` 不进入公开结果 claim。

Profile maturity 与 evidence/result maturity 分开记录。SRAM 333 MHz 的内部 setup/hold 数值保持已核验，但 analytical characterization、minimum-capacitance waiver 和 macro DRC/LVS/PEX 边界使整体 profile 保持 `partial`。

## 完整性

`provenance/checksums.sha256` 按 Git tree 的 bytewise path 顺序记录 mode 和 Git blob 内容 SHA256，不依赖 Windows 或 Linux checkout 行尾。`provenance/verify_release.py` 校验 tag、三层来源引用、profile/claim/evidence schema、canonical checksum 和公开泄漏边界。

`verified` 的 internal reg-to-reg timing 只覆盖已记录的单时钟内部路径。它不等于完整 top-level IO timing、reset recovery/removal、OCV/MMMC、foundry DRC/LVS/PEX、foundry signoff 或 silicon readiness。

