#!/usr/bin/env python3
"""生成 TokenClock 价格快照（pricing-snapshot.json）。

数据源：BerriAI/litellm 的 model_prices_and_context_window.json（MIT，日更）。
本脚本裁剪出 TokenClock 关心的厂商与模型，转成 app 内置的紧凑格式：

    {
      "_meta": { "generatedAt": ..., "unit": "USD/MTok", "models": N },
      "models": {
        "claude-sonnet-4-5": {"in": 3.0, "out": 15.0, "cr": 0.3, "cw": 3.75, "p": "anthropic"}
      }
    }

单价单位为 USD / 百万 tokens（比上游 per-token 科学计数法更适合人读与 diff）。
每个模型一行，方便 PR review 时逐行看价格变化。

用法：
    python3 scripts/update-pricing-snapshot.py            # 拉上游 → 写快照
    python3 scripts/update-pricing-snapshot.py --check     # 仅检查上游是否有变化（CI 用）

由 .github/workflows/update-pricing.yml 每周自动运行并对快照发起 PR。
"""

import argparse
import json
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

UPSTREAM_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)
REPO_ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_PATH = REPO_ROOT / "Sources/TokenClock/Resources/pricing-snapshot.json"

# litellm_provider 允许清单：TokenClock 各工具日志里实际会出现的厂商。
# 一方模型（anthropic/openai/gemini 等）在 litellm 里是无前缀 key，
# 第三方托管版本（azure/bedrock/vertex…）用户本地日志不会出现，一律不收。
ALLOWED_PROVIDERS = {
    "anthropic",
    "openai",
    "gemini",
    "vertex_ai-language-models",  # gemini 一方模型挂在这个 provider 下
    "xai",
    "grok",
    "deepseek",
    "dashscope",
    "qwen",
    "moonshotai",
    "minimax",
    "zai",
    "z-ai",
}

# 除一方无前缀 key 外，额外保留的路由前缀（国内模型多以 <provider>/<model> 记录）。
ALLOWED_ROUTE_PREFIXES = (
    "dashscope/",
    "qwen/",
    "moonshotai/",
    "minimax/",
    "z-ai/",
    "zai/",
)

# 只收对话类模型；embedding/audio/image/moderation 无 token 计费意义。
ALLOWED_MODES = {"chat", "responses", "completion"}


def fetch_upstream() -> dict:
    req = urllib.request.Request(UPSTREAM_URL, headers={"User-Agent": "TokenClock-pricing-snapshot"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def per_mtok(value) -> float | None:
    """上游 per-token 单价 → USD/MTok，保留 6 位有效数字。缺失返回 None。"""
    if value is None:
        return None
    v = float(value) * 1_000_000
    if v == 0:
        return 0.0
    # round to 6 significant digits, strip float noise like 0.30000000000000004
    return float(f"{v:.6g}")


def is_relevant(key: str, entry: dict) -> bool:
    if key == "sample_spec" or key.startswith("fallback"):
        return False
    provider = entry.get("litellm_provider")
    if provider not in ALLOWED_PROVIDERS:
        return False
    if entry.get("mode") not in ALLOWED_MODES:
        return False
    if "/" in key:
        return key.startswith(ALLOWED_ROUTE_PREFIXES)
    # 一方无前缀 key：排除 bedrock 点号变体、微调、通配等部署 ID
    if ":" in key or "@" in key or key.startswith(("ft-", "ft:")):
        return False
    return True


def build_models(upstream: dict) -> dict:
    models = {}
    for key, entry in upstream.items():
        if not is_relevant(key, entry):
            continue
        price = {
            "in": per_mtok(entry.get("input_cost_per_token")),
            "out": per_mtok(entry.get("output_cost_per_token")),
            "cr": per_mtok(entry.get("cache_read_input_token_cost")),
            "cw": per_mtok(entry.get("cache_creation_input_token_cost")),
            "p": entry.get("litellm_provider", ""),
        }
        if price["in"] is None or price["out"] is None:
            continue  # 没有输入/输出单价的条目无法计费
        models[key] = {k: v for k, v in price.items() if v is not None}
    return dict(sorted(models.items()))


def render_snapshot(models: dict) -> str:
    """逐模型一行的 JSON 文本：价格变化在 diff 里一行可见。"""
    meta = {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "unit": "USD/MTok",
        "source": "BerriAI/litellm model_prices_and_context_window.json",
        "models": len(models),
    }
    lines = ["{"]
    lines.append(f'  "_meta": {json.dumps(meta, ensure_ascii=False)},')
    lines.append('  "models": {')
    for i, (key, price) in enumerate(models.items()):
        comma = "," if i < len(models) - 1 else ""
        lines.append(f'    {json.dumps(key, ensure_ascii=False)}: {json.dumps(price, ensure_ascii=False)}{comma}')
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="只检查上游变化是否影响快照，不写文件")
    args = parser.parse_args()

    upstream = fetch_upstream()
    models = build_models(upstream)
    if not models:
        print("error: 裁剪后模型数为 0，上游格式可能已变化，拒绝生成", file=sys.stderr)
        return 1
    # 保底：一方核心模型必须在，否则上游改名/结构变化应人工介入
    for must in ("claude-sonnet-4-5", "gpt-5", "gpt-5-codex"):
        if must not in models:
            print(f"error: 核心模型 {must} 缺失，请检查上游变化", file=sys.stderr)
            return 1

    text = render_snapshot(models)
    if args.check:
        current = SNAPSHOT_PATH.read_text() if SNAPSHOT_PATH.exists() else ""
        # _meta.generatedAt 每次都变，比较时剔除
        strip_meta = lambda s: "\n".join(l for l in s.splitlines() if '"_meta"' not in l and '"generatedAt"' not in l)
        if strip_meta(current) == strip_meta(text):
            print("快照无变化")
            return 0
        print("快照需要更新")
        return 2

    SNAPSHOT_PATH.parent.mkdir(parents=True, exist_ok=True)
    SNAPSHOT_PATH.write_text(text)
    print(f"已写入 {SNAPSHOT_PATH.relative_to(REPO_ROOT)}（{len(models)} 个模型）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
