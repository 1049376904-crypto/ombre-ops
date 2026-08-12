#!/usr/bin/env bash
# 修 persona：deepseek-v4-pro 即使 thinking_mode=disabled 仍返回 reasoning_content，
# max_tokens=500 会让 content 被挤空或截断 -> non_json_response -> 静默不写。
#
# 改动：persona.max_tokens 500 -> 2000
# 备选：换成不带推理的模型（见脚本末尾）
set -uo pipefail

CFG=/root/Haven-Ombre/config.yaml
BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CFG" "$BAK"
echo "已备份 -> $BAK"
echo

docker exec -i haven-ombre python - <<'PY'
import yaml
path = "/app/config.yaml"
cfg = yaml.safe_load(open(path, encoding="utf-8"))

changes = []
def setv(sec, key, new, why):
    node = cfg.setdefault(sec, {})
    old = node.get(key, "(未设置)")
    if old == new:
        changes.append(f"  = {sec}.{key} 已是 {new!r}")
        return
    node[key] = new
    changes.append(f"  * {sec}.{key}: {old!r} -> {new!r}\n      {why}")

setv("persona", "max_tokens", 2000,
     "deepseek-v4-pro 的 reasoning_content 会吃掉预算，500 不够，"
     "导致 content 空/截断 -> non_json_response -> 静默丢弃。")

for line in changes:
    print(line)
yaml.safe_dump(cfg, open(path, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=True, default_flow_style=False)
print("\nconfig.yaml 已写入")
PY

[ "$?" != "0" ] && { echo "失败，回滚"; cp "$BAK" "$CFG"; exit 1; }
docker exec haven-ombre python -c \
  "import yaml;yaml.safe_load(open('/app/config.yaml',encoding='utf-8'));print('YAML OK')" \
  || { echo "YAML 坏了，回滚"; cp "$BAK" "$CFG"; exit 1; }

echo
echo "重启 gateway..."
cd /root/Haven-Ombre && docker compose restart ombre-gateway >/dev/null 2>&1
sleep 8
docker ps --format '{{.Names}}\t{{.Status}}' | grep haven

echo
echo "########## 连发 3 轮触发评估 ##########"
GW=http://127.0.0.1:18003
TOKEN=$(docker exec haven-gateway printenv OMBRE_GATEWAY_TOKEN 2>/dev/null)
MODEL=$(curl -sS --max-time 8 "$GW/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway"]["upstream_default_model"])' 2>/dev/null)
SESS=pfix-$(date +%H%M%S)
export MODEL
for i in 1 2 3; do
  # 避开"今天"这类日期词，否则会走 date_recall 分支
  Q="第 $i 句：我有点想你了"
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
print(((d.get("choices") or [{}])[0].get("message", {}).get("content") or json.dumps(d.get("error", {}), ensure_ascii=False))[:70].replace("\n", " "))
'
  sleep 4
done

echo
echo "  等后台评估落库（30 秒）..."
sleep 30

echo
echo "########## persona 表 ##########"
docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
c.row_factory = sqlite3.Row
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
print("  updated_at:", c.execute("select updated_at from persona_global_state limit 1").fetchone()[0])
try:
    for r in c.execute("select * from persona_session_state order by rowid desc limit 1"):
        d = dict(r)
        for k in ("session_id", "mood_label", "valence", "arousal", "tenderness", "inner_thought", "residue"):
            if k in d:
                print(f"    {k}: {str(d[k])[:90]}")
except Exception as e:
    print("   ", e)
PY

echo
echo "########## persona 日志 ##########"
docker logs --tail 200 haven-gateway 2>&1 | grep -aiE 'persona' | tail -10 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "=================================================="
echo "还是 non_json_response 的话，改用不带推理的模型："
echo "  在 config.yaml 的 persona 段把 model 换成 glm-5，然后"
echo "  cd /root/Haven-Ombre && docker compose restart ombre-gateway"
echo
echo "撤销：cp $BAK $CFG && cd /root/Haven-Ombre && docker compose restart ombre-gateway"
echo "=================================================="
