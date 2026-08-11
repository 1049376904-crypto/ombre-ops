#!/usr/bin/env bash
# 两件事：
#   1. 逐个模型探额度，看清到底哪几个 403
#   2. 逐个路径 + 两种 payload 格式探 rerank，找出能返回 200 的组合
# 只读，不改配置。会消耗极少量 token（每个模型 1 token 输出）。
set -uo pipefail
G=haven-gateway

echo "########## 1. 逐模型探额度 ##########"
docker exec -i "$G" python - <<'PY'
import yaml, json, httpx

cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))

# 收集所有 (用途, model, base_url, api_key)
targets = []
def add(label, section):
    s = cfg.get(section, {}) or {}
    m = s.get("model") or ""
    b = s.get("base_url") or cfg.get("dehydration", {}).get("base_url") or ""
    k = s.get("api_key") or cfg.get("dehydration", {}).get("api_key") or ""
    if m and b and k:
        targets.append((label, m, b.rstrip("/"), k))

add("dehydration 脱水/打标", "dehydration")
add("persona 人格状态", "persona")
add("portrait 画像", "portrait")
add("reflection 日印象", "reflection")
add("dream 夜梦", "dream")

g = cfg.get("gateway", {}) or {}
ds_model = g.get("domain_sentinel_model")
if ds_model:
    targets.append((
        "domain_sentinel 域哨兵",
        ds_model,
        (g.get("domain_sentinel_base_url") or cfg["dehydration"]["base_url"]).rstrip("/"),
        cfg["dehydration"].get("api_key", ""),
    ))

seen = set()
for label, model, base, key in targets:
    tag = (model, base)
    dup = "  (与上面同一模型)" if tag in seen else ""
    seen.add(tag)
    try:
        r = httpx.post(
            f"{base}/chat/completions",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            json={"model": model, "max_tokens": 1,
                  "messages": [{"role": "user", "content": "hi"}]},
            timeout=25,
        )
        if r.status_code == 200:
            print(f"  OK    {label:24s} {model}{dup}")
        else:
            try:
                err = r.json().get("error", {})
                msg = str(err.get("message") or "")[:90]
                code = err.get("code") or err.get("type") or ""
            except Exception:
                msg, code = r.text[:90], ""
            print(f"  {r.status_code}   {label:24s} {model}")
            print(f"        {code}: {msg}{dup}")
    except Exception as e:
        print(f"  ERR   {label:24s} {model}  {str(e)[:80]}")

print()
print("  --- embedding（召回的命脉）---")
e = cfg.get("embedding", {}) or {}
try:
    r = httpx.post(
        f"{str(e.get('base_url')).rstrip('/')}/embeddings",
        headers={"Authorization": f"Bearer {e.get('api_key')}", "Content-Type": "application/json"},
        json={"model": e.get("model"), "input": "测试"},
        timeout=25,
    )
    print(f"  {r.status_code}  {e.get('model')}  {r.text[:100] if r.status_code != 200 else '正常'}")
except Exception as ex:
    print("  ERR", str(ex)[:100])
PY

echo
echo "########## 2. 探 rerank 的正确端点与 payload ##########"
echo "代码写死了 endpoint = base_url + \"/rerank\"，且 payload 用 documents=[字符串]"
echo "下面把各种组合都试一遍，找哪个回 200："
echo
docker exec -i "$G" python - <<'PY'
import yaml, json, httpx

cfg = yaml.safe_load(open("/app/config.yaml", encoding="utf-8"))
rc = cfg.get("reranker", {}) or {}
ec = cfg.get("embedding", {}) or {}
key = rc.get("api_key") or ec.get("api_key") or ""
model = rc.get("model") or "qwen3-rerank"

host = "https://ws-6u6u948ov18iuv19.cn-beijing.maas.aliyuncs.com"
q = "回复风格偏好"
docs = ["妍妍喜欢闷骚成熟型的语气", "今天天气不错", "学习闷骚风格与专属暗号"]

# 候选端点（完整 URL，不再拼接）
endpoints = [
    f"{host}/compatible-mode/v1/rerank",
    f"{host}/compatible-api/v1/rerank",
    f"{host}/compatible-api/v1/rerankers/rerank",
    f"{host}/compatible-api/v1/reranks/rerank",
    f"{host}/api/v1/services/rerank/text-rerank/text-rerank",
    f"{host}/compatible-mode/v1/rerankers/rerank",
]

# 两种 payload：OpenAI/SiliconFlow 风格 vs DashScope 原生风格
payloads = {
    "siliconflow(documents=str)": {
        "model": model, "query": q, "documents": docs, "return_documents": False,
    },
    "dashscope(input.documents)": {
        "model": model,
        "input": {"query": q, "documents": docs},
        "parameters": {"return_documents": False, "top_n": 3},
    },
}

for ep in endpoints:
    for name, body in payloads.items():
        try:
            r = httpx.post(
                ep,
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                json=body, timeout=20,
            )
            flag = "  <<< 成功" if r.status_code == 200 else ""
            short = r.text[:150].replace("\n", " ")
            print(f"  [{r.status_code}] {ep.replace(host,'')}")
            print(f"        payload={name}  {short}{flag}")
        except Exception as e:
            print(f"  [ERR] {ep.replace(host,'')}  payload={name}  {str(e)[:80]}")
    print()
PY

echo
echo "########## 3. 代码里 rerank 端点是怎么拼的 ##########"
docker exec -i "$G" sh -lc 'grep -n "rerank" /app/reranker_engine.py | head -20'

echo
echo "########## 完毕。只读，未改任何配置。 ##########"
