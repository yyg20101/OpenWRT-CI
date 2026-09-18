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
2. 用精确 `--force-with-lease` 将 fork `main` 指向上游提交，包含上游历史改写的情况。
3. 将同一提交合并到 `custom`，常规推送；没有变化则不产生提交或推送。

发生冲突时工作流失败，列出冲突文件，远程 `custom` 保持原状；`main` 仍完成同步。
不能保证自定义逻辑永不冲突，不自动选择 ours/theirs，也不创建 PR。
并发更新导致推送被拒绝时，本轮失败，下一次运行重新获取最新分支。

Sync fork 按钮执行合并，遇到上游改写历史可能生成多余合并提交；严格镜像应由本工作流维护。
“had recent pushes” 仅是 GitHub 推送活动提示，不代表分支有代码差异；此工作流不负责隐藏提示。

## 本地验证

`bash tests/test-fork-sync.sh` 在临时本地 Git 仓库中验证普通更新、上游历史改写、
重复执行、合并冲突和并发推送保护，不访问 GitHub。
