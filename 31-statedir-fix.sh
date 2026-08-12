#!/usr/bin/env bash
# 安全版 state_dir 修复。取代 30 的 --write（那个用 mtime 判断，会用空库覆盖真数据）。
#
# 背景：persona_engine.py:234 用 config["buckets_dir"]，而 config.yaml 里
# buckets_dir 是 None，环境变量 OMBRE_BUCKETS_DIR=/app/buckets 只被部分模块读取，
# persona 落到了 /app/state/（容器可写层，recreate 就没）。
#
# 本脚本：
#   1. 逐表比行数，只有容器内那份严格更多才迁移
#   2. 只迁 persona_state.db（唯一容器内更好的）
#   3. 迁移前把 /state 的原件另存
#   4. 显式设 state_dir=/state，让所有引擎都写挂载目录
#
# 默认 dry-run，加 --write 执行。
set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

echo "########## 1. 逐表对比行数（决定迁不迁）##########"
docker exec -i haven-gateway python - <<'PY'
import sqlite3, os

pairs = [
    ("persona_state.db",      ["persona_events", "persona_session_state", "persona_exchange_log"]),
    ("raw_events.sqlite",     ["raw_events"]),
    ("memory_moments.sqlite", ["memory_moments", "memory_moment_edges", "memory_retrieval_aliases"]),
    ("reminders.sqlite",      ["reminders"]),
    ("word_map.sqlite",       ["word_nodes", "word_edges"]),
]

def counts(path, tables):
    if not os.path.exists(path):
        return None
    out = {}
    try:
        c = sqlite3.connect(path)
        for t in tables:
            try:
                out[t] = c.execute("select count(*) from " + t).fetchone()[0]
            except Exception:
                out[t] = None
        c.close()
    except Exception:
        return None
    return out

for name, tables in pairs:
    src = f"/app/state/{name}"
    dst = f"/state/{name}"
    a, b = counts(src, tables), counts(dst, tables)
    print(f"  --- {name}")
    print(f"      /app/state : {a}")
    print(f"      /state     : {b}")
    if a is None:
        print("      => 容器内没有这份，无需迁移"); continue
    if b is None:
        print("      => /state 没有，直接复制"); continue
    sa = sum(v for v in a.values() if isinstance(v, int))
    sb = sum(v for v in b.values() if isinstance(v, int))
    if sa > sb:
        print(f"      => 迁移（{sa} > {sb}）")
    elif sa == sb:
        print(f"      => 相同（{sa}），跳过")
    else:
        print(f"      => !! 不迁移，容器内更少（{sa} < {sb}），迁了会丢数据")
PY

if [ "$WRITE" != "1" ]; then
  echo
  echo "=================================================="
  echo "以上是 dry-run。确认只有 persona_state.db 标记为「迁移」后："
  echo "    bash 31-statedir-fix.sh --write"
  echo "=================================================="
  exit 0
fi

echo
echo "########## 2. 迁移（只迁行数严格更多的）##########"
docker exec -i haven-gateway python - <<'PY'
import sqlite3, os, shutil, datetime

pairs = [
    ("persona_state.db",      ["persona_events", "persona_session_state", "persona_exchange_log"]),
    ("raw_events.sqlite",     ["raw_events"]),
    ("memory_moments.sqlite", ["memory_moments", "memory_moment_edges", "memory_retrieval_aliases"]),
    ("reminders.sqlite",      ["reminders"]),
]
stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

def total(path, tables):
    if not os.path.exists(path):
        return None
    try:
        c = sqlite3.connect(path)
        n = 0
        for t in tables:
            try:
                n += c.execute("select count(*) from " + t).fetchone()[0]
            except Exception:
                pass
        c.close()
        return n
    except Exception:
        return None

for name, tables in pairs:
    src, dst = f"/app/state/{name}", f"/state/{name}"
    sa, sb = total(src, tables), total(dst, tables)
    if sa is None:
        continue
    if sb is None:
        shutil.copy2(src, dst); print(f"  {name}: 复制到 /state（目标原本不存在）"); continue
    if sa > sb:
        shutil.copy2(dst, f"{dst}.pre_statedir_{stamp}")
        shutil.copy2(src, dst)
        print(f"  {name}: 已迁移 {sa} 条（原 {sb} 条存为 .pre_statedir_{stamp}）")
    else:
        print(f"  {name}: 跳过（容器内 {sa} <= /state {sb}）")
