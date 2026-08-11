#!/usr/bin/env bash
# 改 config.yaml 的 6 项，然后重启两个容器让改动生效。
# 改前自动备份成 config.yaml.bak.<时间戳>。
# 中风险：会重启 haven-ombre 和 haven-gateway，期间聊天短暂不可用（约 10-30 秒）。
set -uo pipefail

CFG=/root/Haven-Ombre/config.yaml
COMPOSE_DIR=/root/Haven-Ombre

[ -f "$CFG" ] || { echo "找不到 $CFG"; exit 1; }

BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CFG" "$BAK"
echo "已备份到 $BAK"
echo

docker exec -i haven-ombre python - <<'PY'
import yaml, io, sys

path = "/app/config.yaml"
with open(path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

changes = []

def setv(section, key, new, why):
    node = cfg if section is None else cfg.setdefault(section, {})
    old = node.get(key, "(未设置)")
    if old == new:
        changes.append(f"  = {section or ''}.{key} 已经是 {new!r}，跳过")
        return
    node[key] = new
    changes.append(f"  * {section or ''}.{key}: {old!r} -> {new!r}   # {why}")

# 1. 让 10 个 permanent/pinned 桶真正每轮在场
setv("gateway", "core_memory_budget", 400, "原来是 0 = 永不注入核心记忆")

# 2. 清掉原作者的 bucket id
setv("dream", "identity_anchor_id", "", "原值 c0b8ddb7423e 是原作者的桶，本库不存在")

# 3. 词图是空的，hint 开着没意义
setv("gateway", "word_map_hint_enabled", False, "word_map.enabled=false，hint 无数据可用")

# 4. 思考模式下 700 token 会把日印象截断
setv("reflection", "max_tokens", 2000, "thinking_mode=enabled 时 700 太少，易截断成空")

# 5. 两个 legacy 项关回默认
setv("reflection", "memory_affect_anchor_enabled", False, "legacy，新写入不该再追加 affect_anchor")
setv("reflection", "relationship_weather_affect_anchor_enabled", False, "legacy 同上")

# 6. 打开召回诊断，之后才查得到为什么召回为空
setv("recall_diagnostics", "enabled", True, "排查召回必需")

print("将要做的修改：")
for line in changes:
    print(line)

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=True, default_flow_style=False)
print("\nconfig.yaml 已写入。")
PY

rc=$?
if [ "$rc" != "0" ]; then
  echo
  echo "!! 修改失败，正在回滚"
  cp "$BAK" "$CFG"
  echo "已回滚到 $BAK"
  exit 1
fi

echo
echo "校验 YAML 是否还能正常解析..."
docker exec haven-ombre python -c "import yaml;yaml.safe_load(open('/app/config.yaml',encoding='utf-8'));print('  OK')" || {
  echo "!! YAML 坏了，回滚"; cp "$BAK" "$CFG"; exit 1;
}

echo
echo "=================================================="
echo "改完了。现在需要重启才生效："
echo
echo "    cd $COMPOSE_DIR && docker compose up -d"
echo
echo "如果想撤销：cp $BAK $CFG  然后同样重启。"
echo "=================================================="
