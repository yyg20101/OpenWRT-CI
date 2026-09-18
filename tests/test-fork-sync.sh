#!/usr/bin/env bash
set -euo pipefail

sync_script="$(cd "$(dirname "$0")/.." && pwd)/Scripts/Sync-Upstream.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/fork-sync-test.XXXXXX")
# 保留临时仓库以便失败时检查；不访问任何真实远程。
printf 'Test repositories: %s\n' "$test_root"
export GIT_AUTHOR_NAME='Sync Test' GIT_AUTHOR_EMAIL='sync-test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
unset GITHUB_STEP_SUMMARY

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
printf 'upstream content\n' > ../source/shared.txt
git -C ../source commit -qam 'upstream edit'
git -C ../source push -q origin main
if bash "$sync_script"; then fail 'conflicting merge unexpectedly passed'; fi
assert_equal "$(git --git-dir=../fork.git rev-parse custom)" "$custom_before" 'conflict changed remote custom'
assert_equal "$(git --git-dir=../fork.git rev-parse main)" "$(git -C ../source rev-parse HEAD)" 'conflict prevented main sync'
[[ -z "$(git status --porcelain)" ]] || fail 'merge was not aborted'
printf 'PASS: conflict preserves remote custom while main syncs\n'

for target in main custom; do
  fixture "race-$target"
  upstream_change update
  expected=$(git --git-dir=../fork.git rev-parse "$target")
  competing=$(printf 'concurrent commit\n' | git commit-tree "$expected^{tree}" -p "$expected")
  git push -q origin "$competing:refs/test/concurrent"
  # 在远程公布旧引用之后、实际推送之前注入并发提交。
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nwhile read -r local_ref local_sha remote_ref remote_sha; do\n  if [[ "$remote_ref" == "refs/heads/%s" ]]; then\n    git --git-dir=../fork.git update-ref "$remote_ref" %s %s\n  fi\ndone\n' \
    "$target" "$competing" "$expected" > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  if bash "$sync_script"; then fail "concurrent $target update was overwritten"; fi
  assert_equal "$(git --git-dir=../fork.git rev-parse "$target")" "$competing" "concurrent $target update lost"
  assert_equal "$(git --git-dir=../upstream.git rev-parse main)" "$(git -C ../source rev-parse HEAD)" 'upstream changed'
  printf 'PASS: concurrent %s update preserved\n' "$target"
done

printf 'All fork sync tests passed.\n'
