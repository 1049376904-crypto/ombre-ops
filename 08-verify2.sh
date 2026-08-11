#!/usr/bin/env bash
# 07 的修正版：docker exec 加 -i，heredoc 才能喂进容器。全部只读。
set -uo pipefail

echo "########## 1. moment 图是否真的落盘 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/memory_moments.sqlite")
for t in ("memory_moments", "memory_moment_edges", "memory_retrieval_aliases"):
    try:
        n = c.execute("select count(*) from " + t).fetchone()[0]
        print(f"  {t}: {n}")
    except Exception as e:
        print(f"  {t}: ERR {e}")
print("  期望 moments≈205 edges≈107，重建前是 3 / 0")
PY

echo
echo "########## 2. raw_events / persona 现状 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
for path, tables in (
    ("/state/raw_events.sqlite", ["raw_events"]),
    ("/state/persona_state.db",
     ["persona_events", "persona_session_state", "persona_exchange_log", "persona_global_state"]),
):
    print(f"  --- {path} ---")
    try:
        c = sqlite3.connect(path)
        for t in tables:
            try:
                print(f"    {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
            except Exception as e:
                print(f"    {t}: ERR {e}")
    except Exception as e:
        print(f"    打不开: {e}")
PY

echo
echo "########## 3. persona_global_state 里存了什么（判断它活着没）##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3, json
c = sqlite3.connect("/state/persona_state.db")
c.row_factory = sqlite3.Row
try:
    for r in c.execute("select * from persona_global_state limit 2"):
        d = dict(r)
        for k, v in d.items():
            s = str(v)
            print(f"    {k}: {s[:160]}")
        print("    ---")
except Exception as e:
    print("    ERR", e)
PY

echo
echo "########## 4. 注入调试的真实结构（看清有哪些字段）##########"
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
if [ -n "${TOKEN:-}" ]; then
  curl -sS --max-time 10 -H "Authorization: Bearer $TOKEN" \
    'http://127.0.0.1:18003/api/debug/injections?limit=2' 2>/dev/null \
    | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("  解析失败:", e); sys.exit()
items = data if isinstance(data, list) else data.get("items", [])
print("  记录数:", len(items))
for it in items[:2]:
    print("  ==== round", it.get("round_id"), it.get("created_at"), "session:", it.get("session_id"))
    p = it.get("payload", {})
    print("     payload 顶层键:", sorted(p.keys())[:40])
    for k in ("stable_context", "dynamic_context"):
        t = p.get(k) or ""
        print(f"     {k}: {len(t)} 字符")
        for line in [l for l in t.splitlines() if l.strip().startswith(("#", "[", "<"))][:15]:
            print("        |", line.strip()[:90])
'
else
  echo "  读不到 token"
fi

echo
echo "########## 5. 磁盘 187 个 md 但 health 报 185，差哪两个 ##########"
docker exec -i haven-ombre python - <<'PY'
import glob, os, re
bad = []
for p in glob.glob("/app/buckets/**/*.md", recursive=True):
    try:
        head = open(p, encoding="utf-8").read(400)
    except Exception as e:
        bad.append((p, f"读不了 {e}")); continue
    if not head.lstrip().startswith("---"):
        bad.append((p, "没有 frontmatter")); continue
    if not re.search(r"^id:", head, re.M):
        bad.append((p, "缺 id 字段"))
print(f"  总 md: {len(glob.glob('/app/buckets/**/*.md', recursive=True))}")
if bad:
    for p, why in bad:
        print(f"    可疑: {os.path.relpath(p, '/app/buckets')}  <- {why}")
else:
    print("  没发现格式问题（差额可能来自 .tombstones 或 archive 不计入）")
PY

echo
echo "########## 6. 召回诊断日志是否开始记录 ##########"
docker exec -i haven-ombre sh -lc '
  f=/state/recall_diagnostics.jsonl
  if [ -s "$f" ]; then
    echo "  已记录 $(wc -l < "$f") 条"
    echo "  最后一条的 query 和结论："
    tail -1 "$f" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(\"    query:\", str(d.get(\"query\"))[:80])
print(\"    候选数:\", len(d.get(\"candidates\") or []))
print(\"    最终选中:\", d.get(\"selected_ids\") or d.get(\"selected\") or \"(无)\")
" 2>/dev/null || tail -c 400 "$f"
  else
    echo "  还没有记录。去 dwell 聊一句就会写。"
  fi'

echo
echo "########## 完毕。全部只读。 ##########"
