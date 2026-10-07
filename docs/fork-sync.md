# Fork 同步约定

- `main` 是 `VIKINGYFY/OpenWRT-CI:main` 的精确镜像，不添加任何配置或工作流。
- `custom` 是本仓库默认分支，存放自定义配置和自动同步工作流，并合并 `main`。
- 软件包选择写入 `Config/PRIVATE.txt`；扩展脚本使用上游已有的私有入口。

## 启用

在 GitHub 创建 Fine-grained personal access token：Repository access 仅选择
`yyg20101/OpenWRT-CI`，Repository permissions 中授予 `Contents: Read and write`
和 `Workflows: Read and write`。后者用于同步上游 `.github/workflows/` 的更新。
将它保存为此 fork 的 Actions repository secret `SYNC_TOKEN`。
不要把 token 写入文件或提交，也不要复用个人 CLI 的全局登录凭据。

保持默认分支为 `custom`，在 Actions → Sync Upstream → Run workflow 中选择
`custom` 运行一次。此后每天 UTC 20:51（北京时间次日 04:51）自动运行，
比当前 Auto-Clean 的 UTC 21:21（北京时间次日 05:21）提前 30 分钟。
GitHub 定时任务可能延迟，此安排不保证两个工作流的严格执行顺序；
如果上游调整 Auto-Clean 的执行时间，需要相应检查此同步计划。
本工作流不主动触发固件编译，原有编译计划继续使用默认分支。
token 到期后需更新同名 Secret；长期不活跃的公开仓库定时任务可能被 GitHub 停用。

## 同步行为

1. 获取上游 `main`、fork `main` 与 `custom` 的最新状态。
2. 在本地将上游提交合并到 `custom`，验证候选提交包含上游及旧 `custom` 历史。
3. 使用 `git push --atomic` 一次性更新远端 `main/custom`，两个引用均有精确 lease，防止覆盖并发更新。
4. 再次读取远端，确认 `main` 等于本次获取的上游提交，`custom` 包含该提交及准备好的自定义历史。
5. 没有变化则不产生提交或推送，仍执行远端校验。

发生冲突时停止，记录冲突文件，本次同步不更新两个远程分支。这样避免先更新 `main`、
再合并失败产生半完成状态；代价是冲突解决前 `main` 也停留在上次成功状态。
不自动选择 ours/theirs，不丢弃自定义提交，不创建 PR；也不推送上游。
网络、并发推送或远端校验异常最多尝试三次，每次重新获取分支，间隔 10 秒。
合并冲突、工作区不干净或远端不支持原子推送直接失败，绝不退回分两次推送。
原子更新只约束本工作流；手动更新 `main` 后应运行 Sync Upstream，不能假设 Sync fork 同时更新 `custom`。

## 异常日志和上报

每次执行记录 UTC 时间、步骤、尝试次数、上游/远端/候选提交、冲突文件及 Git 日志。
工作流的上报任务使用独立的 `GITHUB_TOKEN`（`issues: write`、`actions: read`），
所以 `SYNC_TOKEN` 缺失、过期或 checkout 失败也能记录失败步骤；无需增加个人 token 的 Issues 权限。

最终失败或取消时，在 **本 fork** 创建 `[Sync Upstream] 自动同步异常` Issue。
未解决的同类异常追加到同一 Issue；随后成功则追加恢复记录并关闭。
重试后自行恢复的异常也保存为已关闭的 Issue。正常首次成功不创建 Issue。
记录包含运行链接、最多 16000 字符的同步日志尾部，以及失败作业最多 8000 字符的日志尾部，
因此凭据检查或 checkout 早期失败也可保留具体错误。日志过滤常见凭据格式，
不上传整个固件构建日志或节点/订阅配置。Issues 需保持开启。

日志同时作为 Actions artifact 上传（保留期 7 天），但 Auto-Clean 删除运行记录时
artifact 也可能被删除；Issue 是持久排查记录，现有 Auto-Clean 不删除它。
异常记录会 @yyg20101；邮件或站内通知取决于 GitHub 账号的通知设置，
也可在本 fork 的 Watch 设置中订阅 Issues。
如 Issue 上报失败，上报任务也会失败并保留 Actions 错误；GitHub/API 全面不可用时无法保证远端上报。
尚未启动的定时任务不会执行自己的上报代码，不能用本机制保证发现 GitHub 调度丢失。

手动运行时可勾选“仅测试异常上报，不执行分支同步”：产生一次预期失败，
验证诊断上传、Issue 创建/评论及关闭，不更新 `main/custom`。测试 Issue 单独标识，不影响真实异常。

Sync fork 按钮执行合并，遇到上游改写历史可能生成多余合并提交；严格镜像应由本工作流维护。
“had recent pushes” 仅是 GitHub 推送活动提示，不代表分支有代码差异；此工作流不负责隐藏提示。

## 本地验证

`bash tests/test-fork-sync.sh` 在临时本地 Git 仓库中验证普通更新、上游历史改写、
重复执行、合并冲突、原子推送、并发保护、不支持原子推送、有限重试和工作区保护，不访问 GitHub。
`node tests/test-sync-report.cjs` 验证日志脱敏、重复异常归并、恢复关闭、早期失败与手动诊断上报。
