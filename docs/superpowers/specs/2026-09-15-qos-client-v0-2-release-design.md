# qos_client v0.2 操作端发布设计

## 背景

0xkey-v2026.09.0 要求每位 KeyOps 操作员使用的 `qos_client`，都必须由与 Enclave 发布版本一致、且已经过审阅的 QoS 修订构建。QoS main 的 `8a157122a1cad4d5b0674bcda53ae0450d187fbc` 已包含对齐后的 0.14 安全基线，但 main 尚无工作流可构建并发布所需的 Linux AMD64 与 Darwin ARM64 操作端客户端。历史标签 `0xkey-qos_client-v0.1.0` 包含一个原型工作流；它只能作为制品形态的证据，不能原样恢复为安全实现。

本设计只增加发布机制，不创建标签、不发布 Release、不构建 Enclave manifest、不处理 quorum 材料，也不部署任何环境。

## 决策

新增一个工作流 `.github/workflows/0xkey-qos-client-release.yml`，并提供两种明确模式：

1. 修改工作流或其契约测试的 Pull Request，以只读权限构建并验证两个操作端客户端，然后上传短期工作流制品；它不能发布 GitHub Release 或 attestation。
2. 匹配规则的标签推送，或显式 dispatch 一个已经存在的匹配标签时，构建相同矩阵；随后由一个单独授权的 job 发布不可变 GitHub Release 与构建 provenance attestation。

首个预期发布标识为 `0xkey-qos_client-v0.2.0`。创建该标签和执行发布模式属于后续、需要另行授权的操作。

## 备选方案

### 原样恢复历史工作流

不采用。历史工作流使用浮动 Action 引用，允许通过 `--clobber` 替换资产，生成的 checksum 文件不含文件名，且发布前没有验证所需的 YubiKey 命令面。

### 将构建与发布拆成可复用工作流

暂缓。这会为当前单一调用方增加一个公共接口和更多跨文件策略。当出现第二个调用方时，再考虑拆分发布流程。

### 单一双模式工作流

采用。它把来源选择与制品契约保留在同一个审阅单元内，同时把全部写权限隔离到最终、仅发布模式可执行的 job。

## 事件与来源状态机

工作流只接受以下状态：

| 事件 | 来源修订 | 构建 | 发布 |
|---|---|---:|---:|
| `pull_request` | GitHub Pull Request 的精确 merge-ref SHA（`github.sha`） | Linux + Darwin | 永不 |
| 匹配 `0xkey-qos_client-v[0-9]+.[0-9]+.[0-9]+` 的标签推送 | 被推送标签的精确 commit | Linux + Darwin | 是 |
| `workflow_dispatch`，输入一个已存在且匹配的标签 | 该标签的精确 commit | Linux + Darwin | 是 |

其他所有 event/ref 组合都必须在 checkout 前 fail closed。PR 模式测试候选代码与当前 base 合并后的结果，不得静默改用分支 head。dispatch 输入必须是完整标签名、必须匹配稳定语义版本格式、且必须已经解析到一个 commit。本生产工作流不接受预发布后缀。

发布模式下，来源 commit 必须可从 `origin/main` 到达。工作流记录 commit 与 tree 两种身份。各构建 job 独立检查 checkout 是否与准备阶段确定的身份一致。发布 job 在消费制品前再次执行身份检查。

复审补充：`workflow_dispatch` 必须从 `refs/heads/main` 执行；标签通过环境变量传递并使用锚定正则校验，Git 子命令使用参数数组。构建结束、上传制品之前再次核对来源身份及 tracked 文件是否保持干净。

## 权限边界

工作流级权限为 `contents: read`。准备、Linux、Darwin 与 PR 汇总 job 均保持只读。只有仅发布模式可执行的发布 job 获得：

- `contents: write`：创建 GitHub Release；
- `attestations: write`：发布 provenance；
- `id-token: write`：提供 attestation 身份。

任何 job 都不得获得 package、ECR、AWS、environment、Kubernetes、manifest、quorum 或成员秘密权限。构建 job 的 checkout 不持久化凭据。所有外部 Action 都固定到完整的 40 字符 commit SHA。

如果对应标签已经存在 GitHub Release，发布必须拒绝继续。资产绝不更新或替换。发布失败后，只有人工确认应保留还是移除不完整 Release，才能重试；工作流本身不做这一破坏性决策。

## Linux AMD64 构建

Linux job 在 `ubuntu-24.04` 上运行，只通过已审阅的 StageX/Buildx 路径构建 `out/qos_client/index.json`。它加载该 OCI layout、提取 `/qos_client`，并验证：

