#!/usr/bin/env bash
#
# sync_to_remote.sh — 一键把本机 hermes-reader 源码同步到远程机器并提交推送到 GitHub。
#
# 流程:
#   1. rsync 本机源码到 william@10.10.164.32 的对应目录 (排除 .git 与构建产物, --delete 镜像)
#   2. SSH 登录远程: git fetch -> git add -A -> git commit -> git rebase origin/master -> git push
#
# 用法:
#   ./scripts/sync_to_remote.sh "提交说明"
#   ./scripts/sync_to_remote.sh "提交说明" --no-push      # 只 rsync + 远程提交, 不推送
#
# 注意: 提交说明中避免使用双引号/反引号, 以免破坏变量传递。
#
set -euo pipefail

LOCAL_DIR="/home/tomac/.hermes/workspace/hermes-application/hermes-reader"
REMOTE_HOST="william@10.10.164.32"
REMOTE_DIR="/home/william/workspace/github/hermes-reader"

# 解析参数
NO_PUSH=0
MSG=""
for a in "$@"; do
  if [ "$a" = "--no-push" ]; then
    NO_PUSH=1
  else
    MSG="$a"
  fi
done
MSG="${MSG:-Sync local changes ($(date '+%Y-%m-%d %H:%M'))}"
# base64 编码提交说明, 避免说明中的 & / 空格等破坏远程 ssh 命令行解析
MSG_B64=$(printf '%s' "$MSG" | base64 -w0)

# rsync 排除项 (.git 必须保留远程历史; 构建产物与 IDE 文件不传)
EXCLUDES=(
  --exclude='.git'
  --exclude='build'
  --exclude='.dart_tool'
  --exclude='android/build'
  --exclude='android/.gradle'
  --exclude='ios/Pods'
  --exclude='ios/build'
  --exclude='linux/build'
  --exclude='macos/build'
  --exclude='windows/build'
  --exclude='web/build'
  --exclude='.idea'
  --exclude='.vscode'
  --exclude='*.iml'
  --exclude='.flutter-plugins'
  --exclude='.flutter-plugins-dependencies'
  --exclude='scripts/'   # 本脚本是本机专用, 不传到远程仓库
)

echo "==> [1/2] rsync sources -> ${REMOTE_HOST}:${REMOTE_DIR}"
rsync -az --delete "${EXCLUDES[@]}" "${LOCAL_DIR}/" "${REMOTE_HOST}:${REMOTE_DIR}/"

echo "==> [2/2] commit & push on remote"
# MSG 通过环境变量传到远程, 远程用 quoted heredoc 避免本地展开
ssh "${REMOTE_HOST}" MSG_B64="${MSG_B64}" NO_PUSH="${NO_PUSH}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd /home/william/workspace/github/hermes-reader
# 解码提交说明 (与本地 base64 编码对应)
MSG=$(printf '%s' "${MSG_B64}" | base64 -d)
git fetch origin
git add -A
if [ -n "$(git status --porcelain)" ]; then
  git commit -m "$MSG"
  echo "committed on remote"
else
  echo "no local changes to commit"
fi
git rebase origin/master
if [ "${NO_PUSH:-0}" = "0" ]; then
  git push origin master
  echo "pushed to origin/master"
else
  echo "(--no-push) skipped push"
fi
REMOTE

echo "==> done"
