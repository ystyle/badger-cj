#!/usr/bin/env bash
# 下游集成验证（badger-cj 2.0 发版前置闸门）
#
# 为什么先做这一步：2.0 改了 WAL/VLog 的文件布局与写路径（分组提交），
# 只靠本仓测试无法证明「下游的真实用法」不被破坏。发布不可逆，所以先用
# **独立 worktree** 把下游切到本地 2.0 源码，跑通 build + test，再发版。
#
# 做法：每个下游仓用 `git worktree add -B test/badgercj-2.0` 建独立检出，
# 只在该 worktree 的 cjpm.toml 里把 badgercj 依赖改成 path 指向本仓
# （本地临时改动，不提交、不影响下游主干）。
#
# 用法：scripts/downstream-verify.sh [--skip-tests]
set -euo pipefail

ROOT="${WORKSPACE_ROOT:-/home/ystyle/Projects/Cangjie}"
BADGER="$ROOT/badger-cj"
WT_ROOT="$ROOT/.wt"
SKIP_TESTS="${1:-}"

# repo:branch:worktree 名；bstorm 在 storm-cj / storm-cj-v2 两个工作区里各一份
REPOS=(
  "storm-cj:master:storm-b2"
  "storm-cj-v2:v2:stormv2-b2"
  "tsdb-cj:master:tsdb-b2"
  "sunku-cj:master:sunku-b2"
  "holt-cj:master:holt-b2"
)

eval "$(cjvs env zsh)"
eval "$(cjvs stdx-env zsh)"

mkdir -p "$WT_ROOT"
for spec in "${REPOS[@]}"; do
  repo="${spec%%:*}"; rest="${spec#*:}"; branch="${rest%%:*}"; name="${rest##*:}"
  dir="$WT_ROOT/$name"
  echo "=== $name ($repo @ $branch) ==="
  git -C "$ROOT/$repo" worktree remove --force "$dir" 2>/dev/null || true
  git -C "$ROOT/$repo" worktree add -B "test/badgercj-2.0-$name" "$dir" "$branch" >/dev/null
  # 把 worktree 里的 badgercj 依赖改成 path（本地临时改动）
  manifest="$dir/cjpm.toml"
  [ -f "$manifest" ] && sed -i 's|"badgercj" = "[0-9.]*"|"badgercj" = { path = "'"$BADGER"'" }|' "$manifest"
  [ -f "$manifest" ] && sed -i 's|^badgercj = "[0-9.]*"|badgercj = { path = "'"$BADGER"'" }|' "$manifest"
  if [ -f "$dir/bstorm/cjpm.toml" ]; then
    sed -i 's|"badgercj" = "[0-9.]*"|"badgercj" = { path = "'"$BADGER"'" }|' "$dir/bstorm/cjpm.toml"
  fi
  ( cd "$dir" && cjpm build -j 16 )
  if [ "$SKIP_TESTS" != "--skip-tests" ]; then
    ( cd "$dir" && cjpm test -j 4 --no-progress )
  fi
done
echo "下游集成验证完成（全部 build/test 通过）"
