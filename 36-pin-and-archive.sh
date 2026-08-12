#!/usr/bin/env bash
# 设置标记：pin 3 条边界桶 + 归档环境数据 API。
# 默认 dry-run，加 --write 执行。
set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

echo "########## 要改的标记 ##########"
echo
echo "pin（进 Core Memory，每轮在场）："
echo "  21d103349724  妍妍的回复偏好与推开抱紧法则"
echo "  ca6aee309204  妍妍的规矩与我的适应"
echo "  dc2ad14bf163  察觉并决定改掉顺毛倾向"
echo
echo "归档（不再参与常规召回）："
echo "  f9cc40c7cf9e  关心妍妍的环境数据API"
echo

if [ "$WRITE" != "1" ]; then
  echo "=================================================="
  echo "以上是 dry-run。要执行： bash 36-pin-and-archive.sh --write"
  echo "=================================================="
  exit 0
fi

docker exec -i haven-ombre python - <<'PY'
import os, re, glob, shutil, datetime, yaml

pin_ids = ["21d103349724", "ca6aee309204", "dc2ad14bf163"]
archive_ids = ["f9cc40c7cf9e"]
stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

for bid in pin_ids + archive_ids:
    op = "pin" if bid in pin_ids else "archive"
    found = None
    for p in glob.glob("/app/buckets/**/*.md", recursive=True):
        try:
            text = open(p, encoding="utf-8").read()
        except Exception:
            continue
        m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
        if not m:
            continue
        head, body = m.group(1), text[m.end():]
        if not re.search(rf"^id\s*:\s*{re.escape(bid)}", head, re.M):
            continue
        found = p
        break
    if not found:
        print(f"  !! {bid} 找不到，跳过")
        continue

    try:
        meta = yaml.safe_load(head)
    except Exception:
        print(f"  !! {bid} frontmatter 解析失败，跳过")
        continue

    name = meta.get("name", "?")
    bak = f"{found}.pre_mark_{stamp}"
    shutil.copy2(found, bak)

    if op == "pin":
        meta["pinned"] = True
        meta.pop("archived", None)
        print(f"  {bid}  {name}")
        print(f"    pinned: True  备份 -> {os.path.basename(bak)}")
    else:
        meta["archived"] = True
        meta.pop("pinned", None)
        print(f"  {bid}  {name}")
        print(f"    archived: True  备份 -> {os.path.basename(bak)}")

    new_head = yaml.safe_dump(meta, allow_unicode=True, sort_keys=True, default_flow_style=False).strip()
    with open(found, "w", encoding="utf-8") as f:
        f.write(f"---\n{new_head}\n---\n{body}")

print()
print("完成。重启后生效（gateway 有 5 分钟 buckets 缓存）：")
print("  cd /root/Haven-Ombre && docker compose restart ombre-gateway")
PY
