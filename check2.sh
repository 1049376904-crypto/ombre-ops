#!/usr/bin/env bash
# 只读诊断，不写不删不重启。
# 用法： bash check2.sh
set -uo pipefail

LIVE=/data/haven-ombre
STALE=/root/Haven-Ombre

red() { sed -E \
  -e 's/((api_key|apikey|password|passwd|secret|token)[[:space:]]*[:=][[:space:]]*)[^,;"]*/\1[REDACTED]/Ig' \
  -e 's/(sk-|gsk_|ghp_|xoxb-)[A-Za-z0-9_-]{8,}/[REDACTED]/g'; }

echo "########## A. 真实 buckets 目录里的数据库 ##########"
ls -la "$LIVE"/*.db "$LIVE"/*.sqlite 2>/dev/null || echo "无"

echo
echo "########## B. 真实 gateway_state.db 行数（关键）##########"
for db in "$LIVE/gateway_state.db" "$STALE/buckets/gateway_state.db"; do
  [ -f "$db" ] || continue
  echo "--- $db ---"
  for t in request_rounds conversation_turns injected_buckets injection_debug upstream_usage; do
    printf '    %s: %s\n' "$t" "$(sqlite3 "$db" "select count(*) from $t;" 2>/dev/null || echo '无此表')"
  done
  echo "    最近一轮: $(sqlite3 "$db" "select max(completed_at) from request_rounds;" 2>/dev/null)"
done

echo
echo "########## C. 真实 embeddings.db ##########"
for db in "$LIVE/embeddings.db" "$STALE/buckets/embeddings.db"; do
  [ -f "$db" ] || continue
  echo "--- $db ---"
  sqlite3 "$db" "select model, dimension, count(*) from embeddings group by model, dimension;" 2>&1
done
echo "真实 buckets md 数: $(find "$LIVE" -name '*.md' 2>/dev/null | wc -l)"

echo
echo "########## D. /state 是否会随容器销毁（最重要）##########"
for c in haven-ombre haven-gateway; do
  echo "--- $c 的挂载 ---"
  docker inspect "$c" --format '{{range .Mounts}}{{.Type}} | {{.Source}} -> {{.Destination}}{{println}}{{end}}' 2>/dev/null
done
echo "--- 两个容器的 /state 是否同一份 ---"
docker exec haven-ombre   sh -lc 'echo brain=$(ls /state 2>/dev/null | wc -l)' 2>/dev/null
docker exec haven-gateway sh -lc 'echo gw=$(ls /state 2>/dev/null | wc -l); ls -la /state 2>/dev/null' 2>/dev/null

echo
echo "########## E. 运行中的 Gateway 配置 vs 配置文件 ##########"
echo "--- 文件里的 ---"
grep -nE 'domain_sentinel_model|^  model:|state_dir|buckets_dir' "$STALE/config.yaml" 2>/dev/null | red
echo "--- 有没有 runtime 覆盖层 ---"
docker exec haven-ombre sh -lc 'ls -la /state/config.runtime.yaml 2>/dev/null || echo 无' 2>/dev/null

echo
echo "########## F. dwell 里存的网关配置 ##########"
for db in $(find /root/dwell-on-something -name '*.db' -o -name '*.sqlite*' 2>/dev/null | head -5); do
  echo "--- $db ---"
  sqlite3 "$db" "select key, case when key like '%token%' then '[REDACTED]' else value end from settings where key in ('gateway_base','gateway_token','model');" 2>/dev/null
done

echo
echo "########## G. Gateway 端到端实测 ##########"
TOKEN=$(docker exec haven-gateway sh -lc 'printenv OMBRE_GATEWAY_TOKEN' 2>/dev/null)
if [ -n "$TOKEN" ]; then
  curl -sS --max-time 60 -X POST http://127.0.0.1:18003/v1/chat/completions \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -H 'X-Ombre-Session-Id: smoketest' \
    -d '{"model":"【机械信使】claude-sonnet-4-6","max_tokens":32,"messages":[{"role":"user","content":"你还记得我的回复风格偏好吗"}]}' \
    | head -c 600 | red
  echo
  echo "--- 这一轮有没有被记下来 ---"
  sleep 2
  sqlite3 "$LIVE/gateway_state.db" "select count(*) from request_rounds;" 2>/dev/null
  echo "--- 注入了什么 ---"
  curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" \
    'http://127.0.0.1:18003/api/debug/injections?limit=1' 2>/dev/null | head -c 1500 | red
else
  echo "读不到 OMBRE_GATEWAY_TOKEN"
fi
echo
echo "########## 完毕，以上全部只读 ##########"
