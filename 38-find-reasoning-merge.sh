#!/usr/bin/env bash
set -euo pipefail

echo "########## 1. gateway.py 3988 附近：reasoning 拿到后干了什么 ##########"
docker exec -i haven-gateway sed -n '3938,4038p' /app/gateway.py | nl -v 3938

echo ""
echo "########## 2. 搜所有拼接 '---' 或 reasoning + content 的地方 ##########"
docker exec -i haven-gateway grep -n '\-\-\-\|reasoning.*content\|content.*reasoning' /app/gateway.py | head -40

echo ""
echo "########## 3. 处理上游响应 body 的函数 ##########"
docker exec -i haven-gateway grep -n 'def.*response\|def.*assistant_message\|def.*upstream' /app/gateway.py | head -30

echo ""
echo "########## 4. dwell 后端有没有在客户端侧做拼接 ##########"
if [ -d /root/dwell-on-something/backend ]; then
    echo "--- backend/*.py 里搜 reasoning / --- / 分隔符 ---"
    grep -rn 'reasoning\|---\|split.*content' /root/dwell-on-something/backend/*.py | head -30 || echo "  无匹配"
else
    echo "  /root/dwell-on-something/backend 不存在"
fi

echo ""
echo "########## 5. 上游回复的原始结构示例（最近一轮）##########"
docker exec -i haven-gateway python3 -c "
import sqlite3
conn = sqlite3.connect('/data/haven-ombre/gateway_state.db')
row = conn.execute('SELECT upstream_response FROM request_rounds ORDER BY created_at DESC LIMIT 1').fetchone()
if row and row[0]:
    import json
    body = json.loads(row[0])
    choice = body.get('choices', [{}])[0]
    msg = choice.get('message', {})
    print('content 字段:', repr(msg.get('content', '')[:300]))
    print('reasoning_content 字段:', repr(msg.get('reasoning_content', '')[:200]))
    print('finish_reason:', choice.get('finish_reason'))
else:
    print('无最近记录')
"

echo ""
echo "########## 完毕 ##########"
