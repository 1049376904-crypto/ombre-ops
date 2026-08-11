#!/usr/bin/env bash
# 03-collect-diag.sh
# 目的：把诊断所需的东西（脉敏后的 config、计数、挂载、健康、注入日志）写成文件，
#       推到私有仓库 ombre-diag，让我直接读，不用你复制粘贴。
#
# 不会上传：记忆正文（buckets/*.md）、embeddings.db、.env、任何 key/token、portrait 正文。
#
# 一次性前置（只需做一次，用你自己的 PAT）：
#   git clone https://<PAT>@github.com/1049376904-crypto/ombre-diag.git /root/ombre-diag
#   cd /root/ombre-diag && git config user.email ombre@local && git config user.name ombre

set -uo pipefail

DIAG_REPO=/root/ombre-diag
DATA=/data/haven-ombre
STAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="$DIAG_REPO/$STAMP"

if [ ! -d "$DIAG_REPO/.git" ]; then
  echo "没有找到 $DIAG_REPO（带凭证的 clone）。"
  echo "先跑这一行（把 <PAT> 换成你的 token）："
  echo '  git clone https://<PAT>@github.com/1049376904-crypto/ombre-diag.git /root/ombre-diag'
  echo "仍会把结果写到 /root/ombre-diag-local 供你自己看。"
  DIAG_REPO=/root/ombre-diag-local
  OUTDIR="$DIAG_REPO/$STAMP"
  NO_PUSH=1
fi
mkdir -p "$OUTDIR"

redact() {
  sed -E \
    -e 's/((api_?key|token|secret|password|passwd|authorization)["'"'"']?[[:space:]]*[:=][[:space:]]*).*/\1***REDACTED***/I' \
    -e 's/(sk-|Bearer )[A-Za-z0-9_\-]{8,}/\1***REDACTED***/g'
}

q() { sqlite3 "$1" "$2" 2>&1; }

# ---------- 1. config ----------
if [ -f /root/Haven-Ombre/config.yaml ]; then
  redact < /root/Haven-Ombre/config.yaml > "$OUTDIR/config.redacted.yaml"
fi
cp -a /root/Haven-Ombre/docker-compose.yml "$OUTDIR/docker-compose.yml" 2>/dev/null

# ---------- 2. 容器 / 挂载 ----------
{
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo
  for c in haven-ombre haven-gateway; do
    echo "--- $c mounts ---"
    docker inspect "$c" --format '{{range .Mounts}}{{.Type}}  {{.Source}}  ->  {{.Destination}}  rw={{.RW}}
{{end}}'
    echo "--- $c /state 内容 ---"
    docker exec "$c" sh -lc 'ls -la /state 2>&1; echo; ls -la /state/dreams 2>&1' 2>&1
    echo
  done
} > "$OUTDIR/containers.txt" 2>&1

# ---------- 3. 健康 ----------
{
  echo "### brain /health"; curl -s -m 10 http://127.0.0.1:18001/health
  echo; echo "### gateway /health"; curl -s -m 10 http://127.0.0.1:18003/health
  echo
} 2>&1 | redact > "$OUTDIR/health.json.txt"

# ---------- 4. 数据目录概况 ----------
{
  echo "### $DATA 顶层"
  ls -la "$DATA" | head -60
  echo
  echo "### bucket 计数"
  find "$DATA" -name '*.md' -type f | wc -l
  echo
  echo "### 最近 15 个修改的 .md（只文件名）"
  find "$DATA" -name '*.md' -type f -printf '%T@ %p\n' | sort -rn | head -15 | cut -d' ' -f2-
  echo
  echo "### db 文件"
  find "$DATA" -maxdepth 2 \( -name '*.db' -o -name '*.sqlite' -o -name '*.jsonl' \) -printf '%p  %s bytes  %TY-%Tm-%Td %TH:%TM\n'
} > "$OUTDIR/data_overview.txt" 2>&1

# ---------- 5. 数据库计数 ----------
if command -v sqlite3 >/dev/null; then
  {
    for db in $(find "$DATA" /data/haven-ombre/state -maxdepth 2 \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | sort -u); do
      echo "===== $db ====="
      for t in $(sqlite3 "$db" ".tables" 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d'); do
        printf '%-34s %s\n' "$t" "$(q "$db" "select count(*) from \"$t\";")"
      done
      echo
    done
  } > "$OUTDIR/db_counts.txt" 2>&1

  GW="$DATA/gateway_state.db"
  if [ -f "$GW" ]; then
    {
      echo "### schema"
      q "$GW" ".schema"
      echo
      echo "### 最近 5 轮 request_rounds"
      q "$GW" "select * from request_rounds order by rowid desc limit 5;"
      echo
      echo "### 最近 60 条 injection_debug"
      q "$GW" "select * from injection_debug order by rowid desc limit 60;"
      echo
      echo "### injection_debug 按 stage/status 聚合"
      q "$GW" "select * from injection_debug limit 1;"
    } 2>&1 | redact > "$OUTDIR/gateway_state.txt"
  fi
else
  echo "宿主机没有 sqlite3，请跑：apt-get install -y sqlite3" > "$OUTDIR/db_counts.txt"
fi

# ---------- 6. portrait 结构（不包含正文） ----------
PS=/data/haven-ombre/state/portrait_state.json
[ -f "$PS" ] || PS=$(find /data/haven-ombre -maxdepth 3 -name portrait_state.json 2>/dev/null | head -1)
if [ -n "${PS:-}" ] && [ -f "$PS" ]; then
  python3 - "$PS" > "$OUTDIR/portrait_shape.txt" 2>&1 <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
def walk(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items():
            walk(v, f"{p}.{k}")
    elif isinstance(o, list):
        print(f"{p}  list[{len(o)}]")
    elif isinstance(o, str):
        print(f"{p}  str({len(o)} chars)")
    else:
        print(f"{p}  {o!r}")
walk(d)
PY
fi

# ---------- 7. 日志尾巴 ----------
{
  for c in haven-ombre haven-gateway ombre-tunnel; do
    echo "===== $c (last 120) ====="
    docker logs --tail 120 "$c" 2>&1
    echo
  done
} | redact > "$OUTDIR/logs.txt"

# ---------- 8. dwell 侧设置 ----------
D=/root/dwell-on-something/backend/data/dwell.db
if command -v sqlite3 >/dev/null && [ -f "$D" ]; then
  q "$D" "select key, case when key like '%token%' or key like '%key%' then '***REDACTED***' else value end from settings order by key;" \
    > "$OUTDIR/dwell_settings.txt" 2>&1
fi

# ---------- 9. 推送 ----------
echo
echo "已生成：$OUTDIR"
ls -la "$OUTDIR"

if [ "${NO_PUSH:-0}" = "1" ]; then
  echo
  echo "未推送（没有带凭证的 clone）。看脚本头部的一次性前置。"
  exit 0
fi

cd "$DIAG_REPO" || exit 1
git add -A
git -c user.email=ombre@local -c user.name=ombre commit -m "diag $STAMP" || echo "没有变更"
git push origin HEAD && echo "推送成功：$STAMP" || echo "推送失败（看上面报错，通常是 token 没权限）"
