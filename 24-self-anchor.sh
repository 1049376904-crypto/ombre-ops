#!/usr/bin/env bash
# 收尾三件事：
#   1. 把「我有了名字叫沐」标成 self_anchor，让 handoff 的「自我」块有内容
#   2. dream.identity_anchor_id 填上这个桶
#   3. 复查 persona 换 glm-5 后是否开始写入
#
# 默认 dry-run，加 --write 才动文件。
set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1
TARGET=/data/haven-ombre/permanent/内心/我有了名字叫沐_ab4081cf097c.md
BID=ab4081cf097c

echo "########## 1. 目标桶当前的 frontmatter ##########"
if [ -f "$TARGET" ]; then
  sed -n '1,/^---$/p' "$TARGET" | head -30
else
  echo "  !! 找不到 $TARGET"
  echo "  现有 permanent 桶："
  find /data/haven-ombre/permanent -name '*.md' 2>/dev/null | head -20
  exit 1
fi

echo
echo "########## 2. 全库 self_anchor / anchor 现状 ##########"
echo "  self_anchor: $(grep -rl 'self_anchor' /data/haven-ombre --include='*.md' 2>/dev/null | wc -l) 个"
echo "  anchor:true: $(grep -rlE '^anchor:[[:space:]]*true' /data/haven-ombre --include='*.md' 2>/dev/null | wc -l) 个"

echo
echo "########## 3. 修改内容 ##########"
WRITE="$WRITE" TARGET="$TARGET" python3 - <<'PY'
import os, re, shutil, datetime

write = os.environ["WRITE"] == "1"
path = os.environ["TARGET"]
text = open(path, encoding="utf-8").read()

m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not m:
    print("  !! 没有 frontmatter，放弃"); raise SystemExit(1)

fm = m.group(1)
lines = fm.split("\n")
changed = []

def has(key):
    return any(re.match(rf"^{key}\s*:", l) for l in lines)

if has("self_anchor"):
    changed.append("  = self_anchor 已存在")
else:
    lines.append("self_anchor: true"); changed.append("  * 新增 self_anchor: true")

if has("anchor"):
    for i, l in enumerate(lines):
        if re.match(r"^anchor\s*:", l):
            if "true" in l:
                changed.append("  = anchor 已是 true")
            else:
                lines[i] = "anchor: true"; changed.append("  * anchor -> true")
else:
    lines.append("anchor: true"); changed.append("  * 新增 anchor: true")

for line in changed:
    print(line)

if not write:
    print("\n  [dry-run] 未写入。加 --write 生效。")
    raise SystemExit(0)

bak = path + ".bak." + datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
shutil.copy2(path, bak)
new = "---\n" + "\n".join(lines) + "\n---\n" + text[m.end():]
open(path, "w", encoding="utf-8").write(new)
print(f"\n  已写入，原文件备份为 {os.path.basename(bak)}")
PY

if [ "$WRITE" = "1" ]; then
  echo
  echo "########## 4. dream.identity_anchor_id 填上 ##########"
  CFG=/root/Haven-Ombre/config.yaml
  cp "$CFG" "${CFG}.bak.$(date +%Y%m%d_%H%M%S)"
  BID="$BID" CFG="$CFG" python3 - <<'PY'
import os, yaml
cfg_path = os.environ["CFG"]; bid = os.environ["BID"]
cfg = yaml.safe_load(open(cfg_path, encoding="utf-8"))
old = cfg.setdefault("dream", {}).get("identity_anchor_id", "")
cfg["dream"]["identity_anchor_id"] = bid
sa = cfg.setdefault("self_anchor", {})
old2 = sa.get("entry_bucket_id", "")
sa["entry_bucket_id"] = bid
print(f"  dream.identity_anchor_id: {old!r} -> {bid!r}")
print(f"  self_anchor.entry_bucket_id: {old2!r} -> {bid!r}")
yaml.safe_dump(cfg, open(cfg_path, "w", encoding="utf-8"),
               allow_unicode=True, sort_keys=True, default_flow_style=False)
PY

  echo
  echo "########## 5. 重启并看 handoff 的自我块 ##########"
  cd /root/Haven-Ombre && docker compose restart ombre-brain ombre-gateway >/dev/null 2>&1
  sleep 12
  docker ps --format '{{.Names}}\t{{.Status}}' | grep haven
  echo
  curl -sS --max-time 25 'http://127.0.0.1:18001/breath-hook?mode=handoff&session_id=selftest&max_tokens=800' \
    2>/dev/null | head -c 1000
  echo
fi

echo
echo "########## 6. persona 复查（换 glm-5 后有没有开始写）##########"
docker exec -i haven-ombre python - <<'PY' 2>/dev/null
import sqlite3
c = sqlite3.connect("/state/persona_state.db")
for t in ("persona_events", "persona_session_state", "persona_exchange_log", "persona_global_state"):
    try:
        print(f"  {t}: {c.execute('select count(*) from ' + t).fetchone()[0]}")
    except Exception as e:
        print(f"  {t}: {e}")
try:
    r = c.execute("select updated_at from persona_global_state limit 1").fetchone()
    print("  global_state.updated_at:", r[0] if r else None)
    print("  （若仍是 2026-08-07，说明 persona 评估还是没跑）")
except Exception as e:
    print(" ", e)
PY

echo
echo "########## 7. persona 日志 ##########"
docker logs --tail 300 haven-gateway 2>&1 | grep -aiE 'persona' | tail -12 \
  | sed -E 's/(sk-|Bearer )[A-Za-z0-9._-]{8,}/\1[REDACTED]/g'

echo
echo "=================================================="
[ "$WRITE" = "0" ] && echo "确认无误后： bash 24-self-anchor.sh --write"
echo "=================================================="
