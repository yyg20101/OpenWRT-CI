#!/usr/bin/env bash
# 在专用、干净的 checkout 中运行；只向 origin 的 main/custom 推送。
set -euo pipefail

log_dir=${SYNC_LOG_DIR:-$(git rev-parse --git-path fork-sync-logs)}
mkdir -p "$log_dir"
log_dir=$(cd "$log_dir" && pwd)
: > "$log_dir/state.tsv"
: > "$log_dir/sync.log"
: > "$log_dir/conflicts.txt"
stage=prepare
reason=unexpected_error
result=failure
attempt=0
max_attempts=${SYNC_MAX_ATTEMPTS:-3}
retry_delay=${SYNC_RETRY_DELAY:-10}

record() { printf '%s\t%s\n' "$1" "$2" >> "$log_dir/state.tsv"; }
report() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" | tee -a "$log_dir/sync.log"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}
run() { "$@" 2>&1 | tee -a "$log_dir/sync.log"; }
phase() { stage=$1; record stage "$stage"; report "步骤：${stage}；尝试：${attempt}/${max_attempts}"; }
finish() {
  local code=$?
  trap - EXIT
  record status "$result"
  record reason "$reason"
  record stage "$stage"
  record attempt "$attempt"
  record exit_code "$code"
  record finished_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ "$code" != 0 ]]; then
    report "同步失败：${reason}；失败步骤：${stage}；退出码：${code}。诊断目录：${log_dir}"
  fi
  exit "$code"
}
trap finish EXIT
record started_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ ! "$max_attempts" =~ ^[1-3]$ || ! "$retry_delay" =~ ^[0-9]+$ || "$retry_delay" -gt 30 ]]; then
  reason=invalid_retry_settings
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  reason=dirty_worktree
  report '工作区不干净，停止同步。日志必须存放在工作区外或 .git 内。'
  exit 1
fi

# 返回 10 表示可重试；20/30 为冲突或配置错误，不盲目重试。
sync_once() {
  local old_main source_main old_custom new_custom remote_main remote_custom
  phase fetch
  if ! run git fetch --no-tags origin \
      +refs/heads/main:refs/remotes/origin/main \
      +refs/heads/custom:refs/remotes/origin/custom; then
    reason=fetch_origin_failed
    return 10
  fi
  if ! run git fetch --no-tags upstream +refs/heads/main:refs/remotes/upstream/main; then
    reason=fetch_upstream_failed
    return 10
  fi
  old_main=$(git rev-parse refs/remotes/origin/main)
  source_main=$(git rev-parse refs/remotes/upstream/main)
  old_custom=$(git rev-parse refs/remotes/origin/custom)
  record old_main "$old_main"
  record source_main "$source_main"
  record old_custom "$old_custom"
  report "引用快照：upstream=${source_main}；main=${old_main}；custom=${old_custom}。"

  phase merge
  if ! run git checkout -B custom "$old_custom"; then
    reason=checkout_failed
    return 30
  fi
  if ! git merge-base --is-ancestor "$source_main" HEAD; then
    if ! run git merge --no-ff --no-edit "$source_main" \
        -m "sync: merge main (${source_main:0:12}) into custom"; then
      git diff --name-only --diff-filter=U > "$log_dir/conflicts.txt"
      if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
        run git merge --abort || return 30
      fi
      reason=merge_failed
      report '合并失败，两个远程分支均未由本次同步更新。冲突文件：'
      run cat "$log_dir/conflicts.txt"
      return 20
    fi
  fi
  new_custom=$(git rev-parse HEAD)
  record new_custom "$new_custom"
  report "合并候选：custom=${new_custom}。"

  phase validate
  if ! git merge-base --is-ancestor "$old_custom" "$new_custom" || \
      ! git merge-base --is-ancestor "$source_main" "$new_custom"; then
    reason=history_validation_failed
    return 30
  fi

  if [[ "$old_main" != "$source_main" || "$old_custom" != "$new_custom" ]]; then
    phase atomic_push
    # custom 的候选提交已验证保留旧历史；两个精确 lease 防止覆盖并发更新。
    # 远端不支持原子推送时直接失败，绝不退回分两次推送。
    if ! run git push --atomic \
        "--force-with-lease=refs/heads/main:$old_main" \
        "--force-with-lease=refs/heads/custom:$old_custom" \
        origin "$source_main:refs/heads/main" "$new_custom:refs/heads/custom"; then
      reason=atomic_push_failed
      if grep -q 'does not support --atomic push' "$log_dir/sync.log"; then
        reason=atomic_push_unsupported
        return 30
      fi
      return 10
    fi
  else
    report 'main/custom 已同步，无需提交或推送。'
  fi

  phase verify_remote
  if ! run git fetch --no-tags origin \
      +refs/heads/main:refs/remotes/origin/main \
      +refs/heads/custom:refs/remotes/origin/custom; then
    reason=verification_fetch_failed
    return 10
  fi
  remote_main=$(git rev-parse refs/remotes/origin/main)
  remote_custom=$(git rev-parse refs/remotes/origin/custom)
  record remote_main "$remote_main"
  record remote_custom "$remote_custom"
  if [[ "$remote_main" != "$source_main" ]] || \
      ! git merge-base --is-ancestor "$source_main" "$remote_custom" || \
      ! git merge-base --is-ancestor "$new_custom" "$remote_custom"; then
    reason=remote_verification_failed
    return 10
  fi
  report "验证通过：main=${remote_main}；custom=${remote_custom}，包含上游及原自定义历史。"
  reason=verified
  return 0
}

for ((attempt=1; attempt<=max_attempts; attempt++)); do
  record attempt "$attempt"
  if sync_once; then
    result=success
    exit 0
  else
    code=$?
  fi
  [[ "$code" == 10 && "$attempt" -lt "$max_attempts" ]] || exit 1
  report "本次失败：${reason}；${retry_delay} 秒后重新获取分支并重试。"
  sleep "$retry_delay"
done
