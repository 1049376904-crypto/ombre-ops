#!/usr/bin/env bash
# 两件事：
#  A. persona：round=3 命中了 interval（没有 skipped 日志），也没有 failed 日志，
#     说明 update_from_exchange 跑完了但没写库 -> 门槛在函数内部。直接读它。
#     顺带修正类名：是 PersonaStateEngine，不是 PersonaEngine。
#  B. core memory：只注入了 1 个桶（环境数据API，正文是冗长 JSON），
#     400 token 预算被它一个吃满，回复风格偏好等桶排在后面全被挤掉。
#     列出所有 pinned/protected 桶的体积和 importance，好定预算。
set -uo pipefail

echo "########## A1. update_from_exchange 的实现（473 起）##########"
docker exec -i haven-gateway sed -n '473,600p' /app/persona_engine.py

echo
echo "########## A2. 写库函数附近（840-930）##########"
docker exec -i haven-gateway sed -n '840,930p' /app/persona_engine.py

echo
echo "########## A3. 手动调一次（类名 PersonaStateEngine）##########"
docker exec -i haven-gateway python - <<'PY'
import asyncio, sys, inspect, traceback, yaml, logging
logging.basicConfig(level=logging.DEBUG, format="  LOG %(name)s %(levelname)s: %(message)s")
sys.path.insert(0, "/app")
from persona_engine import PersonaStateEngine

cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
try:
    eng = PersonaStateEngine(cfg)
except TypeError as e:
    print("  构造需要额外参数:", e)
    print("  签名:", inspect.signature(PersonaStateEngine.__init__))
    raise SystemExit(1)

print("  enabled:", getattr(eng, "enabled", "?"))
print("  mode:", getattr(eng, "mode", "?"))
print("  model:", getattr(eng, "model", "?"))
print("  db_path:", getattr(eng, "db_path", getattr(eng, "state_path", "?")))
print("  interval:", getattr(eng, "evaluation_interval_rounds", "?"))
print("  event_recording_enabled:", getattr(eng, "event_recording_enabled", "?"))
print("  update_from_exchange 签名:", inspect.signature(eng.update_from_exchange))

async def main():
    try:
        r = await eng.update_from_exchange(
            session_id="manual-test",
            user_message="我有点想你了",
            assistant_response="想你也是。刚好也有点记挂你。",
            recalled_memory_ids=[],
            tool_summary="",
            recent_conversation_turns=[],
        )
        print("  返回值:", str(r)[:600])
    except Exception:
        traceback.print_exc(limit=8)

asyncio.run(main())
PY

echo
echo "########## A4. 手动调用后表变了吗 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
print("  updated_at:", c.execute("select updated_at from persona_global_state limit 1").fetchone()[0])
PY

echo
echo "########## A5. 引擎写的是哪个 db 文件（会不会写错地方）##########"
docker exec -i haven-gateway python - <<'PY'
import sys, yaml
sys.path.insert(0, "/app")
from persona_engine import PersonaStateEngine
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
eng = PersonaStateEngine(cfg)
for attr in ("db_path", "state_path", "state_dir", "path"):
    if hasattr(eng, attr):
        print(f"  {attr}: {getattr(eng, attr)}")
print("  config buckets_dir:", cfg.get("buckets_dir"))
print("  config state_dir  :", cfg.get("state_dir"))
PY
echo "  --- 容器里所有 persona_state.db ---"
docker exec -i haven-gateway sh -lc 'find / -name "persona_state.db" -not -path "*/proc/*" 2>/dev/null | while read f; do echo "    $f  $(stat -c %s "$f") bytes  $(stat -c %y "$f")"; done'

echo
echo "########## B1. 所有 pinned/protected 桶：体积与 importance ##########"
docker exec -i haven-ombre python - <<'PY'
import glob, re, os

def fm(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return (m.group(1), text[m.end():]) if m else ("", text)

rows = []
for p in glob.glob("/app/buckets/**/*.md", recursive=True):
    try:
        t = open(p, encoding="utf-8").read()
    except Exception:
        continue
    head, body = fm(t)
    if not re.search(r"^(pinned|protected)\s*:\s*true", head, re.M):
        continue
    imp = re.search(r"^importance\s*:\s*(\d+)", head, re.M)
    la = re.search(r"^last_active\s*:\s*'?([^'\n]+)", head, re.M)
    name = re.search(r"^name\s*:\s*(.+)$", head, re.M)
    bid = re.search(r"^id\s*:\s*(\S+)", head, re.M)
    # token 粗估：中文 1.5 字/token
    approx = int(len(body) / 1.5)
    rows.append((int(imp.group(1)) if imp else 0,
                 la.group(1) if la else "",
                 name.group(1).strip() if name else os.path.basename(p),
                 bid.group(1) if bid else "?",
                 len(body), approx))

rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
print(f"  共 {len(rows)} 个（按 importance desc, last_active desc 排，就是注入顺序）")
print(f"  {'imp':>3} {'字数':>6} {'≈token':>7}  {'id':<14} 名称")
cum = 0
for imp, la, name, bid, chars, approx in rows:
    cum += approx
    flag = "  <= 400 预算在这里用光" if cum > 400 and cum - approx <= 400 else ""
    print(f"  {imp:>3} {chars:>6} {approx:>7}  {bid:<14} {name[:34]}{flag}")
print(f"  累计 ≈{cum} token，而 core_memory_budget = 400")
PY

echo
echo "########## B2. 当前预算配置 ##########"
docker exec -i haven-ombre python -c "
import yaml
g=yaml.safe_load(open('/app/config.yaml',encoding='utf-8'))['gateway']
for k in ('core_memory_budget','inject_total_budget','recalled_memory_budget','recent_context_budget','related_memory_budget'):
    print('  %s: %s'%(k,g.get(k)))
print('  注意：stable_tokens >= inject_total_budget 时，dynamic 会被整个丢弃（源码 17981）')
"

echo
echo "########## 完毕 ##########"
