#!/usr/bin/env bash
# 上一轮 13 的 E 段报"响应异常"，说明 Gateway 返回的不是 JSON。
# 这个脚本把原始响应体完整打出来，并确认 14 的改动有没有真的生效。
set -uo pipefail
G=haven-gateway
GW=http://127.0.0.1:18003

echo "########## 1. 14 的改动生效了吗 ##########"
docker exec -i haven-ombre python - <<'PY'
import yaml
g = yaml.safe_load(open("/app/config.yaml", encoding="utf-8")).get("gateway", {})
for k in ("core_memory_interval_rounds", "core_memory_budget",
          "recall_admission_semantic_score", "semantic_rescue_enabled"):
    print(f"  {k}: {g.get(k)}")
print("  期望: 1 / 400 / 0.55 / True")
PY

echo
echo "########## 2. 容器重启过了吗（Up 应该是几分钟内）##########"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'

echo
echo "########## 3. 进程实际读到的值（不是文件里的值）##########"
curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c '
import sys, json
g = json.load(sys.stdin).get("gateway", {})
for k in sorted(g):
    if any(w in k for w in ("core", "admission", "rescue", "budget")):
        print(f"  {k}: {g[k]}")
' 2>/dev/null || echo "  health 读不到"

echo
echo "########## 4. 上游原始响应体（关键：看真实报错）##########"
TOKEN=$(docker exec "$G" printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
MODEL=$(curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["upstream_default_model"])' 2>/dev/null)
SESS=raw-$(date +%H%M%S)
Q="你还记得我的回复风格偏好吗"
export MODEL Q
BODY=$(python3 -c '
import json, os
print(json.dumps({"model": os.environ["MODEL"], "max_tokens": 60,
                  "messages":[{"role":"user","content":os.environ["Q"]}]}, ensure_ascii=False))')

echo "  session=$SESS"
echo "  --- HTTP 状态码 + 原始 body ---"
curl -sS --max-time 90 -o /tmp/ombre_resp.txt -w '  HTTP %{http_code}  耗时 %{time_total}s\n' \
  -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H "X-Ombre-Session-Id: $SESS" \
  -H 'X-Ombre-Debug-Detail: full' \
  --data-raw "$BODY" 2>&1
echo "  --- body 前 800 字 ---"
head -c 800 /tmp/ombre_resp.txt | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
echo
echo

echo "########## 5. Gateway 日志里这一轮发生了什么 ##########"
docker logs --tail 60 "$G" 2>&1 \
  | grep -aviE '"GET / HTTP' \
  | tail -25 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "########## 6. 上游余额 / 直连测试（绕过 Gateway）##########"
KEY=$(docker exec "$G" printenv OMBRE_GATEWAY_PROVIDER_CLAUDE_API_KEY 2>/dev/null)
if [ -n "$KEY" ]; then
  echo "  --- 直接打 ebutterfly，看它怎么回 ---"
  curl -sS --max-time 60 -o /tmp/ombre_up.txt -w '  HTTP %{http_code}\n' \
    -X POST https://api.ebutterfly.cc/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H 'Content-Type: application/json' \
    --data-raw "$BODY" 2>&1
  head -c 500 /tmp/ombre_up.txt | sed -E 's/(sk-)[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
  echo
else
  echo "  读不到上游 key"
fi

echo
echo "########## 7. 这一轮有没有被记下来 ##########"
sleep 2
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/data/gateway_state.db")
print("  request_rounds:", c.execute("select count(*) from request_rounds").fetchone()[0])
for r in c.execute("select session_id, round_id, completed_at from request_rounds order by rowid desc limit 3"):
    print("   ", r)
PY
echo
echo "########## 完毕 ##########"
