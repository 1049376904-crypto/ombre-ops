#!/usr/bin/env bash
# 验证 05/06 两步是否真的生效。全部只读。
set -uo pipefail

echo "########## 1. 容器有没有真的重启 ##########"
docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -E 'haven|ombre'
echo "(Up 后面应该是几分钟以内。如果还是 3 days，说明没重启成功)"

echo
echo "########## 2. moment 图是否落盘 ##########"
docker exec haven-ombre python - <<'PY' 2>/dev/null
import sqlite3
c = sqlite3.connect("/state/memory_moments.sqlite")
for t in ("memory_moments", "memory_moment_edges", "memory_retrieval_aliases"):
    try:
        print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
    except Exception as e:
        print(f"  {t}: ERR {e}")
PY
echo "(期望：memory_moments 约 205，edges 约 107。重建前是 3 / 0)"

echo
echo "########## 3. 新配置是否被进程读到 ##########"
curl -sS --max-time 8 http://127.0.0.1:18001/health 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  buckets:",d.get("buckets"));print("  memory_edges:",d.get("memory_edges"));print("  reflection:",d.get("reflection",{}).get("model"),d.get("reflection",{}).get("api_ready"));print("  portrait:",d.get("portrait",{}).get("model"),d.get("portrait",{}).get("api_ready"))' 2>/dev/null \
  || echo "  Brain health 读取失败"

echo "--- Gateway 侧关键值 ---"
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
curl -sS --max-time 8 http://127.0.0.1:18003/health 2>/dev/null \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
g = d.get("gateway", {})
print("  core_memory_budget:", g.get("core_memory_budget", "(health 未暴露此字段)"))
print("  word_map_hint_enabled:", g.get("word_map_hint_enabled", "(未暴露)"))
print("  retrieval_mode:", g.get("retrieval_mode"))
print("  domain_sentinel_model:", g.get("domain_sentinel_model"))
print("  persona_model:", d.get("persona", {}).get("model"))
b = d.get("buckets", {})
print("  permanent/dynamic/feel:", b.get("permanent_count"), b.get("dynamic_count"), b.get("feel_count"))
' 2>/dev/null || echo "  Gateway health 读取失败"

echo
echo "########## 4. 有没有 runtime 覆盖层在偷偷改配置 ##########"
docker exec haven-ombre sh -lc '
  if [ -s /state/config.runtime.yaml ]; then
    echo "  存在 config.runtime.yaml，它会覆盖 config.yaml："
    grep -nE "model|budget|enabled" /state/config.runtime.yaml | head -20
  else
    echo "  无 runtime 覆盖层（好，config.yaml 就是唯一真相）"
  fi' 2>/dev/null

echo
echo "########## 5. 最近一轮注入了什么（核心记忆有没有出现）##########"
if [ -n "${TOKEN:-}" ]; then
  curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" \
    'http://127.0.0.1:18003/api/debug/injections?limit=1&include_context=true' 2>/dev/null \
    | python3 -c '
import sys, json, re
try:
    data = json.load(sys.stdin)
except Exception:
    print("  解析失败"); sys.exit()
items = data if isinstance(data, list) else data.get("items", [])
if not items:
    print("  还没有注入记录。去 dwell 里聊一句再回来看。"); sys.exit()
it = items[0]
p = it.get("payload", it)
print("  轮次:", it.get("round_id"), " 时间:", it.get("created_at"))
blocks = []
for key in ("stable_context", "dynamic_context"):
    txt = p.get(key) or ""
    if txt:
        blocks += re.findall(r"^#+\s*(.+)$|^\[(.+?)\]$", txt, re.M)
        for name in ("Core Memory", "Recent Context", "Just Now", "Recalled Memory",
                     "Diffused Memory", "Relationship Weather", "Dream Context",
                     "Favorite Memory", "Persona"):
            if name.lower() in txt.lower():
                print(f"    有: {name}")
print("  召回的 bucket:", p.get("recalled_ids") or p.get("injected_bucket_ids") or "(无)")
' 2>/dev/null || echo "  debug 端点无输出"
else
  echo "  读不到 OMBRE_GATEWAY_TOKEN"
fi

echo
echo "########## 6. raw_events / persona 现状（还没修的两项）##########"
docker exec haven-ombre python - <<'PY' 2>/dev/null
import sqlite3
for path, tables in (
    ("/state/raw_events.sqlite", ["raw_events"]),
    ("/state/persona_state.db", ["persona_events", "persona_session_state", "persona_exchange_log"]),
):
    c = sqlite3.connect(path)
    for t in tables:
        try:
            print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
        except Exception as e:
            print(f"  {t}: ERR {e}")
PY

echo
echo "########## 完毕。全部只读。 ##########"
