#!/usr/bin/env bash
# 02-mount-state.sh
# 目的：把容器内 /state 持久化到宿主机 /data/haven-ombre/state，并让 brain 与 gateway 共享同一份。
#
# 会做的事：
#   1. 备份 docker-compose.yml
#   2. 把容器内现有 /state 先拷到宿主机（否则挂载会把它们盖住）
#   3. 给两个 service 加上  /data/haven-ombre/state:/state
#   4. docker compose up -d 重建容器（服务会中断大约半分钟）
#   5. 验证挂载与健康
#
# 重要：跑之前请确认 01-state-rescue.sh 已经成功跑过。

set -uo pipefail
cd /root/Haven-Ombre || { echo "找不到 /root/Haven-Ombre"; exit 1; }

TS=$(date +%Y%m%d_%H%M%S)
HOST_STATE=/data/haven-ombre/state

say() { printf '\n===== %s =====\n' "$1"; }

say "0. 前置检查"
command -v docker >/dev/null || { echo "没有 docker"; exit 1; }
python3 - <<'PY' || { echo "宿主机 python3 没有 PyYAML，停。告诉我，我换一种写法。"; exit 1; }
import yaml  # noqa
PY
echo "OK"

say "1. 备份 compose"
cp -a docker-compose.yml "docker-compose.yml.bak.$TS"
ls -la "docker-compose.yml.bak.$TS"

say "2. 把容器内 /state 落到宿主机"
mkdir -p "$HOST_STATE"
if [ -z "$(ls -A "$HOST_STATE" 2>/dev/null)" ]; then
  TMP=$(mktemp -d)
  if docker cp haven-ombre:/state "$TMP/state" 2>&1; then
    cp -a "$TMP/state/." "$HOST_STATE/"
    echo "已拷入 $HOST_STATE："
    ls -la "$HOST_STATE"
  else
    echo "警告：容器内没有 /state，将以空目录开始"
  fi
  rm -rf "$TMP"
else
  echo "$HOST_STATE 已有内容，不覆盖。当前："
  ls -la "$HOST_STATE"
fi

say "3. 修改 compose（只加一行 volume）"
python3 - "$HOST_STATE" <<'PY'
import sys, yaml

host_state = sys.argv[1]
line = f"{host_state}:/state"
path = "docker-compose.yml"

with open(path, encoding="utf-8") as f:
    data = yaml.safe_load(f)

changed = []
for svc in ("ombre-brain", "ombre-gateway"):
    cfg = data.get("services", {}).get(svc)
    if cfg is None:
        print(f"警告：compose 里没有 service {svc}")
        continue
    vols = cfg.setdefault("volumes", [])
    if any(isinstance(v, str) and v.rstrip("/").endswith(":/state") for v in vols):
        print(f"{svc}: 已经有 /state 挂载，跳过")
        continue
    vols.append(line)
    changed.append(svc)

if changed:
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=True)
    print("已修改：" + ", ".join(changed))
else:
    print("无需修改")
PY

say "4. 改后的 compose"
cat docker-compose.yml

say "5. 语法校验"
if ! docker compose config >/dev/null; then
  echo "compose 校验失败，已回滚"
  cp -a "docker-compose.yml.bak.$TS" docker-compose.yml
  exit 1
fi
echo "OK"

say "6. 重建容器"
docker compose up -d

say "7. 验证挂载"
for c in haven-ombre haven-gateway; do
  echo "--- $c ---"
  docker inspect "$c" --format '{{range .Mounts}}{{.Type}}  {{.Source}}  ->  {{.Destination}}
{{end}}'
done

say "8. 等 15 秒后看健康"
sleep 15
echo "--- brain :18001/health ---"
curl -s -m 10 http://127.0.0.1:18001/health | head -c 2000; echo
echo "--- gateway :18003/health ---"
curl -s -m 10 http://127.0.0.1:18003/health | head -c 2000; echo

say "9. 宿主机 state 目录现状"
ls -la "$HOST_STATE"

say "完成"
echo "回滚办法：cp -a /root/Haven-Ombre/docker-compose.yml.bak.$TS /root/Haven-Ombre/docker-compose.yml && cd /root/Haven-Ombre && docker compose up -d"
