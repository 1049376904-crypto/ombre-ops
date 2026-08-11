#!/usr/bin/env bash
# 00-set-diag-remote.sh
#
# 目的：把 /root/ombre-diag 的 remote 设成带 token 的正确格式，并把本地已有的 commit 推上去。
#
# 为什么需要它：
#   https://TOKEN@github.com/...        → git 把 token 当成用户名，还会再问密码（错）
#   https://x-access-token:TOKEN@...    → token 在密码位，不会再问（对）
#
# token 输入时不回显：屏幕上什么都不会显示，粘完直接回车就行，不是没生效。
# 也不会进入 bash 历史记录。

set -uo pipefail

REPO=/root/ombre-diag
SLUG=1049376904-crypto/ombre-diag

if [ ! -d "$REPO/.git" ]; then
  echo "没有 $REPO，先 clone。本脚本也能帮你 clone，继续往下跑。"
  NEED_CLONE=1
fi

printf '\n请粘贴新的 GitHub token（输入不可见，粘完回车）：'
IFS= read -rs TOKEN
printf '\n'

if [ -z "${TOKEN:-}" ]; then
  echo "没有输入内容，退出。"
  exit 1
fi

case "$TOKEN" in
  ghp_*|github_pat_*) : ;;
  *) echo "警告：看起来不像 GitHub token（应以 ghp_ 或 github_pat_ 开头），仍继续尝试。" ;;
esac

URL="https://x-access-token:${TOKEN}@github.com/${SLUG}.git"

if [ "${NEED_CLONE:-0}" = "1" ]; then
  echo "clone 中..."
  if ! git clone "$URL" "$REPO" 2>&1 | sed "s/${TOKEN}/***REDACTED***/g"; then
    echo "clone 失败。常见原因：token 没有 repo 权限，或已被删。"
    exit 1
  fi
fi

cd "$REPO" || exit 1

git remote set-url origin "$URL" 2>/dev/null || git remote add origin "$URL"
git config user.email ombre@local
git config user.name ombre

printf '\n===== remote（已隐去 token） =====\n'
git remote -v | sed -E 's#(https://x-access-token:)[^@]+#\1***REDACTED***#g'

printf '\n===== 待推送的本地 commit =====\n'
git log --oneline -5 2>&1

printf '\n===== 试推 =====\n'
if git push origin HEAD 2>&1 | sed "s/${TOKEN}/***REDACTED***/g"; then
  printf '\n推送成功。以后直接跑 bash /root/ombre-ops/03-collect-diag.sh 就会自动推。\n'
else
  printf '\n推送失败。看上面报错；若是 403，说明 token 缺 repo 写权限。\n'
fi

unset TOKEN
