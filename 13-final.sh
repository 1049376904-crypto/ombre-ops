#!/usr/bin/env bash
# 1) 读 _should_inject_interval：interval=0 到底是"每轮"还是"永不"
# 2) 读 _build_core_memory_block：core_buckets 怎么挑
# 3) 带 X-Ombre-Debug-Detail: full 实发一轮，看 8 个候选各自被谁拦下
set -uo pipefail
G=haven-gateway
GW=http://127.0.0.1:18003

echo "########## A. _should_inject_interval 的实现（7392 起）##########"
docker exec -i "$G" sed -n '7392,7430p' /app/gateway.py

echo
echo "########## B. _build_core_memory_block 的实现（7727 起）##########"
docker exec -i "$G" sed -n '7727,7745p' /app/gateway.py

echo
echo "########## C. core_buckets 是怎么筛出来的 ##########"
docker exec -i "$G" sh -lc '
  grep -n "core_buckets" /app/gateway.py | head -20'

echo
echo "########## D. _summarize_buckets 会不会调模型 ##########"
docker exec -i "$G" sh -lc '
  grep -n "async def _summarize_buckets" /app/gateway.py'
docker exec -i "$G" sh -lc '
  n=$(grep -n "async def _summarize_buckets" /app/gateway.py | cut -d: -f1 | head -1)
  [ -n "$n" ] && sed -n "${n},$((n+35))p" /app/gateway.py'

echo
echo "########## E. 带 full debug 实发一轮 ##########"
TOKEN=$(docker exec "$G" printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
MODEL=$(curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["upstream_default_model"])' 2>/dev/null)
SESS=full-$(date +%H%M%S)
Q="${1:-你还记得我的回复风格偏好吗}"
export MODEL Q

BODY=$(python3 -c '
import json, os
print(json.dumps({"model": os.environ["MODEL"], "max_tokens": 80,
                  "messages": [{"role": "user", "content": os.environ["Q"]}]},
                 ensure_ascii=False))')

echo "  session=$SESS  问题=$Q"
curl -sS --max-time 90 -X POST "$GW/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H "X-Ombre-Session-Id: $SESS" \
  -H 'X-Ombre-Debug-Detail: full' \
  --data-raw "$BODY" 2>/dev/null \
  | python3 -c '
import sys, json
try: d = json.loads(sys.stdin.read())
except Exception: print("  响应异常"); sys.exit()
if "error" in d: print("  错误:", json.dumps(d["error"], ensure_ascii=False)[:300]); sys.exit()
print("  回复:", ((d.get("choices") or [{}])[0].get("message", {}).get("content") or "")[:200])
'

echo
echo "########## F. full debug 的召回细节 ##########"
sleep 2
curl -sS --max-time 15 -H "Authorization: Bearer $TOKEN" \
  "$GW/api/debug/injections?limit=1&include_context=true" 2>/dev/null \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get("items", [])
if not items: print("  无记录"); sys.exit()
p = items[0].get("payload", {})
print("  round:", items[0].get("round_id"), " detail:", p.get("debug_detail"))
print("  stable_context 字符数:", len(p.get("stable_context") or ""))
print("  stable_context 内容:")
print((p.get("stable_context") or "  (空)")[:1500])
print()
print("  core_memory 相关键:")
for k in sorted(p):
    if "core" in k.lower():
        print(f"    {k}: {json.dumps(p[k], ensure_ascii=False)[:300]}")
print()
print("  === 候选与拦截理由 ===")
for k in ("moment_chunk_shadow_debug", "debug_detail", "recall_debug",
          "dynamic_recall_debug", "admission_debug", "candidates"):
    v = p.get(k)
    if v: print(f"  {k}: {json.dumps(v, ensure_ascii=False)[:2500]}")
print()
print("  所有含 admission/reject/gate 的键:")
for k in sorted(p):
    if any(w in k.lower() for w in ("admission", "reject", "gate", "suppress")):
        print(f"    {k}: {json.dumps(p[k], ensure_ascii=False)[:600]}")
'
echo
echo "########## 完毕 ##########"
