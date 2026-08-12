#!/usr/bin/env bash
# 重开 persona 情绪注入和 dream 注入。
# 默认 dry-run，加 --write 执行。
set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

CFG=/root/Haven-Ombre/config.yaml

echo "########## 当前值 ##########"
docker exec -i haven-ombre python - <<'PY'
import yaml
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
g, d, p = cfg.get("gateway", {}), cfg.get("dream", {}), cfg.get("persona", {})
print(f"  gateway.current_inner_state_interval_rounds : {g.get('current_inner_state_interval_rounds')}   -> 15")
print(f"  dream.inject_enabled                       : {d.get('inject_enabled')}  -> True")
print()
print(f"  （不动）persona.enabled            : {p.get('enabled')}")
print(f"  （不动）persona.event_recording    : {p.get('event_recording_enabled')}")
PY

if [ "$WRITE" != "1" ]; then
  echo
  echo "=================================================="
  echo "以上是 dry-run。要执行： bash 37-reopen-persona-dream.sh --write"
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

setv("gateway", "current_inner_state_interval_rounds", 15)
setv("dream", "inject_enabled", True)

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
echo "重开完成。persona 的 inner_thought 和 dream 会再次注入。"
echo
echo "撤销：cp $BAK $CFG && cd /root/Haven-Ombre && docker compose restart ombre-gateway"
echo "=================================================="
