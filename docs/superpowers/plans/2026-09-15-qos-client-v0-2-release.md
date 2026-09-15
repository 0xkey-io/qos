# qos_client v0.2 发布实施计划

**目标：** 提供 Linux AMD64 与 Darwin ARM64 操作端客户端构建、校验和不可变发布流程。

**架构：** 来源解析、制品校验与发布分别设门。PR 使用 GitHub merge ref；手动发布工作流必须从 main 执行，输入只允许已经存在的稳定版本标签。

**技术栈：** GitHub Actions、Bash、Ruby、StageX、Rust 1.94。

**设计：** `../specs/2026-09-15-qos-client-v0-2-release-design.md`。

## 全局约束

- 标签严格匹配 `0xkey-qos_client-v[0-9]+.[0-9]+.[0-9]+`，发布来源必须在 `origin/main` 历史中。
- PR 使用 `github.sha`，每个后续 job 核对 commit/tree。
- 默认 `contents: read`；仅发布 job 获得 contents、attestations、id-token 写权限。
- 发布五个文件，使用 `0xkey.qos-client-release/v1` 封闭 schema，拒绝覆盖 Release。
- 文档使用中文；本实施不授权创建标签、Release 或部署。

## 任务 1：来源门

文件：新增 `.github/scripts/qos-client-source.rb`、`.github/tests/test_qos_client_source.rb`。

接口：`ruby .github/scripts/qos-client-source.rb`，读取 GitHub 事件环境与当前 checkout，向 `GITHUB_OUTPUT` 写入 `source_sha`、`source_tree`、`release_tag`、`publish`。

- [ ] 先用临时 Git 仓库编写行为测试：合法 PR、标签 push、main dispatch，以及错误事件、畸形/缺失标签、分支 dispatch、非 main 来源、SHA 不一致和脏树。
- [ ] 运行 `ruby .github/tests/test_qos_client_source.rb`，记录缺少实现的失败。
- [ ] 实现严格字符串校验、Git argv 调用、标签解引用、main ancestry 和 checkout 身份检查；错误退出非零。
- [ ] 复跑同一测试，并记录通过数量。

## 任务 2：制品契约

文件：新增 `.github/scripts/qos-client-artifacts.rb`、`.github/tests/test_qos_client_artifacts.rb`。

- [ ] 测试二进制 hash/大小、标准 checksum、双平台来源一致、未知字段/额外文件/symlink 拒绝。
- [ ] 实现元数据写入与 manifest 组装；仅允许五项最终资产。
- [ ] 用本地双平台 fixture 复跑正反例；真实平台运行验证文件类型与五条 help 命令。

## 任务 3：工作流和 PR

文件：新增 `.github/workflows/0xkey-qos-client-release.yml`、`.github/tests/test_qos_client_release_workflow.rb`；修改 `.github/workflows/pr.yml` 接入契约测试。

- [ ] 添加工作流契约测试，断言权限、事件、来源传播、完整 Action SHA、固定 runner、StageX 与 locked smartcard 命令。
- [ ] 实现 prepare、双平台 build、只读 PR 汇总与独立 publish job；publish 重验来源与制品后生成 attestation，使用拒绝覆盖的 Release 创建流程。
- [ ] 运行新行为测试及既有 Ruby 工作流测试、diff/Gitleaks；检查 workflow 表达式。
- [ ] 精确提交并推送 PR，检查 merge ref 的 quality 与两个真实平台构建结果；将远端结果同步中文 status/checkpoint。

## 本轮复审结论

## 执行记录

- [x] 任务 1 完成：来源门 RED→GREEN，12 项测试、55 条断言通过。
- [x] 任务 2 完成：制品组装 RED→GREEN，7 项测试、40 条断言通过；真实二进制命令面留待 CI。
- [x] 任务 3 本地实现：工作流契约 2 项、76 条断言通过，actionlint 通过，普通 quality 已接入。
- [x] 本地回归：8 份 Ruby 测试合计 42 项、596 条断言通过；Gitleaks 和 diff 检查通过。
- [ ] 任务 3 远端验收：创建 PR 后等待两个真实平台构建与普通 quality。

## 复审结论

原设计总体可实施。新增约束：手动执行限定 `refs/heads/main`；输入通过环境变量传递，Git 命令使用参数数组；标签稳定格式必须用锚定正则检查，不能把 Actions 的 tags glob 当成语义版本校验。上述收紧直接纳入实现。
