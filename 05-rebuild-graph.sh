#!/usr/bin/env bash
# 修召回的第一步：重建 moment 图（派生索引），并查 persona 为什么不写。
# 不动 buckets 正文，不动 config。最坏情况是消耗一些 embedding 调用。
set -uo pipefail

C=haven-ombre

echo "########## 1. persona 为什么 566 轮一次没写 ##########"
docker logs --tail 800 haven-gateway 2>&1 \
  | grep -aiE 'persona|evaluat' | tail -30 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
echo "--- Brain 侧 ---"
docker logs --tail 800 "$C" 2>&1 \
  | grep -aiE 'persona|evaluat' | tail -20 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'
echo "(上面没输出 = 日志里没提过 persona，需要开 debug 才看得到)"

echo
echo "########## 2. rerank / embedding 有没有在静默失败 ##########"
docker logs --tail 800 haven-gateway 2>&1 \
  | grep -aiE 'rerank|embedding|404|401|429|timeout' | tail -20 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "########## 3. moment 图重建脚本支持哪些参数 ##########"
docker exec "$C" python scripts/build_moment_graph.py --help 2>&1 | head -40

echo
echo "########## 4. 当前 moment 数（重建前）##########"
docker exec "$C" python - <<'PY' 2>/dev/null
import sqlite3
c = sqlite3.connect("/state/memory_moments.sqlite")
for t in ("memory_moments", "memory_moment_edges", "memory_retrieval_aliases"):
    try:
        print(f"  {t}: {c.execute(f'select count(*) from {t}').fetchone()[0]}")
    except Exception as e:
        print(f"  {t}: ERR {e}")
PY

echo
echo "=================================================="
echo "上面 3 段是 --help 输出。看完确认没问题后，跑下面这行开始重建："
echo
echo "    docker exec $C python scripts/build_moment_graph.py"
echo
echo "重建可能要几分钟，会调 embedding API。跑完再执行本脚本可对比 moment 数。"
echo "=================================================="
