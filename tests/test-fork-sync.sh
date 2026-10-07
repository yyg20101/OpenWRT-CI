#!/usr/bin/env bash
set -euo pipefail

sync_script="$(cd "$(dirname "$0")/.." && pwd)/Scripts/Sync-Upstream.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/fork-sync-test.XXXXXX")
# 保留临时仓库以便失败时检查；不访问任何真实远程。
printf 'Test repositories: %s\n' "$test_root"
export GIT_AUTHOR_NAME='Sync Test' GIT_AUTHOR_EMAIL='sync-test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
unset GITHUB_STEP_SUMMARY
export SYNC_RETRY_DELAY=0 SYNC_MAX_ATTEMPTS=3

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3"; }

fixture() {
  local name=$1
  mkdir "$test_root/$name"
  cd "$test_root/$name"
  git init -q --bare --initial-branch=main upstream.git
  git init -q --initial-branch=main source
  cd source
  printf 'base\n' > shared.txt
  git add shared.txt
  git commit -qm base
  git remote add origin ../upstream.git
  git push -q origin main
  cd ..
  git clone -q --bare upstream.git fork.git
  git clone -q fork.git worker
  cd worker
  git remote add upstream ../upstream.git
  git remote set-url --push upstream DISABLED
  git checkout -qb custom
  printf 'private settings\n' > PRIVATE.txt
  git add PRIVATE.txt
  git commit -qm custom
  git push -q origin custom
}

upstream_change() {
  printf '%s\n' "$1" > ../source/release.txt
  git -C ../source add release.txt
  git -C ../source commit -qm "$1"
  git -C ../source push -q origin main
}

fixture basic
upstream_change update
private_before=$(git hash-object PRIVATE.txt)
bash "$sync_script"
source_head=$(git -C ../source rev-parse HEAD)
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$source_head" 'main must mirror upstream'
git merge-base --is-ancestor "$source_head" HEAD || fail 'custom must include upstream'
assert_equal "$(cat release.txt)" update 'upstream file did not reach custom'
assert_equal "$(git hash-object PRIVATE.txt)" "$private_before" 'private settings changed'
custom_before=$(git rev-parse HEAD)
bash "$sync_script"
assert_equal "$(git rev-parse HEAD)" "$custom_before" 'no-op created a commit'
grep -q $'reason\tverified' .git/fork-sync-logs/state.tsv || fail 'verification result not logged'
printf 'PASS: normal update and no-op\n'

git -C ../source commit --amend --allow-empty -qm rewritten
git -C ../source push -q --force origin main
bash "$sync_script"
source_head=$(git -C ../source rev-parse HEAD)
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$source_head" 'rewritten main not mirrored'
git merge-base --is-ancestor "$custom_before" HEAD || fail 'custom history lost'
assert_equal "$(git hash-object PRIVATE.txt)" "$private_before" 'rewrite lost private settings'
printf 'PASS: rewritten upstream history\n'

fixture conflict
printf 'custom content\n' > shared.txt
git commit -qam 'custom edit'
git push -q origin custom
custom_before=$(git rev-parse HEAD)
main_before=$(git --git-dir=../fork.git rev-parse main)
printf 'upstream content\n' > ../source/shared.txt
git -C ../source commit -qam 'upstream edit'
git -C ../source push -q origin main
if bash "$sync_script"; then fail 'conflicting merge unexpectedly passed'; fi
assert_equal "$(git --git-dir=../fork.git rev-parse custom)" "$custom_before" 'conflict changed remote custom'
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$main_before" 'conflict changed remote main'
grep -q '^shared.txt$' .git/fork-sync-logs/conflicts.txt || fail 'conflict path not logged'
grep -q $'attempt\t1' .git/fork-sync-logs/state.tsv || fail 'merge conflict retried'
[[ -z "$(git status --porcelain)" ]] || fail 'merge was not aborted'
printf 'PASS: conflict preserves both remote branches and logs diagnostics\n'

