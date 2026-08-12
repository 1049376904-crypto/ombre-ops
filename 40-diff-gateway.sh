#!/bin/bash
# 40-diff-gateway.sh
# 对比容器里正在跑的 gateway.py 和 GitHub 仓库里的版本，找出所有出入。
# 低内存占用：直接用 diff 命令行工具，结果写入文件，不在终端里堆输出。
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

echo "== 2/3 从 GitHub 拉取仓库里的 gateway.py =="
curl -fsS -o "$REPO_FILE" \
  "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/gateway.py"

echo "== 3/3 生成差异文件 =="
# diff 本身内存占用很小；结果写入文件而不是直接打印，避免终端缓冲区问题
if diff -u "$REPO_FILE" "$RUNNING_FILE" > "$DIFF_FILE"; then
  echo "没有发现任何差异，容器里的代码和仓库完全一致。"
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