PY

echo
echo "########## 3. 设 state_dir=/state ##########"
CFG=/root/Haven-Ombre/config.yaml
BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CFG" "$BAK"; echo "  config 备份 -> $BAK"

docker exec -i haven-ombre python - <<'PY'
import yaml
p = "/app/config.yaml"
cfg = yaml.safe_load(open(p, encoding="utf-8"))
print("  state_dir  :", repr(cfg.get("state_dir")), "-> '/state'")
print("  buckets_dir:", repr(cfg.get("buckets_dir")), "-> '/app/buckets'（补上，避免 KeyError 回退）")
cfg["state_dir"] = "/state"
if not cfg.get("buckets_dir"):
    cfg["buckets_dir"] = "/app/buckets"
yaml.safe_dump(cfg, open(p, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=True, default_flow_style=False)
PY

docker exec haven-ombre python -c \
  "import yaml;yaml.safe_load(open('/app/config.yaml',encoding='utf-8'));print('  YAML OK')" \
  || { echo "  YAML 坏了，回滚"; cp "$BAK" "$CFG"; exit 1; }

echo
echo "########## 4. 重启 ##########"
cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway >/dev/null 2>&1
sleep 14
docker ps --format '{{.Names}}\t{{.Status}}' | grep haven
echo "--- brain health ---"
curl -sS --max-time 8 http://127.0.0.1:18001/health 2>/dev/null | head -c 160 || echo "  不通"
echo

echo
echo "########## 5. 验证：引擎现在写哪里 ##########"
docker exec -i haven-gateway python - <<'PY'
import sys, yaml
sys.path.insert(0, "/app")
from persona_engine import PersonaStateEngine
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
eng = PersonaStateEngine(cfg)
print("  persona db_path:", eng.db_path)
print("  应该是 /state/persona_state.db")
PY

echo
echo "########## 6. 数据核对（迁移有没有伤到东西）##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
checks = [
    ("/state/persona_state.db", "persona_session_state"),
    ("/state/raw_events.sqlite", "raw_events"),
    ("/state/memory_moments.sqlite", "memory_moments"),
    ("/data/gateway_state.db", "request_rounds"),
]
for p, t in checks:
    try:
        print(f"  {t}: {sqlite3.connect(p).execute('select count(*) from ' + t).fetchone()[0]}")
    except Exception as e:
        print(f"  {t}: {e}")
PY
echo "  buckets md: $(find /data/haven-ombre -name '*.md' 2>/dev/null | wc -l)"
echo "  期望：persona 3 / raw_events 1000 / moments 205 / rounds 570+ / md 187"

echo
echo "########## 7. 连发 3 轮，确认 persona 写进 /state ##########"
GW=http://127.0.0.1:18003
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
MODEL=$(curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["upstream_default_model"])' 2>/dev/null)
SESS=sdfix-$(date +%H%M%S)
export MODEL
for i in 1 2 3; do
  Q="第 $i 句：刚才在忙，现在有空了"
  export Q
  BODY=$(python3 -c '
import json, os
print(json.dumps({"model": os.environ["MODEL"], "max_tokens": 50,
                  "messages":[{"role":"user","content":os.environ["Q"]}]}, ensure_ascii=False))')
  printf "  round %s -> " "$i"
  curl -sS --max-time 90 -X POST "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H "X-Ombre-Session-Id: $SESS" --data-raw "$BODY" 2>/dev/null \
    | python3 -c '
import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(((d.get("choices") or [{}])[0].get("message", {}).get("content") or "ERR")[:60].replace("\n", " "))
'
  sleep 4
done
echo "  等 25 秒让后台评估落库..."
sleep 25
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
c.row_factory = sqlite3.Row
print("  /state/persona_state.db:")
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    print(f"    {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
r = c.execute("select session_id, mood_label, inner_thought, updated_at from persona_session_state order by rowid desc limit 1").fetchone()
if r:
    print(f"    最新: {r['session_id']}  {r['mood_label']}  {str(r['inner_thought'])[:70]}")
    print(f"    时间: {r['updated_at']}")
PY
echo
echo "  4 条以上 = 修好了（原有 3 条 + 新增）"
echo
echo "撤销：cp $BAK $CFG && cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway"
