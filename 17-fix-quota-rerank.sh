#!/usr/bin/env bash
# 两件事：
#   1. deepseek-v4-flash 免费额度已耗尽（403）。dehydration 和 dream 都用它。
#      换成实测 200 的 glm-5。
#   2. rerank 接阿里 DashScope 原生端点。
#      需要先在 Haven-Ombre 仓库 git pull 拿到新版 reranker_engine.py，
#      并重新 build 镜像（代码是 COPY 进镜像的，不是挂载）。
#
# 改前自动备份 config.yaml。
set -uo pipefail

REPO=/root/Haven-Ombre
CFG="$REPO/config.yaml"
HOST=https://ws-6u6u948ov18iuv19.cn-beijing.maas.aliyuncs.com

[ -f "$CFG" ] || { echo "找不到 $CFG"; exit 1; }

BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CFG" "$BAK"
echo "已备份 config.yaml -> $BAK"
echo

echo "########## 1. 拉取新版 reranker_engine.py ##########"
cd "$REPO"
git stash list >/dev/null 2>&1
echo "  当前分支: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if git pull --ff-only 2>&1 | tail -5; then
  echo "  pull 完成"
else
  echo "  !! pull 失败。如果 config.yaml 被 git 跟踪导致冲突，"
  echo "     可以先 git stash 再 pull，然后 git stash pop。"
  echo "     或手动检查冲突后重跑本脚本。"
  exit 1
fi
echo "  reranker_engine.py 是否含 dashscope 支持："
grep -c "dashscope" reranker_engine.py || echo "  0 —— 没拉到新版，先确认远端已更新"

echo
echo "########## 2. 改 config.yaml ##########"
HOST="$HOST" python3 - <<'PY'
import os, yaml

path = "/root/Haven-Ombre/config.yaml"
host = os.environ["HOST"]
with open(path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

changes = []

def setv(section, key, new, why):
    node = cfg.setdefault(section, {})
    old = node.get(key, "(未设置)")
    if old == new:
        changes.append(f"  = {section}.{key} 已是 {new!r}")
        return
    node[key] = new
    changes.append(f"  * {section}.{key}: {old!r} -> {new!r}\n      {why}")

# deepseek-v4-flash 403，换 glm-5（实测 OK）
setv("dehydration", "model", "glm-5",
     "deepseek-v4-flash 免费额度耗尽。脱水/打标是写入链路的核心，必须可用。")
setv("dream", "model", "glm-5",
     "同上。夜梦也走这个模型。")

# rerank 走 DashScope 原生
setv("reranker", "base_url",
     f"{host}/api/v1/services/rerank/text-rerank/text-rerank",
     "实测唯一返回 200 的端点。阿里没有 OpenAI 兼容的 rerank 路径。")
setv("reranker", "protocol", "dashscope",
     "新增字段：用 input.documents / parameters 格式，读 output.results。")

print("将要做的修改：")
for line in changes:
    print(line)

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=True, default_flow_style=False)
print("\nconfig.yaml 已写入")
PY

if [ "$?" != "0" ]; then
  echo "!! 改配置失败，回滚"; cp "$BAK" "$CFG"; exit 1
fi

python3 -c "import yaml;yaml.safe_load(open('$CFG',encoding='utf-8'));print('YAML 校验 OK')" || {
  echo "!! YAML 坏了，回滚"; cp "$BAK" "$CFG"; exit 1; }

echo
echo "########## 3. 重新 build 并起容器 ##########"
echo "（代码是 COPY 进镜像的，改了 .py 必须 build，restart 不够）"
cd "$REPO"
docker compose up -d --build ombre-brain ombre-gateway 2>&1 | tail -20

echo
sleep 8
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'

echo
echo "########## 4. 验证 rerank 是否通了 ##########"
docker exec -i haven-gateway python - <<'PY'
import asyncio, yaml, sys
sys.path.insert(0, "/app")
from reranker_engine import RerankerEngine

cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
eng = RerankerEngine(cfg)
print("  enabled :", eng.enabled)
print("  protocol:", eng.protocol)
print("  endpoint:", eng._endpoint())
print("  model   :", eng.model)

docs = ["妍妍喜欢闷骚成熟型的语气", "今天天气不错", "学习闷骚风格与专属暗号"]
out = asyncio.run(eng.rerank("回复风格偏好", docs, top_n=3))
if out:
    print("  结果：")
    for r in out:
        print(f"    [{r.index}] {r.score:.4f}  {docs[r.index]}")
    print("  rerank 通了")
else:
    print("  仍返回空，看 docker logs haven-gateway 里的 Reranker 警告")
PY

echo
echo "########## 5. 确认 403 的模型都换掉了 ##########"
docker exec -i haven-gateway python - <<'PY'
import yaml, httpx
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
key = cfg["dehydration"].get("api_key", "")
for label, sec in (("dehydration", "dehydration"), ("dream", "dream")):
    s = cfg.get(sec, {})
    base = str(s.get("base_url") or cfg["dehydration"]["base_url"]).rstrip("/")
    try:
        r = httpx.post(f"{base}/chat/completions",
                       headers={"Authorization": f"Bearer {s.get('api_key') or key}"},
                       json={"model": s.get("model"), "max_tokens": 1,
                             "messages": [{"role": "user", "content": "hi"}]},
                       timeout=25)
        print(f"  {r.status_code}  {label}: {s.get('model')}")
    except Exception as e:
        print(f"  ERR {label}: {str(e)[:80]}")
PY

echo
echo "=================================================="
echo "撤销配置：cp $BAK $CFG"
echo "然后：cd $REPO && docker compose up -d --build ombre-brain ombre-gateway"
echo
echo "接着实测一轮召回： bash /root/ombre-ops/13-final.sh"
echo "=================================================="
