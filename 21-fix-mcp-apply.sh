#!/usr/bin/env bash
# 修 ModuleNotFoundError: No module named 'mcp.server.fastmcp'
#
# 原因：requirements.txt 写的是 mcp>=1.0.0（没钉上限），
# 这次 build 装到了 mcp 2.x，新版把 FastMCP 从 mcp.server.fastmcp 移走了。
#
# 做法：不 build。把 mcp<2 装到宿主机的 /root/ombre-vendor，
# 挂进容器并用 PYTHONPATH 让它优先于容器自带的新版。
# 好处：recreate 也不会丢，以后想换版本只要改这个目录。
#
# 数据完全不动：buckets 是 /data/haven-ombre 下的 Markdown，state 是 bind mount。
set -uo pipefail

REPO=/root/Haven-Ombre
COMPOSE="$REPO/docker-compose.yml"
VENDOR=/root/ombre-vendor
IMG=$(docker inspect haven-ombre --format '{{.Config.Image}}' 2>/dev/null || echo haven-ombre-ombre-brain)

echo "########## 1. 先钉住 requirements.txt（防止以后 build 再犯）##########"
if grep -qE '^mcp<2|^mcp>=1\.0\.0,<2' "$REPO/requirements.txt"; then
  echo "  已经钉过了"
else
  cp "$REPO/requirements.txt" "$REPO/requirements.txt.bak.$(date +%Y%m%d_%H%M%S)"
  sed -i 's/^mcp>=1\.0\.0$/mcp>=1.0.0,<2/' "$REPO/requirements.txt"
  echo "  已改为："; grep -nE '^mcp' "$REPO/requirements.txt"
fi

echo
echo "########## 2. 用临时容器把 mcp<2 装到宿主机 $VENDOR ##########"
mkdir -p "$VENDOR"
echo "  镜像: $IMG"
echo "  安装中（只下载一个包，比 build 快很多）..."
docker run --rm -v "$VENDOR:/vendor" --entrypoint pip "$IMG" \
  install --no-cache-dir --target /vendor 'mcp<2' 2>&1 | tail -8

echo
echo "  装到的版本："
ls -d "$VENDOR"/mcp-*.dist-info 2>/dev/null | xargs -r -n1 basename
echo "  fastmcp 路径检查："
if [ -d "$VENDOR/mcp/server/fastmcp" ]; then
  echo "  OK  $VENDOR/mcp/server/fastmcp 存在"
else
  echo "  !! 没有 mcp/server/fastmcp，先别继续，把本段贴给小克"
fi

echo
echo "########## 3. 临时容器里验证 import ##########"
docker run --rm -v "$VENDOR:/vendor" -e PYTHONPATH=/vendor \
  --entrypoint python "$IMG" -c \
  'from mcp.server.fastmcp import Context, FastMCP; import mcp; print("  import 成功  mcp:", getattr(mcp,"__version__","?"))' \
  2>&1 | tail -6

echo
echo "########## 4. compose 加挂载和 PYTHONPATH ##########"
cp "$COMPOSE" "${COMPOSE}.bak.$(date +%Y%m%d_%H%M%S)"
VENDOR="$VENDOR" COMPOSE="$COMPOSE" python3 - <<'PY'
import os, yaml
path = os.environ["COMPOSE"]; vendor = os.environ["VENDOR"]
mount = f"{vendor}:/vendor"
doc = yaml.safe_load(open(path, encoding="utf-8"))
for svc in ("ombre-brain", "ombre-gateway"):
    node = doc.get("services", {}).get(svc)
    if node is None:
        continue
    vols = node.setdefault("volumes", [])
    if mount not in vols:
        vols.append(mount); print(f"  {svc}: 加挂载 {mount}")
    env = node.setdefault("environment", [])
    if isinstance(env, list):
        if not any(str(e).startswith("PYTHONPATH=") for e in env):
            env.append("PYTHONPATH=/vendor"); print(f"  {svc}: 加 PYTHONPATH=/vendor")
    elif isinstance(env, dict):
        env.setdefault("PYTHONPATH", "/vendor"); print(f"  {svc}: 加 PYTHONPATH=/vendor")
yaml.safe_dump(doc, open(path, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=False, default_flow_style=False)
print("  compose 已写入")
PY

echo
echo "########## 5. 起容器（不 build）##########"
cd "$REPO"
docker compose up -d --no-build ombre-brain ombre-gateway 2>&1 | tail -12
sleep 12
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'

echo
echo "########## 6. 结果 ##########"
echo "--- brain health ---"
curl -sS --max-time 8 http://127.0.0.1:18001/health 2>/dev/null | head -c 260 || echo "  仍不通"
echo
echo "--- gateway health ---"
curl -sS --max-time 8 http://127.0.0.1:18003/health 2>/dev/null | head -c 120 || echo "  不通"
echo
echo "--- brain 最近日志 ---"
docker logs --tail 15 haven-ombre 2>&1 | tail -10 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "--- 数据还在吗 ---"
echo "  buckets md 数: $(find /data/haven-ombre -name '*.md' 2>/dev/null | wc -l)"
echo "  state 文件数:  $(ls /data/haven-ombre/state 2>/dev/null | wc -l)"

echo
echo "=================================================="
echo "还不通就把第 2、3、6 段贴给小克。"
echo "撤销：cp ${COMPOSE}.bak.<最新时间戳> $COMPOSE"
echo "      cd $REPO && docker compose up -d --no-build"
echo "=================================================="
