#!/usr/bin/env bash
# 通过 Gateway 真发一轮，然后把这一轮的注入内容完整打印出来。
# 会消耗一次上游 Claude 调用（max_tokens 很小）。
set -uo pipefail

GW=http://127.0.0.1:18003
SESS=core-check-$(date +%H%M%S)
Q="${1:-你还记得我的回复风格偏好吗}"

TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
[ -z "$TOKEN" ] && { echo "读不到 token"; exit 1; }

MODEL=$(curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["upstream_default_model"])' 2>/dev/null)
echo "session: $SESS"
echo "model:   $MODEL"
echo "问题:    $Q"
echo

echo "########## 发请求 ##########"
curl -sS --max-time 90 -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H "X-Ombre-Session-Id: $SESS" \
  -d "$(python3 -c '
import json,sys,os
print(json.dumps({
  "model": os.environ["MODEL"],
  "max_tokens": 120,
  "messages": [{"role":"user","content": os.environ["Q"]}]
}, ensure_ascii=False))' )" \
  2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("  响应不是 JSON:", e); sys.exit()
if "error" in d:
    print("  上游报错:", json.dumps(d["error"], ensure_ascii=False)[:300]); sys.exit()
ch = (d.get("choices") or [{}])[0]
print("  回复:", (ch.get("message", {}).get("content") or "")[:300])
u = d.get("usage") or {}
print("  usage:", {k: u[k] for k in list(u)[:6]})
' 
export MODEL Q

echo
echo "########## 这一轮到底注入了什么 ##########"
sleep 2
curl -sS --max-time 15 -H "Authorization: Bearer $TOKEN" \
  "$GW/api/debug/injections?limit=1&include_context=true" 2>/dev/null \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get("items", [])
if not items:
    print("  没有记录"); sys.exit()
it = items[0]
p = it.get("payload", {})
print("  round:", it.get("round_id"), " session:", it.get("session_id"))
print()
for key in ("stable_context", "dynamic_context"):
    t = p.get(key) or ""
    print(f"===== {key} ({len(t)} 字符) =====")
    print(t if t else "  (空)")
    print()
print("===== 各块是否注入 =====")
for k in sorted(p):
    if k.endswith("_injected"):
        print(f"  {k}: {p[k]}")
print()
print("  injected_bucket_ids:", p.get("injected_bucket_ids"))
print("  diffused_bucket_ids:", p.get("diffused_bucket_ids"))
print("  context_mode:", p.get("context_mode"))
print("  dynamic_tokens:", p.get("dynamic_tokens"))
print("  query_preview:", str(p.get("query_preview"))[:120])
print()
print("===== 哨兵怎么判的（决定要不要召回）=====")
for k in ("memory_sentinel_debug", "domain_sentinel_debug", "query_planner_debug"):
    v = p.get(k)
    print(f"  {k}: {json.dumps(v, ensure_ascii=False)[:400] if v else None}")
print()
print("===== 召回细节 =====")
dd = p.get("debug_detail")
print("  debug_detail:", json.dumps(dd, ensure_ascii=False)[:1200] if dd else None)
'

echo
echo "########## 召回诊断日志最后一条 ##########"
docker exec -i haven-ombre sh -lc '
  f=/state/recall_diagnostics.jsonl
  [ -s "$f" ] && tail -1 "$f" | head -c 1200 || echo "  仍无记录（说明 Brain 侧召回没被调用，Gateway 自己算的）"'
echo
