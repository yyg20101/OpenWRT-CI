#!/usr/bin/env bash
# 在专用、干净的 CI checkout 中运行；只向 origin 的 main/custom 推送。
set -euo pipefail

report() {
  printf '%s\n' "$1"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

if [[ -n "$(git status --porcelain)" ]]; then
  report '工作区不干净，停止同步。'
  exit 1
fi

git fetch --no-tags origin \
  +refs/heads/main:refs/remotes/origin/main \
  +refs/heads/custom:refs/remotes/origin/custom
git fetch --no-tags upstream +refs/heads/main:refs/remotes/upstream/main

old_main=$(git rev-parse refs/remotes/origin/main)
source_main=$(git rev-parse refs/remotes/upstream/main)
old_custom=$(git rev-parse refs/remotes/origin/custom)

# 即使上游改写历史，main 也直接指向同一提交，不生成合并提交。
# 精确 lease 可防止覆盖本次获取之后出现的并发更新。
if [[ "$old_main" != "$source_main" ]]; then
  git push "--force-with-lease=refs/heads/main:$old_main" \
    origin "$source_main:refs/heads/main"
  report "main 已镜像上游提交 ${source_main}。"
else
  report "main 已与上游一致：${source_main}；无需推送。"
fi

git checkout -B custom "$old_custom"
if git merge-base --is-ancestor "$source_main" HEAD; then
  report 'custom 已包含本次 main 更新；无需提交或推送。'
  exit 0
fi

if ! git merge --no-ff --no-edit "$source_main" \
    -m "sync: merge main (${source_main:0:12}) into custom"; then
  report 'custom 合并失败；origin/main 已同步，远程 custom 保持原状。'
  git diff --name-only --diff-filter=U
  git merge --abort
  exit 1
fi

# custom 只做常规合并和快进推送，保留自定义提交。
git merge-base --is-ancestor "$old_custom" HEAD
git push origin HEAD:refs/heads/custom
report "custom 已合并 main，当前提交 $(git rev-parse HEAD)。"
