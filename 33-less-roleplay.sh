#!/usr/bin/env bash
# 减少「扮演感」的第一步：只改配置，不动任何记忆内容。
#
#   1. gateway.current_inner_state_interval_rounds 15 -> 0
#      不再把 persona 的 mood / inner_thought 当作状态指导塞给模型。
#      persona 仍在后台记录，Dashboard 照样能看。
#   2. dream.inject_enabled true -> false
#      不再每轮偷偷塞一条梦境联想。后台仍然做梦，可在 Dashboard 读。
#   3. gateway.recall_admission_semantic_score 0.55 -> 0.62
#      0.55 是我今天为了修召回调下来的，副作用是那些反复提到
#      「语气/风格」的桶太容易被翻出来。0.62 是折中。
#
# 全部可逆。默认 dry-run，加 --write 执行。
set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

CFG=/root/Haven-Ombre/config.yaml

echo "########## 当前值 ##########"
docker exec -i haven-ombre python - <<'PY'
import yaml
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
g, d, p = cfg.get("gateway", {}), cfg.get("dream", {}), cfg.get("persona", {})
print(f"  gateway.current_inner_state_interval_rounds : {g.get('current_inner_state_interval_rounds')}   -> 0")
print(f"  dream.inject_enabled                       : {d.get('inject_enabled')}   -> False")
print(f"  gateway.recall_admission_semantic_score    : {g.get('recall_admission_semantic_score')}  -> 0.62")
print()
print(f"  （不动）persona.enabled            : {p.get('enabled')}  后台继续记录")
print(f"  （不动）persona.event_recording    : {p.get('event_recording_enabled')}")
print(f"  （不动）gateway.core_memory_*      : interval={g.get('core_memory_interval_rounds')} budget={g.get('core_memory_budget')}")
PY

if [ "$WRITE" != "1" ]; then
  echo
  echo "=================================================="
  echo "以上是 dry-run。要执行： bash 33-less-roleplay.sh --write"
  echo "=================================================="
  exit 0
fi

BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CFG" "$BAK"
echo
echo "已备份 -> $BAK"

docker exec -i haven-ombre python - <<'PY'
import yaml
p = "/app/config.yaml"
cfg = yaml.safe_load(open(p, encoding="utf-8"))

def setv(sec, key, new):
    node = cfg.setdefault(sec, {})
    old = node.get(key, "(未设置)")
    node[key] = new
    print(f"  {sec}.{key}: {old!r} -> {new!r}")

setv("gateway", "current_inner_state_interval_rounds", 0)
setv("dream", "inject_enabled", False)
setv("gateway", "recall_admission_semantic_score", 0.62)

yaml.safe_dump(cfg, open(p, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=True, default_flow_style=False)
print("  已写入")
PY

docker exec haven-ombre python -c \
  "import yaml;yaml.safe_load(open('/app/config.yaml',encoding='utf-8'));print('  YAML OK')" \
  || { echo "  YAML 坏了，回滚"; cp "$BAK" "$CFG"; exit 1; }

echo
echo "重启 gateway..."
cd /root/Haven-Ombre && docker compose restart ombre-gateway >/dev/null 2>&1
sleep 10
docker ps --format '{{.Names}}\t{{.Status}}' | grep haven

echo
echo "=================================================="
echo "改完了。下次你在 dwell 里正常聊天时留意语气变化，"
echo "不用专门发测试请求（省 token）。"
echo
echo "撤销：cp $BAK $CFG && cd /root/Haven-Ombre && docker compose restart ombre-gateway"
echo "=================================================="
