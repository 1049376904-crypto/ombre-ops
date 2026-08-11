#!/usr/bin/env bash
# 把 gateway.py 里决定 Core Memory 和召回准入的那几段源码打出来。只读。
set -uo pipefail
G=haven-gateway

seg() {  # seg <起始行> <结束行> <标题>
  echo "----- $3  (行 $1-$2) -----"
  docker exec -i "$G" sed -n "$1,$2p" /app/gateway.py
  echo
}

echo "########## A. core_memory_interval_rounds 的用法（2860-2900）##########"
seg 2860 2900 "调用点"

echo "########## B. 那个 helper 函数的定义 ##########"
docker exec -i "$G" sh -lc '
  grep -n "def .*interval\|def _should_inject\|def _interval_gate\|def _due_by_interval" /app/gateway.py | head -20'
echo

echo "########## C. Core Memory 拼装处（17890-17985）##########"
seg 17890 17985 "add_stable_section 与 stable_context 收尾"

echo "########## D. core_budget 的使用点 ##########"
docker exec -i "$G" sh -lc 'grep -n "core_budget" /app/gateway.py | head -20'
echo

echo "########## E. core_memory 变量从哪来 ##########"
docker exec -i "$G" sh -lc 'grep -n "core_memory\b\|core_memory =\|_build_core_memory\|def .*core_memory" /app/gateway.py | head -25'
echo

echo "########## F. debug_detail 在 1860-1885 / 2005-2025 的判定 ##########"
seg 1860 1885 "第一处"
seg 2005 2025 "第二处"

echo "########## G. admission gate 的构造（745-775）##########"
seg 745 775 "阈值装配"

echo "########## H. 准入判定函数 ##########"
docker exec -i "$G" sh -lc '
  grep -n "def .*admission\|def _admit\|def admit" /app/gateway.py | head -20'
echo

echo "########## 完毕。全部只读。 ##########"
