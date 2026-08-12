#!/usr/bin/env bash
# 前两个假设都被证伪了（403 / reasoning 吃 token），不再猜。
# 这次直接读代码路径 + 在容器里手动跑一次评估，看它返回什么、卡在哪个 if。
set -uo pipefail

echo "########## 1. round 3 的结局（前面 tail 截断了）##########"
docker logs --tail 800 haven-gateway 2>&1 \
  | grep -aE 'Persona post-reply|Persona.*background|round=3|round completed' \
  | tail -20 | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "########## 2. 评估的完整代码路径 ##########"
echo "--- gateway.py 4905-5000 ---"
docker exec -i haven-gateway sed -n '4905,5000p' /app/gateway.py

echo
echo "--- _schedule_persona_post_reply_update 5100-5135 ---"
docker exec -i haven-gateway sed -n '5100,5135p' /app/gateway.py

echo
echo "########## 3. persona_engine 里写库的函数 ##########"
docker exec -i haven-gateway sh -lc '
  grep -n "def evaluate\|def record_\|def update_\|def _write\|INSERT INTO persona\|def apply" /app/persona_engine.py | head -30'

echo
echo "########## 4. 手动跑一次评估，看返回值和异常 ##########"
docker exec -i haven-gateway python - <<'PY'
import asyncio, sys, traceback, yaml, inspect
sys.path.insert(0, "/app")
import utils
from persona_engine import PersonaEngine

cfg = utils.load_config() if hasattr(utils, "load_config") else yaml.safe_load(
    open("/app/config.yaml", encoding="utf-8"))

try:
    eng = PersonaEngine(cfg)
except TypeError:
    eng = PersonaEngine(cfg, None)
print("  enabled:", getattr(eng, "enabled", "?"))
print("  mode   :", getattr(eng, "mode", "?"))
print("  db     :", getattr(eng, "db_path", getattr(eng, "state_path", "?")))

# 列出可能的评估入口
cands = [n for n in dir(eng)
         if any(w in n.lower() for w in ("evaluate", "observe", "after", "update"))
         and not n.startswith("__")]
print("  候选方法:", cands[:15])

async def main():
    for name in ("evaluate_exchange", "evaluate", "observe_exchange",
                 "update_after_exchange", "process_exchange"):
        fn = getattr(eng, name, None)
        if fn is None:
            continue
        sig = str(inspect.signature(fn))
        print(f"\n  >>> 尝试 {name}{sig}")
        kw = dict(session_id="manual-test",
                  user_message="我有点想你了",
                  assistant_message="想你也是。刚好也有点记挂你。")
        params = inspect.signature(fn).parameters
        kw = {k: v for k, v in kw.items() if k in params}
        for alt_u, alt_a in (("user_text", "assistant_text"), ("user", "assistant")):
            if alt_u in params and "user_message" not in kw:
                kw[alt_u] = "我有点想你了"
            if alt_a in params and "assistant_message" not in kw:
                kw[alt_a] = "想你也是。"
        try:
            r = fn(**kw)
            if asyncio.iscoroutine(r):
                r = await r
            print("      返回:", str(r)[:400])
        except Exception:
            print("      异常:")
            traceback.print_exc(limit=6)
        break

asyncio.run(main())
PY

echo
echo "########## 5. 手动跑完，表变了吗 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
print("  updated_at:", c.execute("select updated_at from persona_global_state limit 1").fetchone()[0])
PY

echo
echo "########## 6. 顺带查：core memory 真的进上下文了吗 ##########"
echo "（刚才第 2 轮回复带了 emoji，而 pinned 桶里写着你排斥 emoji）"
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
curl -sS --max-time 12 -H "Authorization: Bearer $TOKEN" \
  'http://127.0.0.1:18003/api/debug/injections?limit=1&include_context=true' 2>/dev/null \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
items = data if isinstance(data, list) else data.get("items", [])
if not items:
    print("  无记录"); sys.exit()
p = items[0].get("payload", {})
s = p.get("stable_context") or ""
print("  round:", items[0].get("round_id"), " session:", items[0].get("session_id"))
print("  stable_context:", len(s), "字符")
print(s[:900] if s else "  (空 —— core memory 没进去)")
'

echo
echo "########## 完毕 ##########"
