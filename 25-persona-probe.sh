#!/usr/bin/env bash
# persona 的 interval=3 意味着只在 round % 3 == 0 时评估。
# round=569 被跳过是正常的（569%3=2），但 567 该评估却没写入。
# 这个脚本在同一个 session 连发 3 轮，必然命中一次 interval，
# 然后把那一刻的日志抓出来，看评估到底是没跑还是跑了报错。
set -uo pipefail

GW=http://127.0.0.1:18003
SESS=persona-$(date +%H%M%S)
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
MODEL=$(curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["upstream_default_model"])' 2>/dev/null)
export MODEL

echo "########## 1. persona 配置与模型可用性 ##########"
docker exec -i haven-ombre python - <<'PY'
import yaml, httpx
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
p = cfg.get("persona", {}) or {}
for k in ("enabled", "mode", "model", "base_url", "evaluation_interval_rounds",
          "event_recording_enabled", "json_response_format", "max_tokens",
          "thinking_mode", "profile_id"):
    v = p.get(k)
    print(f"  {k}: {v}")
key = p.get("api_key") or cfg["dehydration"].get("api_key", "")
base = str(p.get("base_url") or cfg["dehydration"]["base_url"]).rstrip("/")
print("  --- 直测 persona 模型 ---")
try:
    r = httpx.post(f"{base}/chat/completions",
                   headers={"Authorization": f"Bearer {key}"},
                   json={"model": p.get("model"), "max_tokens": 8,
                         "response_format": {"type": "json_object"},
                         "messages": [{"role": "user",
                                       "content": '回复一个 JSON: {"ok":1}'}]},
                   timeout=30)
    print(f"  {r.status_code}  {r.text[:200]}")
except Exception as e:
    print("  ERR", str(e)[:150])
PY

echo
echo "########## 2. 连发 3 轮（session=$SESS）##########"
for i in 1 2 3; do
  Q="第 $i 轮：今天有点累，你陪我说说话"
  export Q
  BODY=$(python3 -c '
import json, os
print(json.dumps({"model": os.environ["MODEL"], "max_tokens": 60,
                  "messages":[{"role":"user","content":os.environ["Q"]}]}, ensure_ascii=False))')
  printf "  round %s -> " "$i"
  curl -sS --max-time 90 -X POST "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H "X-Ombre-Session-Id: $SESS" --data-raw "$BODY" 2>/dev/null \
    | python3 -c '
import sys, json
d = json.loads(sys.stdin.read() or "{}")
if "error" in d:
    print("错误:", json.dumps(d["error"], ensure_ascii=False)[:150])
else:
    c = (d.get("choices") or [{}])[0].get("message", {}).get("content") or ""
    print(c[:60].replace("\n", " "))
'
  sleep 3
done

echo
echo "########## 3. 这 3 轮的 persona 日志 ##########"
docker logs --tail 200 haven-gateway 2>&1 \
  | grep -aiE "persona|$SESS" | tail -25 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "########## 4. persona 表有没有变 ##########"
sleep 3
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    try:
        print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
    except Exception as e:
        print(f"  {t}: {e}")
r = c.execute("select updated_at from persona_global_state limit 1").fetchone()
print("  global_state.updated_at:", r[0] if r else None)
PY

echo
echo "########## 5. gateway 侧 persona 相关源码 ##########"
docker exec -i haven-gateway sh -lc '
  grep -n "Persona post-reply update skipped\|persona_post_reply\|def .*persona_post" /app/gateway.py | head -12'

echo
echo "########## 6. 全部日志里 persona 有没有异常 ##########"
docker logs --tail 600 haven-gateway 2>&1 \
  | grep -aiE 'persona.*(error|fail|exception|403|401|timeout|invalid)' | tail -10 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
echo "  (无输出 = 没有报错记录)"
echo
echo "########## 完毕 ##########"
