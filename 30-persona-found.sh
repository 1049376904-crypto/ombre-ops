#!/usr/bin/env bash
# 重大发现：/app/state/persona_state.db 修改时间 2026-08-12 04:39:55，
# 正好是 pfix 测试第 3 轮的时刻（04:39:49 round completed）。
# 也就是说 persona 一直在正常工作，只是写到了 /app/state/ ——
# 那个目录不是 bind mount，是容器可写层，容器一 recreate 就没了。
# 而我一直在查 /state/persona_state.db（挂载出来的那份），当然永远是 0。
#
# 本脚本先证实，再把 state_dir 显式指到 /state。
set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

echo "########## 1. 证实：容器内那份 db 有数据吗 ##########"
docker exec -i haven-gateway python - <<'PY'
import sqlite3, os
for p in ("/app/state/persona_state.db", "/state/persona_state.db", "/data/state/persona_state.db"):
    if not os.path.exists(p):
        print(f"  {p}: 不存在"); continue
    try:
        c = sqlite3.connect(p)
        counts = {}
        for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
            try:
                counts[t] = c.execute("select count(*) from " + t).fetchone()[0]
            except Exception:
                counts[t] = "无表"
        upd = c.execute("select updated_at from persona_global_state limit 1").fetchone()
        import datetime
        mt = datetime.datetime.fromtimestamp(os.path.getmtime(p)).isoformat(timespec="seconds")
        print(f"  {p}")
        print(f"     mtime={mt}  {counts}  global.updated_at={upd[0] if upd else None}")
    except Exception as e:
        print(f"  {p}: ERR {e}")
PY

echo
echo "########## 2. 看看最新的 session_state 内容（persona 到底记了什么）##########"
docker exec -i haven-gateway python - <<'PY'
import sqlite3
try:
    c = sqlite3.connect("/app/state/persona_state.db")
    c.row_factory = sqlite3.Row
    rows = list(c.execute("select * from persona_session_state order by rowid desc limit 3"))
    if not rows:
        print("  没有 session_state 记录")
    for r in rows:
        d = dict(r)
        print("  ---", d.get("session_id"), d.get("updated_at"))
        for k in ("mood_label", "valence", "arousal", "tenderness", "longing",
                  "security", "inner_thought", "residue"):
            if k in d and str(d[k]).strip():
                print(f"     {k}: {str(d[k])[:110]}")
except Exception as e:
    print("  ERR", e)
PY

echo
echo "########## 3. state_dir 现在是什么（空 = 回退到 buckets_dir）##########"
docker exec -i haven-gateway python - <<'PY'
import yaml, os
cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
print("  config.state_dir  :", repr(cfg.get("state_dir")))
print("  config.buckets_dir:", repr(cfg.get("buckets_dir")))
print("  env OMBRE_BUCKETS_DIR:", repr(os.environ.get("OMBRE_BUCKETS_DIR")))
print("  env OMBRE_STATE_DIR  :", repr(os.environ.get("OMBRE_STATE_DIR")))
print("  cwd:", os.getcwd())
print()
print("  persona_engine.py 第 230-240 行：")
PY
docker exec -i haven-gateway sed -n '228,242p' /app/persona_engine.py

echo
echo "########## 4. 其它引擎的 db 写在哪（同一个坑）##########"
docker exec -i haven-gateway sh -lc '
  for n in memory_moments.sqlite raw_events.sqlite reminders.sqlite word_map.sqlite portrait_state.json; do
    echo "  -- $n"
    find /app /state /data -maxdepth 3 -name "$n" -not -path "*pre_restore*" -not -path "*rescue*" 2>/dev/null \
      | while read f; do echo "     $f  $(stat -c %s "$f")B  $(stat -c %y "$f" | cut -d. -f1)"; done
  done'

if [ "$WRITE" = "1" ]; then
  echo
  echo "########## 5. 显式设置 state_dir=/state ##########"
  CFG=/root/Haven-Ombre/config.yaml
  BAK="${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$CFG" "$BAK"; echo "  备份 -> $BAK"

  # 先把容器内那份有数据的 db 抢救到挂载目录
  echo "  抢救 /app/state 里的新数据到 /state ..."
  docker exec -i haven-gateway sh -lc '
    mkdir -p /tmp/rescue
    for f in /app/state/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      if [ -f "/state/$b" ]; then
        # 容器内那份更新则备份旧的再覆盖
        if [ "$f" -nt "/state/$b" ]; then
          cp "/state/$b" "/state/$b.before_statedir_fix"
          cp "$f" "/state/$b"
          echo "     $b: 容器内更新 -> 已覆盖 /state（旧的存为 .before_statedir_fix）"
        else
          echo "     $b: /state 更新或同龄，跳过"
        fi
      else
        cp "$f" "/state/$b"; echo "     $b: 复制到 /state"
      fi
    done'

  docker exec -i haven-ombre python - <<'PY'
import yaml
p = "/app/config.yaml"
cfg = yaml.safe_load(open(p, encoding="utf-8"))
old = cfg.get("state_dir")
cfg["state_dir"] = "/state"
print(f"  state_dir: {old!r} -> '/state'")
yaml.safe_dump(cfg, open(p, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=True, default_flow_style=False)
PY

  echo "  重启两个服务..."
  cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway >/dev/null 2>&1
  sleep 12
  docker ps --format '{{.Names}}\t{{.Status}}' | grep haven
  echo
  echo "  验证：/state 现在有数据吗"
  docker exec -i haven-ombre python - <<'PY'
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
for t in ("persona_events", "persona_session_state", "persona_exchange_log"):
    try:
        print(f"    {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
    except Exception as e:
        print(f"    {t}: {e}")
PY
  echo
  echo "  撤销：cp $BAK $CFG && cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway"
fi

echo
echo "=================================================="
[ "$WRITE" = "0" ] && cat <<'EOF'
确认第 1 段显示 /app/state 那份有数据、/state 那份是 0 之后，跑：
    bash 30-persona-found.sh --write
它会把容器内较新的 state 文件抢救到 /state，并把 config.state_dir 固定为 /state。

另外关于 core memory：现在只有 2 个 pinned 桶（共 182 token，预算 400 够用）。
「妍妍的回复风格偏好」根本没被 pin，所以它不在 core memory 里。
去 Dashboard 把它和「和妍妍相处的注意事项」设为 pinned，才会每轮在场。
「我有了名字叫沐」已标 self_anchor，按设计会被 core memory 排除（走 handoff 的自我块），
这是正常的，不用管。
EOF
echo "=================================================="
