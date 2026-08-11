#!/usr/bin/env bash
# build 卡在网络上时用这个。完全不 build。
#
# 思路：代码本来是 COPY 进镜像的，所以改 .py 要 build。
# 但我们可以把单个文件 bind mount 进容器，之后改文件只要 restart。
# 先 docker cp 立刻生效验证，再改 compose 让它重启后依然生效。
#
# 前置：先 Ctrl+C 掉卡住的 build。
set -uo pipefail

REPO=/root/Haven-Ombre
CFG="$REPO/config.yaml"
COMPOSE="$REPO/docker-compose.yml"
F=reranker_engine.py

echo "########## 0. 确认宿主机上已是新版代码 ##########"
if [ ! -f "$REPO/$F" ]; then
  echo "  !! 找不到 $REPO/$F"; exit 1
fi
if grep -q "dashscope" "$REPO/$F"; then
  echo "  OK  $F 含 dashscope 支持"
else
  echo "  !! $F 还是旧版。先在 $REPO 里 git pull："
  echo "     cd $REPO && git stash && git pull --ff-only && git stash pop"
  exit 1
fi

echo
echo "########## 1. 确认 17 的 config 改动在不在 ##########"
python3 - <<'PY'
import yaml
cfg = yaml.safe_load(open("/root/Haven-Ombre/config.yaml", encoding="utf-8"))
r = cfg.get("reranker", {})
print("  dehydration.model:", cfg.get("dehydration", {}).get("model"))
print("  dream.model      :", cfg.get("dream", {}).get("model"))
print("  reranker.base_url:", r.get("base_url"))
print("  reranker.protocol:", r.get("protocol"))
print("  期望: glm-5 / glm-5 / .../services/rerank/text-rerank/text-rerank / dashscope")
PY

echo
echo "########## 2. docker cp 新代码进两个容器（立刻生效）##########"
for c in haven-ombre haven-gateway; do
  docker cp "$REPO/$F" "$c:/app/$F" && echo "  已复制到 $c"
done

echo
echo "########## 3. 在 compose 里加 bind mount，让重启后依然生效 ##########"
CBAK="${COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$COMPOSE" "$CBAK"
echo "  compose 已备份 -> $CBAK"

REPO="$REPO" COMPOSE="$COMPOSE" python3 - <<'PY'
import os, yaml

path = os.environ["COMPOSE"]
repo = os.environ["REPO"]
mount = f"{repo}/reranker_engine.py:/app/reranker_engine.py"

with open(path, encoding="utf-8") as f:
    doc = yaml.safe_load(f)

changed = []
for svc in ("ombre-brain", "ombre-gateway"):
    node = doc.get("services", {}).get(svc)
    if not node:
        continue
    vols = node.setdefault("volumes", [])
    if mount in vols:
        changed.append(f"  = {svc} 已有该挂载")
        continue
    vols.append(mount)
    changed.append(f"  * {svc} 新增挂载 {mount}")

for line in changed:
    print(line)

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(doc, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
print("  docker-compose.yml 已写入")
PY

if [ "$?" != "0" ]; then
  echo "  !! 改 compose 失败，回滚"; cp "$CBAK" "$COMPOSE"; exit 1
fi

echo
echo "########## 4. 重建容器（不 build，用现有镜像）##########"
echo "  注意：挂载变了，compose 会 recreate 容器。"
echo "  /state 已经是 bind mount，数据不会丢。"
cd "$REPO"
docker compose up -d --no-build ombre-brain ombre-gateway 2>&1 | tail -15

sleep 8
echo
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'

echo
echo "########## 5. 验证挂载和代码 ##########"
docker inspect haven-gateway --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' \
  | grep -i reranker || echo "  !! 挂载没生效"
docker exec haven-gateway grep -c dashscope /app/reranker_engine.py \
  && echo "  容器内代码是新版" || echo "  !! 容器内还是旧版"

echo
echo "########## 6. 实打一次 rerank ##########"
docker exec -i haven-gateway python - <<'PY'
import asyncio, sys, yaml
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
    for r in out:
        print(f"    [{r.index}] {r.score:.4f}  {docs[r.index]}")
    print("  >>> rerank 通了")
else:
    print("  >>> 仍为空，看 docker logs haven-gateway | grep -i rerank")
PY

echo
echo "########## 7. 确认换模型后不再 403 ##########"
docker exec -i haven-gateway python - <<'PY'
import yaml, httpx
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
base_default = cfg["dehydration"]["base_url"].rstrip("/")
key_default = cfg["dehydration"].get("api_key", "")
for label in ("dehydration", "dream"):
    s = cfg.get(label, {}) or {}
    base = str(s.get("base_url") or base_default).rstrip("/")
    try:
        r = httpx.post(f"{base}/chat/completions",
                       headers={"Authorization": f"Bearer {s.get('api_key') or key_default}"},
                       json={"model": s.get("model"), "max_tokens": 1,
                             "messages": [{"role": "user", "content": "hi"}]},
                       timeout=25)
        print(f"  {r.status_code}  {label}: {s.get('model')}")
    except Exception as e:
        print(f"  ERR {label}: {str(e)[:80]}")
PY

echo
echo "=================================================="
echo "以后改任何 .py 都可以照这个套路："
echo "  1. 在 $REPO 里 git pull"
echo "  2. 给该文件在 compose 加一行挂载（只需一次）"
echo "  3. docker compose restart ombre-brain ombre-gateway"
echo "彻底不用 build。"
echo
echo "撤销挂载：cp $CBAK $COMPOSE && cd $REPO && docker compose up -d --no-build"
echo "接着实测召回： bash /root/ombre-ops/13-final.sh"
echo "=================================================="
