#!/usr/bin/env bash
# 把 Gateway 已存的 conversation_turns 灌进 Brain 的 raw_events（原文保险箱）。
# 不用改 dwell 代码。服务端按 source+hash 去重，重复跑安全。
#
# 用法：
#   bash 09-backfill-raw.sh            # 只看会推什么，不写
#   bash 09-backfill-raw.sh --write    # 真的写入
set -uo pipefail

DB=/data/haven-ombre/gateway_state.db
BRAIN=http://127.0.0.1:18001
WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

[ -f "$DB" ] || { echo "找不到 $DB"; exit 1; }

TOKEN=$(docker exec haven-ombre printenv OMBRE_MEMORY_WRITE_TOKEN 2>/dev/null)
[ -z "$TOKEN" ] && TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
[ -z "$TOKEN" ] && { echo "读不到写入 token"; exit 1; }

echo "源库: $DB"
echo "目标: $BRAIN/api/ingest-raw"
[ "$WRITE" = "1" ] && echo "模式: 真实写入" || echo "模式: dry-run（加 --write 才真写）"
echo

WRITE="$WRITE" TOKEN="$TOKEN" DB="$DB" BRAIN="$BRAIN" python3 <<'PY'
import os, json, sqlite3, urllib.request, collections

write = os.environ["WRITE"] == "1"
token = os.environ["TOKEN"]
db    = os.environ["DB"]
brain = os.environ["BRAIN"]

conn = sqlite3.connect(db)
conn.row_factory = sqlite3.Row
rows = conn.execute("""
    SELECT session_id, round_id, created_at, user_text, assistant_text
    FROM conversation_turns
    ORDER BY id ASC
""").fetchall()
conn.close()

# 按 session + 日期分组，一组一次请求
groups = collections.OrderedDict()
for r in rows:
    u = (r["user_text"] or "").strip()
    a = (r["assistant_text"] or "").strip()
    if not u and not a:
        continue
    day = str(r["created_at"] or "")[:10]
    key = (r["session_id"] or "main", day)
    groups.setdefault(key, []).append(r)

print(f"conversation_turns 总数: {len(rows)}")
print(f"有正文的轮次: {sum(len(v) for v in groups.values())}")
print(f"将分成 {len(groups)} 批（按 会话+日期）")
print()

total_events = 0
for (sess, day), items in groups.items():
    events = []
    for r in items:
        u = (r["user_text"] or "").strip()
        a = (r["assistant_text"] or "").strip()
        ts = r["created_at"]
        if u:
            events.append({"role": "user", "text": u, "created_at": ts})
        if a:
            events.append({"role": "assistant", "text": a, "created_at": ts})
    total_events += len(events)
    label = f"  {day}  session={sess}  轮次={len(items)}  事件={len(events)}"

    if not write:
        print(label + "   [dry-run]")
        continue

    payload = {
        "source": "gateway-conversation-turns",
        "conversation_id": f"{sess}:{day}",
        "events": events,
    }
    req = urllib.request.Request(
        f"{brain}/api/ingest-raw",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "X-Ombre-Session-Id": sess,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode("utf-8") or "{}")
        ins = body.get("inserted", body.get("stored", "?"))
        dup = body.get("duplicates", body.get("skipped", "?"))
        print(f"{label}   -> 写入 {ins} 去重 {dup}")
    except urllib.error.HTTPError as e:
        print(f"{label}   -> HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")
    except Exception as e:
        print(f"{label}   -> 失败: {e}")

print()
print(f"合计事件数: {total_events}")
if not write:
    print("确认没问题后跑： bash 09-backfill-raw.sh --write")
PY

echo
echo "########## 写入后的 raw_events 行数 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/raw_events.sqlite")
print("  raw_events:", c.execute("select count(*) from raw_events").fetchone()[0])
try:
    for r in c.execute("select substr(created_at,1,10) d, count(*) n from raw_events group by d order by d desc limit 10"):
        print(f"    {r[0]}: {r[1]}")
except Exception as e:
    print("  按日期统计失败:", e)
PY
