#!/usr/bin/env bash
# 25 的发现：round 3 命中了 interval（没有 reason=interval 日志），
# 但评估是后台 asyncio 任务，日志在 3 秒内还没落。
# 同时直测暴露出 deepseek-v4-pro 会返回 reasoning_content——
# 即使 thinking_mode=disabled。persona.max_tokens 只有 500，
# 推理过程一吃就把 content 挤空/截断，落到 gateway.py:4898 的
# reason=non_json_response，静默返回，什么都不写。
#
# 本脚本先量化 reasoning 占多少 token，再等足够久抓后台日志。
set -uo pipefail

echo "########## 1. 量化 reasoning_content 吃掉多少预算 ##########"
docker exec -i haven-ombre python - <<'PY'
import yaml, httpx, json
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
p = cfg["persona"]
key = p.get("api_key") or cfg["dehydration"]["api_key"]
base = str(p.get("base_url") or cfg["dehydration"]["base_url"]).rstrip("/")

prompt = ("根据这轮对话评估关系与情绪状态，只返回 JSON："
          '{"affinity":0.86,"trust":0.82,"valence":0.5,"arousal":0.3,'
          '"tenderness":0.6,"mood_label":"warm","inner_thought":"..."}'
          "\n\n用户：今天有点累，陪我说说话\n助手：嗯，累了就来说说话吧，我在的。")

for mt in (500, 2000):
    try:
        r = httpx.post(f"{base}/chat/completions",
                       headers={"Authorization": f"Bearer {key}"},
                       json={"model": p["model"], "max_tokens": mt,
                             "temperature": 0.1,
                             "response_format": {"type": "json_object"},
                             "messages": [{"role": "user", "content": prompt}]},
                       timeout=60)
        d = r.json()
        msg = (d.get("choices") or [{}])[0].get("message", {}) or {}
        fin = (d.get("choices") or [{}])[0].get("finish_reason")
        content = msg.get("content") or ""
        reasoning = msg.get("reasoning_content") or ""
        u = d.get("usage") or {}
        print(f"  --- max_tokens={mt} ---")
        print(f"    finish_reason : {fin}")
        print(f"    completion_tok: {u.get('completion_tokens')}")
        print(f"    reasoning 长度: {len(reasoning)} 字")
        print(f"    content   长度: {len(content)} 字")
        print(f"    content 前120 : {content[:120]!r}")
        ok = False
        try:
            json.loads(content); ok = True
        except Exception:
            pass
        print(f"    content 是合法 JSON: {ok}")
    except Exception as e:
        print(f"  max_tokens={mt}  ERR {str(e)[:120]}")
PY

echo
echo "########## 2. 等后台评估任务落日志（25 跑完可能还没写）##########"
echo "  等 25 秒..."
sleep 25
docker logs --tail 400 haven-gateway 2>&1 \
  | grep -aiE 'persona.*(non_json|failed|background|skipped)' | tail -15 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
echo "  (找 reason=non_json_response 或 update failed)"

echo
echo "########## 3. persona 表现状 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
print("  updated_at:", c.execute("select updated_at from persona_global_state limit 1").fetchone()[0])
PY

echo
echo "########## 4. gateway.py 4890-4905 附近（non_json 判定）##########"
docker exec -i haven-gateway sed -n '4885,4905p' /app/gateway.py

echo
echo "=================================================="
echo "如果第 1 段显示 max_tokens=500 时 content 为空或非法 JSON、"
echo "而 2000 时正常，就跑修复： bash 27-fix-persona.sh"
echo "=================================================="
