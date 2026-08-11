#!/usr/bin/env bash
# brain 起来了，但监听 8000，而 compose 映射 18001->9000，所以 18001 不通。
# 先查 9000 是从哪来的、隧道指着哪个端口，再决定改哪一边。全部只读。
set -uo pipefail

REPO=/root/Haven-Ombre

echo "########## 1. 容器内实际监听哪个端口 ##########"
docker exec -i haven-ombre sh -lc '
  (command -v ss >/dev/null && ss -tlnp) 2>/dev/null \
  || (command -v netstat >/dev/null && netstat -tlnp) 2>/dev/null \
  || echo "  容器里没有 ss/netstat"
' 2>/dev/null
echo "--- 容器内自测 ---"
for p in 8000 9000; do
  printf "  127.0.0.1:%s -> " "$p"
  docker exec haven-ombre sh -lc "curl -fsS --max-time 4 http://127.0.0.1:$p/health 2>/dev/null | head -c 80" \
    || echo -n "不通"
  echo
done

echo
echo "########## 2. compose 里 brain 的 ports 和 environment ##########"
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open("/root/Haven-Ombre/docker-compose.yml", encoding="utf-8"))
node = doc.get("services", {}).get("ombre-brain", {})
print("  ports:", node.get("ports"))
env = node.get("environment")
if isinstance(env, list):
    for e in env:
        s = str(e)
        k = s.split("=", 1)[0]
        print("  env:", k if any(w in k.upper() for w in ("KEY","TOKEN","SECRET")) else s)
elif isinstance(env, dict):
    for k, v in env.items():
        print("  env:", k if any(w in k.upper() for w in ("KEY","TOKEN","SECRET")) else f"{k}={v}")
print("  command:", node.get("command"))
PY

echo
echo "########## 3. 9000 这个端口是从哪来的 ##########"
echo "--- config.yaml 里有没有 port ---"
grep -nE '^\s*port:|9000|8000' "$REPO/config.yaml" 2>/dev/null | head -20
echo "--- .env 里有没有 ---"
grep -nE 'PORT|9000|8000' "$REPO/.env" 2>/dev/null | sed -E 's/=.*/=[值]/' | head
echo "--- server.py 怎么决定端口 ---"
docker exec -i haven-ombre sh -lc '
  grep -nE "port\s*=|PORT|9000|8000|uvicorn.run|settings\." /app/server.py | grep -iE "port|9000|8000" | head -25'

echo
echo "########## 4. 旧容器用的什么端口（对照）##########"
docker ps -a --format '{{.Names}}\t{{.Ports}}' | grep -E 'haven|ombre'

echo
echo "########## 5. cloudflared 隧道指向哪个端口（改之前必须确认）##########"
for f in ~/.cloudflared/config.yml ~/.cloudflared/config.yaml; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  sed -E 's/(tunnel|credentials-file):.*/\1: [REDACTED]/' "$f"
done
echo "--- 隧道容器最近日志 ---"
docker logs --tail 15 ombre-tunnel 2>&1 | grep -aiE 'ingress|service|18001|9000|8000|error' | tail -8

echo
echo "########## 6. dwell 那边访问 brain 用的什么地址 ##########"
grep -rnoE 'http://[0-9.]+:(18001|9000|8000)[^"'"'"' ]*' \
  /root/dwell-on-something/backend/*.py 2>/dev/null | head -10
echo "--- dwell 数据库里的设置 ---"
for db in /root/dwell-on-something/backend/data/dwell.db; do
  [ -f "$db" ] && sqlite3 "$db" \
    "select key, value from settings where key like '%brain%' or key like '%ombre%' or value like '%18001%';" 2>/dev/null
done

echo
echo "=================================================="
echo "两种改法，等看完上面再定："
echo
echo "A. 改 compose 映射（如果 9000 只是旧的遗留值）"
echo "     ports: 18001:8000"
echo "   风险：隧道若指向容器 9000 需同步改。"
echo
echo "B. 让 server 继续听 9000（如果隧道/其它服务依赖 9000）"
echo "   需要找到端口配置项，可能是 config.yaml 的 port 或环境变量。"
echo "=================================================="
