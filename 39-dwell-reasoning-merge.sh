#!/usr/bin/env bash
set -euo pipefail

echo "########## 1. dwell 后端 agent_tools_feature.py 840-860 附近 ##########"
sed -n '840,860p' /root/dwell-on-something/backend/agent_tools_feature.py | nl -v 840

echo ""
echo "########## 2. 搜 dwell 后端里所有处理 reasoning 的地方 ##########"
grep -rn 'reasoning\|thinking' /root/dwell-on-something/backend/*.py | grep -v '^\s*#' | head -40

echo ""
echo "########## 3. 搜 --- 分隔符的生成位置 ##########"
grep -rn '---' /root/dwell-on-something/backend/*.py | grep -v '^\s*#' | head -20

echo ""
echo "########## 4. gateway 返回的原始结构（从 gateway 日志看）##########"
docker logs haven-gateway 2>&1 | grep -A5 'reasoning_content\|Gateway upstream cache' | tail -30

echo ""
echo "########## 5. dwell 数据库最近一条 assistant 消息 ##########"
sqlite3 /root/dwell-on-something/backend/data/dwell.db "
SELECT substr(content, 1, 400) FROM messages 
WHERE role='assistant' 
ORDER BY created_at DESC LIMIT 1;
"

echo ""
echo "########## 完毕 ##########"
