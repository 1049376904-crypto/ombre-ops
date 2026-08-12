#!/bin/bash
# 40-diff-gateway.sh
# 对比容器里正在跑的 gateway.py 和 GitHub 仓库里的版本。
# 优化点：先只查仓库文件的 git blob sha（几十字节的 API 响应），
# 用 git hash-object 给本地文件算同样的 sha 对比；
# 完全一致就直接结束，不必下载整份 900KB 的源码来对比内容。
# 只有哈希不一致时，才去下载仓库版本、跑 diff。
set -euo pipefail

REPO_OWNER="1049376904-crypto"
REPO_NAME="Haven-Ombre"
BRANCH="main"
CONTAINER_NAME="haven-gateway"
CONTAINER_FILE="/app/gateway.py"
OUT_DIR="/tmp/gateway-diag"
RUNNING_FILE="${OUT_DIR}/gateway-running.py"
REPO_FILE="${OUT_DIR}/gateway-repo.py"
DIFF_FILE="${OUT_DIR}/gateway.diff"

mkdir -p "$OUT_DIR"

echo "== 1/3 从容器里拷出正在运行的 gateway.py =="
docker cp "${CONTAINER_NAME}:${CONTAINER_FILE}" "$RUNNING_FILE"

echo "== 2/3 只查仓库文件的哈希（不下载全文）=="
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/gateway.py?ref=${BRANCH}"
REMOTE_SHA=$(curl -fsS "$API_URL" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")
LOCAL_SHA=$(git hash-object "$RUNNING_FILE")

echo "仓库 blob sha : ${REMOTE_SHA}"
echo "本地 blob sha : ${LOCAL_SHA}"

if [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
  echo ""
  echo "哈希完全一致，容器里的代码和仓库完全同步，无需下载全文对比。"
  echo "== 完成 =="
  exit 0
fi

echo ""
echo "哈希不一致，说明确实有差异，现在才下载仓库版本做详细对比 =="
echo "== 3/3 拉取仓库版本并生成差异文件 =="
curl -fsS -o "$REPO_FILE" \
  "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/gateway.py"

if diff -u "$REPO_FILE" "$RUNNING_FILE" > "$DIFF_FILE"; then
  echo "diff 显示无差异（哈希不同但内容一致，可能是行尾符等非内容差异）。"
else
  LINES=$(wc -l < "$DIFF_FILE")
  echo "发现差异，共 ${LINES} 行，已保存到：${DIFF_FILE}"
  echo ""
  echo "只看改动的代码行（不含上下文），一目了然："
  grep -E '^[+-]' "$DIFF_FILE" | grep -v '^+++\|^---' || true
fi

echo ""
echo "== 完成 =="
echo "完整 diff 文件路径：${DIFF_FILE}"
echo "如果想再看一次完整 diff（不重新下载），运行："
echo "  cat ${DIFF_FILE}"
echo ""
echo "看完可以清理临时文件释放空间："
echo "  rm -rf ${OUT_DIR}"
