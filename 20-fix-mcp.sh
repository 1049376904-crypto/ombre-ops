#!/usr/bin/env bash
# haven-ombre 崩溃原因：ModuleNotFoundError: No module named 'mcp.server.fastmcp'
# 上游 pull 之后重新 build，pip 装到了新版 mcp，而新版把 FastMCP 移走了。
# 先查装的是哪个版本、哪些路径存在，再在容器里装回可用版本。
set -uo pipefail

REPO=/root/Haven-Ombre
C=haven-ombre

echo "########## 1. brain 现在到底活着没 ##########"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'haven'
echo "--- health ---"
curl -sS --max-time 6 http://127.0.0.1:18001/health 2>/dev/null | head -c 200 || echo "  不通"
echo
echo "--- 最近日志 ---"
docker logs --tail 12 "$C" 2>&1 | tail -8

echo
echo "########## 2. 容器里装的 mcp 是什么版本 ##########"
docker exec -i "$C" python - <<'PY' 2>/dev/null || echo "  容器不可用，用 run 方式再试"
import importlib.metadata as md
for name in ("mcp", "fastmcp", "starlette", "uvicorn", "pydantic"):
    try:
        print(f"  {name}: {md.version(name)}")
    except Exception:
        print(f"  {name}: 未安装")
PY

if ! docker exec "$C" true 2>/dev/null; then
  IMG=$(docker inspect "$C" --format '{{.Config.Image}}' 2>/dev/null)
  echo "  容器起不来，改用临时容器检查镜像 $IMG"
  docker run --rm --entrypoint python "$IMG" - <<'PY' 2>/dev/null
import importlib.metadata as md
for name in ("mcp", "fastmcp"):
    try: print(f"  {name}: {md.version(name)}")
    except Exception: print(f"  {name}: 未安装")
PY
fi

echo
echo "########## 3. FastMCP 到底在哪个路径下 ##########"
RUNNER="docker exec -i $C"
docker exec "$C" true 2>/dev/null || RUNNER="docker run --rm --entrypoint python $(docker inspect "$C" --format '{{.Config.Image}}')"
$RUNNER python - <<'PY' 2>/dev/null || $RUNNER - <<'PY2' 2>/dev/null
for path in ("mcp.server.fastmcp", "mcp.server.FastMCP", "fastmcp", "mcp.server"):
    try:
        m = __import__(path, fromlist=["*"])
        has = "FastMCP" in dir(m)
        print(f"  {path}: 可导入  FastMCP={has}")
    except Exception as e:
        print(f"  {path}: {type(e).__name__}")
PY
for path in ("mcp.server.fastmcp", "fastmcp", "mcp.server"):
    try:
        m = __import__(path, fromlist=["*"])
        print(f"  {path}: 可导入  FastMCP={'FastMCP' in dir(m)}")
    except Exception as e:
        print(f"  {path}: {type(e).__name__}")
PY2

echo
echo "########## 4. requirements.txt 里写的是什么 ##########"
grep -inE 'mcp|fastmcp' "$REPO/requirements.txt" 2>/dev/null || echo "  没提到 mcp"

echo
echo "########## 5. server.py 第 60-70 行怎么导入的 ##########"
sed -n '60,70p' "$REPO/server.py" 2>/dev/null

echo
echo "=================================================="
echo "看完上面再决定装哪个版本。常见修法（先别急着跑）："
echo
echo "A. 容器还能起：直接在容器里装回旧版 mcp"
echo "     docker exec $C pip install --no-cache-dir 'mcp<2'"
echo "     cd $REPO && docker compose restart ombre-brain"
echo "   注意：pip 装在容器可写层，recreate 会丢，但 restart 不丢。"
echo
echo "B. 想永久生效：在 requirements.txt 里钉住版本再 build"
echo "     echo 'mcp<2' >> $REPO/requirements.txt"
echo "     cd $REPO && docker compose up -d --build ombre-brain"
echo
echo "C. 回退上游代码（如果是上游改动引入的）"
echo "     cd $REPO && git log --oneline -5"
echo "     git checkout 284c9c7~1 -- server.py requirements.txt"
echo "=================================================="
