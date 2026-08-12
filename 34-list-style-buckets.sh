#!/usr/bin/env bash
# 列出正文含「风格/语气类词汇」的桶，紧凑版：每条 3 行，一屏能扫完。
# 想看某条全文： bash 34-list-style-buckets.sh <bucket_id>
set -uo pipefail

ONE="${1:-}"

docker exec -i -e ONE="$ONE" haven-ombre python - <<'PY'
import glob, re, os

only = (os.environ.get("ONE") or "").strip()

STYLE = re.compile(r"闷骚|欲拒还迎|语气|风格|扮演|人设|设定|省略号|模仿|学着|daddy感|嘲讽|活人感|直白")
DIRECTIVE = re.compile(
    r"(我(答应|保证|决定|会|尽量|试着)[^。；\n]{0,40}(说话|语气|风格|少说|多说|直白|稳重|模仿))"
    r"|((要求|希望|让|不许|不让)我[^。；\n]{0,30}(语气|风格|说话|回复|催|问))"
    r"|(不要[^。；\n]{0,20}(加引号|太长|太短|扮演))"
)

rows = []
for path in glob.glob("/app/buckets/**/*.md", recursive=True):
    try:
        text = open(path, encoding="utf-8").read()
    except Exception:
        continue
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    head, body = (m.group(1), text[m.end():]) if m else ("", text)
    body = body.strip()
    if not STYLE.search(body):
        continue

    def f(pat, d=""):
        mm = re.search(pat, head, re.M)
        return mm.group(1).strip() if mm else d

    flags = [k for k in ("pinned", "protected", "anchor", "self_anchor", "resolved", "archived")
             if re.search(rf"^{k}\s*:\s*true", head, re.M)]
    rows.append({
        "id": f(r"^id\s*:\s*(\S+)", "?"),
        "name": f(r"^name\s*:\s*(.+)$", os.path.basename(path)),
        "imp": f(r"^importance\s*:\s*(\d+)", "?"),
        "la": f(r"^last_active\s*:\s*'?([^'\n]+)")[:10],
        "flags": ",".join(flags) or "-",
        "n": len([d for d in DIRECTIVE.findall(body) if any(d)]),
        "body": body,
        "chars": len(body),
    })

if only:
    for r in rows:
        if r["id"] == only:
            print(f"{r['id']}  {r['name']}")
            print(f"importance:{r['imp']}  标记:{r['flags']}  末次活跃:{r['la']}  {r['chars']}字")
            print("-" * 60)
            print(r["body"])
            break
    else:
        print(f"没找到 {only}")
    raise SystemExit

rows.sort(key=lambda r: r["n"], reverse=True)
print(f"共 {len(rows)} 条，按「指令句数」降序。越靠前越像在给模型下命令。\n")
for i, r in enumerate(rows, 1):
    mark = "!" * r["n"] if r["n"] else " "
    print(f"[{i:>2}] {r['id']}  指令{r['n']}{mark:<3} imp{r['imp']:<3} {r['flags']:<10} {r['name'][:30]}")
    prev = r["body"].replace("\n", " ")
    print(f"     {prev[:150]}")
    if len(prev) > 150:
        print(f"     ...（共 {r['chars']} 字，看全文： bash 34-list-style-buckets.sh {r['id']}）")
    print()
PY
