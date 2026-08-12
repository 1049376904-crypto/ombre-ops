#!/bin/bash
# 41-diff-all-py.sh
# 批量检查容器里正在跑的所有 .py 源码文件，是否和 GitHub 仓库版本一致。
# 思路：先只对比哈希，一致就跳过，不一致才下载全文做 diff。
# 所有 curl 请求都带超时（连接超时 10s，总超时 30s），网络卡顿不会导致脚本挂死。
# gateway.py 已经手动确认过差异（只有 timeout 600s 这一处），默认跳过不重复检查，
# 如果想强制重新检查它，运行时加 RECHECK_GATEWAY=1 ./41-diff-all-py.sh
set -uo pipefail

REPO_OWNER="1049376904-crypto"
REPO_NAME="Haven-Ombre"
BRANCH="main"
CONTAINER_NAME="haven-gateway"
CONTAINER_APP_DIR="/app"
OUT_DIR="/tmp/gateway-diag-all"
CURL_OPTS=(--connect-timeout 10 --max-time 30 --retry 1 --retry-delay 2 -fsS)
RECHECK_GATEWAY="${RECHECK_GATEWAY:-0}"

PRIORITY_FILES=(
  "gateway.py"
  "reranker_engine.py"
  "persona_engine.py"
  "dream_engine.py"
  "dehydrator.py"
  "server.py"
  "embedding_engine.py"
  "bucket_manager.py"
  "memory_moments.py"
  "self_anchor.py"
  "raw_events.py"
  "gateway_state.py"
)

mkdir -p "$OUT_DIR"
SUMMARY_FILE="${OUT_DIR}/summary.txt"
: > "$SUMMARY_FILE"

echo "== 1/2 列出容器内 /app 目录下的所有 .py 文件 =="
docker exec "$CONTAINER_NAME" find "$CONTAINER_APP_DIR" -maxdepth 1 -name "*.py" -printf "%f\n" \
  | sort > "${OUT_DIR}/container_py_files.txt"
CONTAINER_FILES=$(cat "${OUT_DIR}/container_py_files.txt")

ORDERED_FILES=()
for f in "${PRIORITY_FILES[@]}"; do
  if echo "$CONTAINER_FILES" | grep -qx "$f"; then
    ORDERED_FILES+=("$f")
  fi
done
while IFS= read -r f; do
  skip=0
  for existing in "${ORDERED_FILES[@]}"; do
    [ "$existing" = "$f" ] && skip=1 && break
  done
  [ "$skip" -eq 0 ] && ORDERED_FILES+=("$f")
done <<< "$CONTAINER_FILES"

echo "共 ${#ORDERED_FILES[@]} 个文件待检查"
echo ""
echo "== 2/2 逐个对比哈希，不一致的才下载 diff（每个网络请求最多等 30 秒）=="

DIFF_COUNT=0
TIMEOUT_COUNT=0
for FILE in "${ORDERED_FILES[@]}"; do
  if [ "$FILE" = "gateway.py" ] && [ "$RECHECK_GATEWAY" != "1" ]; then
    echo "[${FILE}] 跳过：已手动确认过（只有 timeout=600.0 一处差异）。如需重查加 RECHECK_GATEWAY=1"
    echo "SKIP(already_confirmed) ${FILE}" >> "$SUMMARY_FILE"
    continue
  fi

  RUNNING_FILE="${OUT_DIR}/running_${FILE}"
  if ! docker cp "${CONTAINER_NAME}:${CONTAINER_APP_DIR}/${FILE}" "$RUNNING_FILE" 2>/dev/null; then
    echo "[${FILE}] 跳过：容器内拷贝失败"
    echo "SKIP(copy_failed) ${FILE}" >> "$SUMMARY_FILE"
    continue
  fi
  LOCAL_SHA=$(git hash-object "$RUNNING_FILE" 2>/dev/null || echo "")

  API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents/${FILE}?ref=${BRANCH}"
  REMOTE_JSON=$(curl "${CURL_OPTS[@]}" "$API_URL" 2>/dev/null)
  CURL_STATUS=$?
  if [ $CURL_STATUS -ne 0 ]; then
    echo "[${FILE}] 查询仓库哈希超时/失败（curl 退出码 ${CURL_STATUS}），跳过"
    echo "SKIP(network_timeout) ${FILE}" >> "$SUMMARY_FILE"
    TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
    rm -f "$RUNNING_FILE"
    continue
  fi
  if [ -z "$REMOTE_JSON" ]; then
    echo "[${FILE}] 仓库里没有这个文件（可能是容器专属/生成文件），跳过"
    echo "SKIP(not_in_repo) ${FILE}" >> "$SUMMARY_FILE"
    rm -f "$RUNNING_FILE"
    continue
  fi
  REMOTE_SHA=$(echo "$REMOTE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

  if [ -z "$REMOTE_SHA" ]; then
    echo "[${FILE}] 查询仓库哈希失败，跳过"
    echo "SKIP(query_failed) ${FILE}" >> "$SUMMARY_FILE"
    rm -f "$RUNNING_FILE"
    continue
  fi

  if [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
    echo "[${FILE}] 一致，无差异"
    echo "SAME ${FILE}" >> "$SUMMARY_FILE"
    rm -f "$RUNNING_FILE"
  else
    echo "[${FILE}] 哈希不一致，下载仓库版本做详细对比..."
    REPO_FILE="${OUT_DIR}/repo_${FILE}"
    if ! curl "${CURL_OPTS[@]}" -o "$REPO_FILE" \
      "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/${FILE}" 2>/dev/null; then
      echo "  -> 下载仓库版本超时/失败，跳过详细对比"
      echo "SKIP(download_timeout) ${FILE}" >> "$SUMMARY_FILE"
      TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
      rm -f "$RUNNING_FILE" "$REPO_FILE"
      continue
    fi
    DIFF_FILE="${OUT_DIR}/diff_${FILE}.diff"
    if diff -u "$REPO_FILE" "$RUNNING_FILE" > "$DIFF_FILE"; then
      echo "  -> diff 显示无实际内容差异"
      echo "SAME(diff_empty) ${FILE}" >> "$SUMMARY_FILE"
    else
      LINES=$(wc -l < "$DIFF_FILE")
      echo "  -> 发现差异，${LINES} 行，已保存到 ${DIFF_FILE}"
      echo "DIFF(${LINES}_lines) ${FILE}" >> "$SUMMARY_FILE"
      DIFF_COUNT=$((DIFF_COUNT + 1))
      echo "  改动内容："
      grep -E '^[+-]' "$DIFF_FILE" | grep -v '^+++\|^---' | sed 's/^/    /'
    fi
    rm -f "$REPO_FILE" "$RUNNING_FILE"
  fi
done

echo ""
echo "================ 汇总 ================"
cat "$SUMMARY_FILE"
echo "========================================"
echo "共发现 ${DIFF_COUNT} 个文件存在实际差异，${TIMEOUT_COUNT} 个文件因网络超时被跳过。"
if [ "$TIMEOUT_COUNT" -gt 0 ]; then
  echo "如果超时较多，可以隔一会再跑一次脚本，重复跑不会影响已确认的文件（还是会重新查一遍，可自行按 Ctrl+C 提前结束）。"
fi
echo ""
echo "看完可以清理临时文件："
echo "  rm -rf ${OUT_DIR}"
