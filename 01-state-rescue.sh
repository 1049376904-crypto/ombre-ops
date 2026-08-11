#!/usr/bin/env bash
# 01-state-rescue.sh
# 目的：把两个容器里 /state 的数据抢救到宿主机，并打印出改挂载所需的信息。
# 这个脚本不重启、不删除、不修改任何东西，只读 + 复制。

set -uo pipefail

TS=$(date +%Y%m%d_%H%M%S)
OUT="/data/haven-ombre/_state_rescue_${TS}"
mkdir -p "$OUT"

say() { printf '\n===== %s =====\n' "$1"; }

say "A. 抢救 brain 容器 /state"
if docker cp haven-ombre:/state "$OUT/brain_state" 2>&1; then
  echo "OK -> $OUT/brain_state"
  find "$OUT/brain_state" -type f | sed "s|$OUT/||" | sort
  echo "--- 文件大小 ---"
  du -ab "$OUT/brain_state" | sort -k2
else
  echo "FAILED: brain /state 拷贝失败"
fi

say "B. 抢救 gateway 容器 /state"
if docker cp haven-gateway:/state "$OUT/gateway_state" 2>&1; then
  echo "OK -> $OUT/gateway_state"
  find "$OUT/gateway_state" -type f | sed "s|$OUT/||" | sort
else
  echo "FAILED 或 gateway 内没有 /state"
fi

say "C. 打成 tar 存档（防止后续误删）"
tar czf "${OUT}.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null \
  && ls -la "${OUT}.tar.gz" \
  || echo "tar 失败（不致命，目录仍在）"

say "D. 生效的 compose 文件内容"
for f in /root/Haven-Ombre/docker-compose.yml; do
  echo "--- $f ---"
  cat "$f"
done

say "E. compose 相关标签（确认哪份 compose、哪个 project 在管容器）"
for c in haven-ombre haven-gateway ombre-tunnel; do
  echo "--- $c ---"
  docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}
{{end}}' 2>/dev/null | grep -i compose || echo "(无 compose 标签)"
done

say "F. 当前挂载（确认 /state 确实没有挂载点）"
for c in haven-ombre haven-gateway; do
  echo "--- $c ---"
  docker inspect "$c" --format '{{range .Mounts}}{{.Type}}  {{.Source}}  ->  {{.Destination}}  rw={{.RW}}
{{end}}'
done

say "G. 两个容器的环境变量（查 qwen-turbo / qwen-max 来源）"
for c in haven-ombre haven-gateway; do
  echo "--- $c ---"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -viE 'api_key|token|secret|password' \
    | grep -viE '^(PATH|LANG|GPG_KEY|PYTHON|HOSTNAME)' \
    | sed '/^$/d'
done

say "H. 结果位置"
echo "目录： $OUT"
echo "存档： ${OUT}.tar.gz"
echo "完成。请把 D / F / G 三段贴给我。"
