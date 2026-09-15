# qos_client v0.2 设计复审与实施复核

## 结论

设计可以实施。本轮复审补足手动执行的工作流来源约束，并已纳入代码。复核由当前代理完成，不计为独立审阅。

## 主要检查

1. **来源：** PR 使用 merge ref 的 commit；稳定标签必须存在且可从 main 到达。dispatch 限定 main；构建前后以及汇总/发布 job 均校验 commit/tree，拒绝 tracked 文件变化。
2. **权限：** 默认只读；只有 publish job 获得三项写权限。PR 的 publish 输出恒为 false；发布依赖两个平台构建和制品验证成功。
3. **制品：** 各平台只允许二进制、带文件名的 checksum、metadata 三文件。先校验全部文件与封闭元数据，再创建含五项资产的发布目录；拒绝 symlink、额外文件、hash/大小/来源/工具链不一致。
4. **失败：** Release 列表读取失败立即退出；已存在的标签 Release 拒绝覆盖；创建时使用 `--verify-tag`，没有 upload/clobber 回退。失败后的不完整 Release 留待人工处置。

## 验证与限制

来源与制品测试使用临时 Git 仓库和伪二进制 fixture；不把它们计为真实平台执行。真实文件类型、五条 help 命令和编译结果由双平台 CI 验证。

Shell 测试方案采用 Ruby Open3 驱动真实 Git/CLI 子进程实现，与仓库既有 Ruby 契约测试保持一致。平台构建命令仍使用 Bash。

本轮只建立发布工作流候选。后续发布需固定合并后的 QoS commit/tree，并协调 Enclave pin 与 Builder 输入，才能使用同一修订形成发布证据。
