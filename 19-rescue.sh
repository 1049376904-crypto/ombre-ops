#!/usr/bin/env bash
# haven-ombre 进了重启循环，先查原因，再修 reranker。只读诊断在前，动手在后。
set -uo pipefail

REPO=/root/Haven-Ombre

echo "########## 1. haven-ombre 为什么起不来（最重要）##########"
docker logs --tail 60 haven-ombre 2>&1 | tail -45 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "########## 2. 当前容器状态 ##########"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'haven|ombre'

echo
echo "########## 3. git remote 指向哪（关键：新代码在不在这个 remote）##########"
cd "$REPO"
git remote -v
echo "--- 最近 5 个提交 ---"
git log --oneline -5
echo "--- reranker_engine.py 是否含 dashscope ---"
grep -c dashscope reranker_engine.py || true

echo
echo "########## 4. 直接从我的 fork 取新版 reranker_engine.py ##########"
URL=https://raw.githubusercontent.com/1049376904-crypto/Haven-Ombre/main/reranker_engine.py
TMP=/tmp/reranker_engine.new.py
if curl -fsSL --max-time 30 "$URL" -o "$TMP"; then
  if grep -q dashscope "$TMP"; then
    echo "  下载成功且含 dashscope（$(wc -l < "$TMP") 行）"
    cp "$REPO/reranker_engine.py" "$REPO/reranker_engine.py.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$TMP" "$REPO/reranker_engine.py"
    echo "  已替换 $REPO/reranker_engine.py（旧版已备份）"
  else
    echo "  !! 下载到的文件不含 dashscope，放弃替换"
  fi
else
  echo "  !! 下载失败（网络或仓库不可达）"
  echo "     备选：仓库可能是私有的。可以用 ombre-ops 里的副本，见第 5 段。"
fi

echo
echo "########## 5. 备选：ombre-ops 里也放了一份副本 ##########"
if [ -f /root/ombre-ops/files/reranker_engine.py ]; then
  echo "  有副本，可执行："
  echo "    cp /root/ombre-ops/files/reranker_engine.py $REPO/reranker_engine.py"
else
  echo "  （下次我会把副本放进 ombre-ops/files/）"
fi

echo
echo "########## 6. 把新代码送进容器并挂载 ##########"
if grep -q dashscope "$REPO/reranker_engine.py" 2>/dev/null; then
  for c in haven-ombre haven-gateway; do
    docker cp "$REPO/reranker_engine.py" "$c:/app/reranker_engine.py" 2>/dev/null \
      && echo "  已复制到 $c" || echo "  复制到 $c 失败（容器可能没在运行）"
  done

  COMPOSE="$REPO/docker-compose.yml"
  if ! grep -q "reranker_engine.py:/app/reranker_engine.py" "$COMPOSE"; then
    cp "$COMPOSE" "${COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"
    REPO="$REPO" COMPOSE="$COMPOSE" python3 - <<'PY'
import os, yaml
path = os.environ["COMPOSE"]; repo = os.environ["REPO"]
mount = f"{repo}/reranker_engine.py:/app/reranker_engine.py"
doc = yaml.safe_load(open(path, encoding="utf-8"))
for svc in ("ombre-brain", "ombre-gateway"):
    node = doc.get("services", {}).get(svc)
    if node is None: continue
    vols = node.setdefault("volumes", [])
    if mount not in vols:
        vols.append(mount); print(f"  {svc} 加挂载")
yaml.safe_dump(doc, open(path, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=False, default_flow_style=False)
PY
    echo "  compose 已加挂载，之后改 .py 只要 restart"
  else
    echo "  compose 已有挂载"
  fi
else
  echo "  跳过：本地还不是新版代码"
fi

echo
echo "########## 7. 起容器（不 build）##########"
cd "$REPO"
docker compose up -d --no-build ombre-brain ombre-gateway 2>&1 | tail -10
sleep 10
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'

echo
echo "########## 8. 还在重启就再看一次日志 ##########"
if docker ps --format '{{.Names}}\t{{.Status}}' | grep -q 'haven-ombre.*Restarting'; then
  echo "  仍在重启循环，最后 30 行："
  docker logs --tail 30 haven-ombre 2>&1 \
    | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
else
  echo "  haven-ombre 已稳定"
  curl -sS --max-time 8 http://127.0.0.1:18001/health 2>/dev/null | head -c 200; echo
fi

echo
echo "########## 9. rerank 实测 ##########"
docker exec -i haven-gateway python - <<'PY' 2>/dev/null || echo "  gateway 不可用"
import asyncio, sys, yaml
sys.path.insert(0, "/app")
from reranker_engine import RerankerEngine
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
eng = RerankerEngine(cfg)
print("  enabled :", eng.enabled)
print("  protocol:", getattr(eng, "protocol", "!! 旧版代码，无此属性"))
print("  endpoint:", eng._endpoint() if hasattr(eng, "_endpoint") else f"{eng.base_url}/rerank")
docs = ["妍妍喜欢闷骚成熟型的语气", "今天天气不错", "学习闷骚风格与专属暗号"]
out = asyncio.run(eng.rerank("回复风格偏好", docs, top_n=3))
for r in out:
    print(f"    [{r.index}] {r.score:.4f}  {docs[r.index]}")
print("  >>> rerank 通了" if out else "  >>> 仍为空")
PY
echo
echo "########## 完毕 ##########"
