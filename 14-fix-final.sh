#!/usr/bin/env bash
# 两处根因修复：
#   1. core_memory_interval_rounds: 0 -> 1
#      源码 _should_inject_interval() 里 interval<=0 直接 return False，
#      所以 0 = 永不注入。10 个 pinned/protected 桶因此从未进过上下文。
#   2. recall_admission_semantic_score: 0.72 -> 0.55
#      实测候选 semantic_score=0.58，因为 0.58<0.72 且无 exact 命中，
#      被判 semantic_only 拦下。降到 0.55 让这类候选能进。
#   3. 可选：semantic_rescue_enabled -> true
#      专门给 semantic_only 候选做一次廉价校验后放行。
#
# 改前自动备份。改完需要重启容器。
set -uo pipefail

CFG=/root/Haven-Ombre/config.yaml
[ -f "$CFG" ] || { echo "找不到 $CFG"; exit 1; }

BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CFG" "$BAK"
echo "已备份到 $BAK"
echo

docker exec -i haven-ombre python - <<'PY'
import yaml

path = "/app/config.yaml"
with open(path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

changes = []

def setv(section, key, new, why):
    node = cfg.setdefault(section, {})
    old = node.get(key, "(未设置)")
    if old == new:
        changes.append(f"  = {section}.{key} 已是 {new!r}，跳过")
        return
    node[key] = new
    changes.append(f"  * {section}.{key}: {old!r} -> {new!r}\n      理由: {why}")

setv("gateway", "core_memory_interval_rounds", 1,
     "源码里 interval<=0 直接 return False。0=永不注入，1=每轮注入。"
     "这是 10 个 pinned 桶从未在场的直接原因。")

setv("gateway", "recall_admission_semantic_score", 0.55,
     "实测候选 semantic_score=0.58 被 0.72 拦下判为 semantic_only。"
     "0.55 让纯语义命中也能进，代价是偶尔多召回一条弱相关。")

setv("gateway", "semantic_rescue_enabled", True,
     "专门救 semantic_only 候选：一次廉价模型调用校验证据片段后放行。"
     "每轮最多 3 个候选、220 token，成本很低。")

print("将要做的修改：")
for line in changes:
    print(line)

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=True, default_flow_style=False)
print("\n已写入 config.yaml")
PY

rc=$?
if [ "$rc" != "0" ]; then
  echo "!! 失败，回滚"; cp "$BAK" "$CFG"; exit 1
fi

docker exec haven-ombre python -c \
  "import yaml;yaml.safe_load(open('/app/config.yaml',encoding='utf-8'));print('YAML 校验 OK')" || {
  echo "!! YAML 坏了，回滚"; cp "$BAK" "$CFG"; exit 1; }

echo
echo "重启两个服务让配置生效..."
cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway
sleep 6

echo
echo "确认已重启："
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'

echo
echo "确认新值已读入："
docker exec -i haven-ombre python - <<'PY'
import yaml
g = yaml.safe_load(open("/app/config.yaml", encoding="utf-8")).get("gateway", {})
for k in ("core_memory_interval_rounds", "core_memory_budget",
          "recall_admission_semantic_score", "semantic_rescue_enabled"):
    print(f"  {k}: {g.get(k)}")
PY

echo
echo "=================================================="
echo "改完了。现在实测一轮："
echo "    bash 13-final.sh"
echo "期望：stable_context 不再是 0 字符，出现 Core Memory 段落。"
echo
echo "撤销：cp $BAK $CFG && cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway"
echo "=================================================="