for target in main custom; do
  fixture "race-$target"
  upstream_change update
  expected=$(git --git-dir=../fork.git rev-parse "$target")
  other=main
  [[ "$target" != main ]] || other=custom
  other_before=$(git --git-dir=../fork.git rev-parse "$other")
  competing=$(printf 'concurrent commit\n' | git commit-tree "$expected^{tree}" -p "$expected")
  git push -q origin "$competing:refs/test/concurrent"
  # 在远程公布旧引用之后、实际推送之前注入并发提交。
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nwhile read -r local_ref local_sha remote_ref remote_sha; do\n  if [[ "$remote_ref" == "refs/heads/%s" ]]; then\n    git --git-dir=../fork.git update-ref "$remote_ref" %s %s\n  fi\ndone\n' \
    "$target" "$competing" "$expected" > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  if SYNC_MAX_ATTEMPTS=1 bash "$sync_script"; then fail "concurrent $target update was overwritten"; fi
  assert_equal "$(git --git-dir=../fork.git rev-parse "$target")" "$competing" "concurrent $target update lost"
  assert_equal "$(git --git-dir=../fork.git rev-parse "$other")" "$other_before" 'atomic push partially updated other branch'
  assert_equal "$(git --git-dir=../upstream.git rev-parse main)" "$(git -C ../source rev-parse HEAD)" 'upstream changed'
  printf 'PASS: concurrent %s update preserved\n' "$target"
done

fixture unsupported-atomic
upstream_change update
main_before=$(git --git-dir=../fork.git rev-parse main)
custom_before=$(git --git-dir=../fork.git rev-parse custom)
git --git-dir=../fork.git config receive.advertiseAtomic false
if bash "$sync_script"; then fail 'unsupported atomic push unexpectedly passed'; fi
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$main_before" 'unsupported atomic changed main'
assert_equal "$(git --git-dir=../fork.git rev-parse custom)" "$custom_before" 'unsupported atomic changed custom'
grep -q $'reason\tatomic_push_unsupported' .git/fork-sync-logs/state.tsv || fail 'atomic capability failure not logged'
printf 'PASS: unsupported atomic push fails without partial updates\n'

fixture transient-push
upstream_change update
printf '#!/usr/bin/env bash\nif [[ ! -f .git/failed-once ]]; then\n  touch .git/failed-once\n  echo "simulated transient push failure" >&2\n  exit 1\nfi\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
bash "$sync_script"
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$(git -C ../source rev-parse HEAD)" 'retry did not mirror main'
grep -q $'attempt\t2' .git/fork-sync-logs/state.tsv || fail 'transient failure was not retried'
grep -q 'simulated transient push failure' .git/fork-sync-logs/sync.log || fail 'transient error not retained'
printf 'PASS: transient push failure recovers and retains its log\n'

fixture persistent-push
upstream_change update
main_before=$(git --git-dir=../fork.git rev-parse main)
custom_before=$(git --git-dir=../fork.git rev-parse custom)
printf '#!/usr/bin/env bash\nexit 1\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
if bash "$sync_script"; then fail 'persistent push failure passed'; fi
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$main_before" 'persistent failure changed main'
assert_equal "$(git --git-dir=../fork.git rev-parse custom)" "$custom_before" 'persistent failure changed custom'
grep -q $'attempt\t3' .git/fork-sync-logs/state.tsv || fail 'retry limit not applied'
printf 'PASS: persistent failure stops after three attempts\n'

fixture dirty
printf 'uncommitted user content\n' >> PRIVATE.txt
main_before=$(git --git-dir=../fork.git rev-parse main)
if bash "$sync_script"; then fail 'dirty worktree passed'; fi
grep -q 'uncommitted user content' PRIVATE.txt || fail 'dirty content was overwritten'
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$main_before" 'dirty worktree changed main'
printf 'PASS: dirty worktree is preserved\n'

printf 'All fork sync tests passed.\n'
