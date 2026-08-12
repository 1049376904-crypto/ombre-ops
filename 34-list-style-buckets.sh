#!/usr/bin/env bash
# 把 23 条「正文含风格类词汇」的桶完整列出来，附 id / 名称 / 标记 / 正文全文，
# 好让你逐条决定：保留、只删风格句、还是归档。
# 只读。输出较长，建议 bash 34-list-style-buckets.sh > /tmp/style.txt 再看。
set -uo pipefail

docker exec -i haven-ombre python - <<'PY'
import glob, re, os

STYLE = re.compile(r"闷骚|欲拒还迎|语气|风格|扮演|人设|设定|省略号|模仿|学着|学习.*语气|daddy感|嘲讽|活人感|直白")
# 明确的「行为指令」句式，这类最容易被模型当命令执行
DIRECTIVE = re.compile(r"(我(答应|保证|决定|会|尽量|试着)[^。；\n]{0,40}(说话|语气|风格|少说|多说|直白|稳重|模仿))"
                       r"|((要求|希望|让)我[^。；\n]{0,30}(语气|风格|说话|回复))"
                       r"|(不要[^。；\n]{0,20}(加引号|太长|太短|扮演))")

rows = []
for path in glob.glob("/app/buckets/**/*.md", recursive=True):
    try:
        text = open(path, encoding="utf-8").read()
    except Exception:
        continue
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    head, body = (m.group(1), text[m.end():]) if m else ("", text)
    if not STYLE.search(body):
        continue

    def f(pat, default=""):
        mm = re.search(pat, head, re.M)
        return mm.group(1).strip() if mm else default

    bid = f(r"^id\s*:\s*(\S+)", "?")
    name = f(r"^name\s*:\s*(.+)$", os.path.basename(path))
    imp = f(r"^importance\s*:\s*(\d+)", "?")
    typ = f(r"^type\s*:\s*(\S+)", "?")
    la = f(r"^last_active\s*:\s*'?([^'\n]+)")
    flags = []
    for k in ("pinned", "protected", "anchor", "self_anchor", "resolved", "digested"):
        if re.search(rf"^{k}\s*:\s*true", head, re.M):
            flags.append(k)
    directives = DIRECTIVE.findall(body)
    rows.append({
        "id": bid, "name": name, "imp": imp, "type": typ, "la": la[:10],
        "flags": ",".join(flags) or "-",
        "chars": len(body.strip()),
        "n_directive": len([d for d in directives if any(d)]),
        "body": body.strip(),
        "rel": os.path.relpath(path, "/app/buckets"),
    })

rows.sort(key=lambda r: (r["n_directive"], r["chars"]), reverse=True)

print(f"共 {len(rows)} 条。按「指令句数量」降序——越靠前越像在给模型下命令。\n")
print("=" * 72)
for i, r in enumerate(rows, 1):
    print(f"\n[{i:>2}] {r['id']}   指令句:{r['n_directive']}   imp:{r['imp']}  type:{r['type']}  标记:{r['flags']}  末次活跃:{r['la']}")
    print(f"     名称: {r['name']}")
    print(f"     路径: {r['rel']}")
    print(f"     正文({r['chars']}字):")
    for line in r["body"].splitlines():
        print(f"       {line}")
    print("-" * 72)

print("\n\n########## 速查表（复制这段给小克，标上你的决定）##########")
print(f"{'序':>3} {'id':<14} {'指令':>4} {'标记':<12} 名称")
for i, r in enumerate(rows, 1):
    print(f"{i:>3} {r['id']:<14} {r['n_directive']:>4} {r['flags']:<12} {r['name'][:36]}")
print("""
决定可以写成：
  保留      = 不动
  删风格句  = 只去掉「我该怎么说话」的句子，保留事件
  归档      = 设 type=archived，不再参与常规召回
  pin       = 设为 pinned，进 Core Memory 每轮在场
""")
PY