- 文件可执行，且被识别为 x86-64 Linux 可执行文件；
- 二进制以 `--help` 调用时成功返回；
- `provision-yubikey`、`approve-manifest`、`proxy-re-encrypt-share` 与 `after-genesis` 的 help 调用均成功；
- SHA-256 写为 `<64 位小写十六进制><两个空格>qos_client.linux-amd64`。

该 job 输出二进制、checksum，以及一份 JSON 元数据记录，其中包含来源 commit/tree、平台、构建方式、大小与 SHA-256。

## Darwin ARM64 构建

Darwin job 在固定的 `macos-14` runner 上运行，安装仓库指定的 Rust `1.94` 工具链与 `aarch64-apple-darwin` target，并执行：

```bash
cargo build --release --locked --features smartcard \
  --target aarch64-apple-darwin -p qos_client
```

它设置 `SOURCE_DATE_EPOCH=1`、`MACOSX_DEPLOYMENT_TARGET=11.0`，关闭 Cargo 颜色，并剥离 release symbols。它验证产物是可执行的 ARM64 Mach-O，执行与 Linux 相同的五项 help 检查，并写入带标准文件名的 checksum。元数据额外记录精确 `rustc` 版本与 macOS deployment target。

Darwin 输出只在已记录的 runner/toolchain 边界内具备可复现性；工作流不声明跨 runner 的字节级可复现性。

## 制品与 manifest 契约

两个构建 job 均上传保留七天的中间制品。发布 job 只下载两个预期名称的制品，并拒绝缺失或额外的契约文件。

`MANIFEST.json` 使用 schema `0xkey.qos-client-release/v1`，包含：

- 发布标签、仓库、来源 commit、来源 tree 与工作流 URL；
- 生成时间；
- `linux-amd64` 与 `darwin-arm64` 各一条封闭记录；
- 每个平台的文件名、checksum 文件名、大小、SHA-256、构建方式，以及解释可复现性所需的 toolchain/runtime 事实；
- 所需 YubiKey 命令列表，以及所有 help 检查均通过的声明。

发布前，发布 job 检查两个 checksum 文件，将所有元数据中的修订与 hash 与 manifest 对比，并校验 manifest 的封闭 schema。它为两个二进制、两个 checksum 文件和 `MANIFEST.json` 生成 attestation。

GitHub Release 必须且只能包含：

- `qos_client.linux-amd64`
- `qos_client.linux-amd64.sha256`
- `qos_client.darwin-arm64`
- `qos_client.darwin-arm64.sha256`
- `MANIFEST.json`

## 测试与 Pull Request 门禁

Ruby 契约测试解析工作流并断言：

- 可接受事件和严格的稳定版标签模式；
- PR 模式无法进入发布 job；
- 精确来源身份传递到每个构建和发布步骤；
- 构建 job 只读，且 checkout 不持久化凭据；
- 只有发布 job 具有三项必需的写权限；
- 所有 Action 使用完整 commit SHA；
- Linux 使用 StageX，Darwin 使用带 `--locked` 和 `smartcard` 的命令；
- 两个 job 都执行所需的 YubiKey help 检查；
- checksum 行包含文件名；
- 已存在的 Release 会被拒绝，且不存在 clobber/update 命令；
- manifest schema 与精确五文件发布 allowlist 均存在。

Shell 测试使用本地 fixture 覆盖来源/标签校验与 manifest 组装，包含畸形标签、预发布标签、缺失标签、非 main commit、平台修订不一致、checksum 格式错误、额外文件，以及合法双平台 bundle。

仓库现有 PR `quality` 汇总必须包含这些契约测试。因此，仅修改工作流的 Pull Request 在合并前，既能在本地证明不发布的控制面，也能在远端构建两个真实平台二进制。

## 可观测性与失败处理

每个阶段都输出稳定的 `phase`、`source_commit`、`source_tree`、`platform` 与结果，不打印凭据或敏感输入。发布 job 在 job summary 中记录最终 Release URL 与 attestation 验证命令。

构建、checksum、schema、来源身份、YubiKey 命令面或 attestation 任一失败，工作流都必须终止。发布不得降级为无 attestation 的资产，不得替换为其他修订，也不得覆盖已有 Release。

## 验收边界

当契约测试、现有 QoS PR checks，以及固定 Pull Request head 的两个真实平台构建 job 全部通过时，实现才可合并。合并不代表授权创建或发布 `0xkey-qos_client-v0.2.0`。

后续发布检查点必须固定 QoS main commit 与 tree，创建精确标签，观察 release run 成功，下载全部五项资产，验证两个 checksum 与 attestation，并记录 release manifest hash；完成这些步骤后，Builder 才能在 `builder-handoff.json` 中引用该发布。
