#!/usr/bin/env bash
# 04-restore-state.sh
#
# 背景：02-mount-state.sh 把 /data/haven-ombre/state 挂到了两个容器的 /state，
#       但那个目录里是 8/3 的旧数据（各表全 0），脚本因为“目录非空就不覆盖”
#       的保护判断而跳过了拷贝，把容器里那份活的数据盖住了。
#
# 本脚本：把 01-state-rescue.sh 抢救出来的那份恢复为生效的 /state。
#
# 步骤：
#   1. 定位最新的 _state_rescue_*/brain_state
#   2. 停 brain + gateway（不能带着运行中的进程换 SQLite 文件）
#   3. 当前 state 改名为 state.pre_restore_<TS>（不删）
#   4. 新建 state，放入抢救的文件
#   5. 从 state.pre_restore_* 以 no-clobber 方式补齐缺的文件（如 dreams/）
#   6. 启动，打印各表计数与 health
#
# 不删任何东西。服务中断约半分钟。

set -uo pipefail

COMPOSE_DIR=/root/Haven-Ombre
STATE=/data/haven-ombre/state
TS=$(date +%Y%m%d_%H%M%S)

say() { printf '\n===== %s =====\n' "$1"; }

cd "$COMPOSE_DIR" || { echo "找不到 $COMPOSE_DIR"; exit 1; }

say "1. 定位抢救备份"
SRC=$(ls -d /data/haven-ombre/_state_rescue_*/brain_state 2>/dev/null | sort | tail -1)
if [ -z "${SRC:-}" ] || [ ! -d "$SRC" ]; then
  echo "没找到 /data/haven-ombre/_state_rescue_*/brain_state"
  echo "如果只剩 tar.gz，先解开："
  ls -la /data/haven-ombre/_state_rescue_* 2>/dev/null
  exit 1
fi
echo "源：$SRC"
find "$SRC" -type f -printf '  %p  %s bytes  %TY-%Tm-%Td %TH:%TM\n' | sort

SRC_N=$(find "$SRC" -type f | wc -l)
if [ "$SRC_N" -lt 5 ]; then
  echo "源目录只有 $SRC_N 个文件，看起来不对，停。"
  exit 1
fi

say "2. 恢复前的现状（供对比）"
ls -la "$STATE" 2>/dev/null

say "3. 停容器"
docker compose stop ombre-brain ombre-gateway
docker ps --format 'table {{.Names}}\t{{.Status}}'

say "4. 当前 state 改名留存"
if [ -d "$STATE" ]; then
  mv "$STATE" "${STATE}.pre_restore_${TS}"
  echo "已改名为 ${STATE}.pre_restore_${TS}"
else
  echo "$STATE 不存在，直接新建"
fi

say "5. 写入抢救的数据"
mkdir -p "$STATE"
cp -a "$SRC/." "$STATE/"
ls -la "$STATE"

say "6. 从旧目录补齐缺的文件（不覆盖已有）"
OLD="${STATE}.pre_restore_${TS}"
if [ -d "$OLD" ]; then
  cp -a -n "$OLD/." "$STATE/" 2>/dev/null
  echo "补齐后："
  find "$STATE" -type f -printf '  %p  %s bytes  %TY-%Tm-%Td %TH:%TM\n' | sort
fi

say "7. 启动"
docker compose up -d
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

say "8. 等 15 秒"
sleep 15

say "9. 各表计数（应该不再全是 0）"
if command -v sqlite3 >/dev/null; then
  for db in "$STATE"/*.sqlite "$STATE"/*.db; do
    [ -f "$db" ] || continue
    echo "--- $db ---"
    for t in $(sqlite3 "$db" ".tables" 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d'); do
      printf '  %-34s %s\n' "$t" "$(sqlite3 "$db" "select count(*) from \"$t\";" 2>&1)"
    done
  done
else
  echo "宿主机没有 sqlite3（apt-get install -y sqlite3）"
fi
echo "--- memory_edges.jsonl ---"
wc -l "$STATE/memory_edges.jsonl" 2>&1
echo "--- portrait_state.json ---"
ls -la "$STATE/portrait_state.json" 2>&1

say "10. 容器内看到的 /state"
for c in haven-ombre haven-gateway; do
  echo "--- $c ---"
  docker exec "$c" sh -lc 'ls -la /state' 2>&1
done

say "11. health"
echo "--- brain ---"
curl -s -m 10 http://127.0.0.1:18001/health; echo
echo "--- gateway (只看头部) ---"
curl -s -m 10 http://127.0.0.1:18003/health | head -c 400; echo

say "完成"
echo "旧目录仍在：$OLD（含那份 14662 字节的 portrait_state.json，没删）"
echo "下一步：bash /root/ombre-ops/03-collect-diag.sh"
