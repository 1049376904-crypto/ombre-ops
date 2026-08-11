#!/usr/bin/env bash
# 直接在容器里读 gateway.py，查三件事：
#   1. Core Memory 到底被什么条件挡住
#   2. debug_detail 的 compact/full 开关在哪
#   3. Gateway 会不会写 recall_diagnostics
# 全部只读。
set -uo pipefail

G=haven-gateway

echo "########## 1. Core Memory 的注入条件 ##########"
docker exec -i "$G" sh -lc '
  grep -n "core_memory_interval_rounds" /app/gateway.py | head -20
  echo "--- core_memory_budget 用在哪 ---"
  grep -n "core_memory_budget" /app/gateway.py | head -20
  echo "--- Core Memory 段落怎么拼 ---"
  grep -n "Core Memory" /app/gateway.py | head -20
'

echo
echo "########## 2. stable_context 是怎么组装的 ##########"
docker exec -i "$G" sh -lc '
  grep -n "stable_context" /app/gateway.py | head -30
'

echo
echo "########## 3. debug_detail 的开关 ##########"
docker exec -i "$G" sh -lc '
  grep -n "debug_detail" /app/gateway.py | head -20
  echo "--- compact 出现的地方 ---"
  grep -n "\"compact\"\|'"'"'compact'"'"'" /app/gateway.py | head -20
'

echo
echo "########## 4. Gateway 写不写 recall_diagnostics ##########"
docker exec -i "$G" sh -lc '
  grep -c "recall_diagnostics" /app/gateway.py || true
  grep -n "recall_diagnostics" /app/gateway.py | head -10
'

echo
echo "########## 5. 召回准入门槛用的是哪几个值 ##########"
docker exec -i "$G" sh -lc '
  grep -n "recall_admission_semantic_score\|first_card_min_score\|admission" /app/gateway.py | head -25
'

echo
echo "########## 6. Gateway 容器的 OMBRE_* 环境变量（名字+是否有值）##########"
docker exec -i "$G" sh -lc '
  for v in $(printenv | grep -o "^OMBRE_[A-Z_]*" | sort); do
    val=$(printenv "$v")
    case "$v" in
      *KEY*|*TOKEN*|*SECRET*|*PASSWORD*) echo "  $v = [有值]" ;;
      *) echo "  $v = $val" ;;
    esac
  done
'

echo
echo "########## 7. 运行中的 Gateway 实际读到的 core memory 配置 ##########"
docker exec -i "$G" python - <<'PY'
import yaml
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
g = cfg.get("gateway", {})
for k in ("core_memory_budget", "core_memory_interval_rounds",
          "inject_total_budget", "recalled_memory_budget",
          "recall_admission_semantic_score", "recall_admission_rerank_score",
          "first_card_min_score", "second_card_min_score",
          "favorite_memory_interval_rounds", "retrieval_mode"):
    print(f"  {k}: {g.get(k, '(未设置)')}")
print("  recall_diagnostics:", cfg.get("recall_diagnostics"))
PY

echo
echo "########## 完毕。全部只读。 ##########"
