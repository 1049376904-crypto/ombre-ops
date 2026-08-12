#!/usr/bin/env bash
# 目的：找出「它变得不像它自己」的来源。
# 只发 1 轮请求（省 token），然后把这一轮注入的全部原文打出来，
# 再查 dwell 后端自己的 system prompt，最后列出正文里带风格指令的记忆桶。
set -uo pipefail

GW=http://127.0.0.1:18003
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)

echo "########## 1. 最近一轮的完整注入原文（不再发新请求）##########"
curl -sS --max-time 15 -H "Authorization: Bearer $TOKEN" \
  "$GW/api/debug/injections?limit=1&include_context=true" 2>/dev/null \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get("items", [])
if not items:
    print("  无记录"); sys.exit()
it = items[0]; p = it.get("payload", {})
print(f"  round={it.get(\"round_id\")} session={it.get(\"session_id\")} time={it.get(\"created_at\")}")
for k in ("stable_context", "dynamic_context"):
    t = p.get(k) or ""
    print()
    print(f"===== {k}（{len(t)} 字符）=====")
    print(t if t else "  (空)")
print()
print("===== 各块开关 =====")
for k in sorted(p):
    if k.endswith("_injected"):
        print(f"  {k}: {p[k]}")
print("  injected_bucket_ids:", p.get("injected_bucket_ids"))
'

echo
echo "########## 2. dwell 后端自己有没有 system prompt（最可能的角色扮演来源）##########"
for f in /root/dwell-on-something/backend/*.py; do
  hits=$(grep -nE '"role"\s*:\s*"system"|system_prompt|SYSTEM_PROMPT|你是沐|你是一个|扮演|人格|设定' "$f" 2>/dev/null | head -6)
  [ -n "$hits" ] && { echo "--- $(basename "$f") ---"; echo "$hits"; }
done
echo "--- dwell 数据库里存的 prompt ---"
for db in /root/dwell-on-something/backend/data/dwell.db; do
  [ -f "$db" ] && sqlite3 "$db" \
    "select key, substr(value,1,300) from settings where key like '%prompt%' or key like '%persona%' or key like '%system%' or key like '%guide%';" 2>/dev/null
done

echo
echo "########## 3. 正文里带「风格指令」的记忆桶（被召回时会变成命令）##########"
docker exec -i haven-ombre python - <<'PY'
import glob, re, os
pat = re.compile(r"闷骚|欲拒还迎|语气|风格|扮演|人设|省略号|模仿|学着|daddy感|嘲讽")
rows = []
for p in glob.glob("/app/buckets/**/*.md", recursive=True):
    try:
        t = open(p, encoding="utf-8").read()
    except Exception:
        continue
    m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
    head, body = (m.group(1), t[m.end():]) if m else ("", t)
    hits = pat.findall(body)
    if not hits:
        continue
    bid = re.search(r"^id\s*:\s*(\S+)", head, re.M)
    name = re.search(r"^name\s*:\s*(.+)$", head, re.M)
    pin = "PIN " if re.search(r"^(pinned|protected)\s*:\s*true", head, re.M) else "    "
    rows.append((pin, bid.group(1) if bid else "?",
                 (name.group(1).strip() if name else os.path.basename(p))[:38],
                 len(set(hits)), body.strip()[:100].replace("\n", " ")))
rows.sort(key=lambda r: r[3], reverse=True)
print(f"  共 {len(rows)} 个桶正文含风格类词汇：")
for pin, bid, name, n, prev in rows[:15]:
    print(f"  {pin}{bid}  命中{n}类  {name}")
    print(f"       {prev}")
PY

echo
echo "########## 4. 当前会引导语气的开关 ##########"
docker exec -i haven-ombre python - <<'PY'
import yaml
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
g = cfg.get("gateway", {}); p = cfg.get("persona", {}); d = cfg.get("dream", {})
print("  --- persona（语气护栏，会注入 mood/inner_thought 指导）---")
for k in ("enabled", "mode", "event_recording_enabled"):
    print(f"    persona.{k}: {p.get(k)}")
print(f"    gateway.current_inner_state_interval_rounds: {g.get('current_inner_state_interval_rounds')}")
print("  --- 其它语气类注入 ---")
for k in ("relationship_weather_interval_rounds", "favorite_memory_interval_rounds",
          "core_memory_interval_rounds", "core_memory_budget"):
    print(f"    gateway.{k}: {g.get(k)}")
print(f"    dream.inject_enabled: {d.get('inject_enabled')}")
print()
print("  说明：persona 会给模型一段当前情绪状态指导；dream 会塞入一条梦境联想；")
print("  这两个都属于「语气/氛围引导」，不是事实记忆。要纯记忆可以关掉。")
PY

echo
echo "########## 完毕。只读，未改任何配置。 ##########"
