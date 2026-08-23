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
import ssl
import sys
import urllib.request
from datetime import date, datetime, timezone
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
    "moonshot",
    "minimax",
    "zai",
    "z-ai",
}

# 除一方无前缀 key 外，额外保留的路由前缀（国内模型多以 <provider>/<model> 记录）。
ALLOWED_ROUTE_PREFIXES = (
    "dashscope/",
    "qwen/",
    "moonshotai/",
    "moonshot/",
    "minimax/",
    "xai/",
    "z-ai/",
    "zai/",
)

# 只收对话类模型；embedding/audio/image/moderation 无 token 计费意义。
ALLOWED_MODES = {"chat", "responses", "completion"}

# Official first-party overrides protect the bundled catalog from stale or reseller
# rows in aggregation feeds. Values are USD / MTok. `lt` selects a full-request
# long-context tier; `pm` is the API Priority multiplier.
OFFICIAL_OVERRIDES = {
    # OpenAI Docs: developers.openai.com/api/docs/models and learn.chatgpt.com/docs/pricing
    "gpt-5.6": {"in": 4.0, "out": 20.0, "cr": 0.4, "cw": 5.0, "lt": 272_000,
                "lin": 8.0, "lout": 30.0, "lcr": 0.8, "lcw": 10.0, "pm": 2.0, "p": "openai"},
    "gpt-5.6-sol": {"in": 4.0, "out": 20.0, "cr": 0.4, "cw": 5.0, "lt": 272_000,
                    "lin": 8.0, "lout": 30.0, "lcr": 0.8, "lcw": 10.0, "pm": 2.0, "p": "openai"},
    "gpt-5.6-terra": {"in": 2.0, "out": 12.0, "cr": 0.2, "cw": 2.5, "lt": 272_000,
                      "lin": 4.0, "lout": 18.0, "lcr": 0.4, "lcw": 5.0, "pm": 2.0, "p": "openai"},
    "gpt-5.6-luna": {"in": 0.2, "out": 1.2, "cr": 0.02, "cw": 0.25, "lt": 272_000,
                     "lin": 0.4, "lout": 1.8, "lcr": 0.04, "lcw": 0.5, "pm": 2.0, "p": "openai"},
    "gpt-5.5": {"in": 5.0, "out": 30.0, "cr": 0.5, "lt": 272_000,
                "lin": 10.0, "lout": 45.0, "lcr": 1.0, "pm": 2.0, "p": "openai"},
    "gpt-5.4": {"in": 2.5, "out": 15.0, "cr": 0.25, "lt": 272_000,
                "lin": 5.0, "lout": 22.5, "lcr": 0.5, "pm": 2.0, "p": "openai"},

    # Anthropic: platform.claude.com/docs/en/about-claude/pricing (5-minute cache writes)
    "claude-fable-5": {"in": 10.0, "out": 50.0, "cr": 1.0, "cw": 12.5, "p": "anthropic"},
    "claude-mythos-5": {"in": 10.0, "out": 50.0, "cr": 1.0, "cw": 12.5, "p": "anthropic"},
    "claude-opus-5": {"in": 5.0, "out": 25.0, "cr": 0.5, "cw": 6.25, "p": "anthropic"},
    "claude-opus-4-8": {"in": 5.0, "out": 25.0, "cr": 0.5, "cw": 6.25, "p": "anthropic"},
    "claude-sonnet-5": {"in": 2.0, "out": 10.0, "cr": 0.2, "cw": 2.5, "p": "anthropic"},

    # Google AI for Developers: ai.google.dev/gemini-api/docs/pricing
    "gemini-3.5-flash": {"in": 1.5, "out": 9.0, "cr": 0.15, "p": "vertex_ai-language-models"},
    "gemini-3.5-flash-lite": {"in": 0.3, "out": 2.5, "cr": 0.03, "p": "vertex_ai-language-models"},
    "gemini-2.5-pro": {"in": 1.25, "out": 10.0, "cr": 0.125, "lt": 200_000,
                       "lin": 2.5, "lout": 15.0, "lcr": 0.25, "p": "gemini"},

    # xAI: docs.x.ai/developers/models/grok-4.6
    "xai/grok-4.6": {"in": 2.0, "out": 6.0, "cr": 0.5, "lt": 200_000,
                     "lin": 4.0, "lout": 12.0, "lcr": 1.0, "p": "xai"},

    # DeepSeek: api-docs.deepseek.com/quick_start/pricing
    "deepseek-v4-flash": {"in": 0.14, "out": 0.28, "cr": 0.0028, "cw": 0.0, "p": "deepseek"},
    "deepseek-v4-pro": {"in": 0.435, "out": 0.87, "cr": 0.003625, "cw": 0.0, "p": "deepseek"},

    # Kimi API Platform: platform.kimi.ai/docs/pricing
    "moonshot/kimi-k3": {"in": 3.0, "out": 15.0, "cr": 0.3, "p": "moonshot"},
    "moonshot/kimi-k2.7-code": {"in": 0.95, "out": 4.0, "cr": 0.19, "p": "moonshot"},
    "moonshot/kimi-k2.7-code-highspeed": {"in": 1.9, "out": 8.0, "cr": 0.38, "p": "moonshot"},
    "moonshot/kimi-k2.6": {"in": 0.95, "out": 4.0, "cr": 0.16, "p": "moonshot"},
    "moonshot/kimi-k2.5": {"in": 0.6, "out": 3.0, "cr": 0.1, "p": "moonshot"},

    # MiniMax: platform.minimax.io/docs/guides/pricing-paygo
    "minimax/MiniMax-M2.7": {"in": 0.3, "out": 1.2, "cr": 0.06, "cw": 0.375, "p": "minimax"},
    "minimax/MiniMax-M2.7-highspeed": {"in": 0.6, "out": 2.4, "cr": 0.06, "cw": 0.375, "p": "minimax"},

    # Z.AI: docs.z.ai/guides/overview/pricing
    "zai/glm-5.1": {"in": 1.4, "out": 4.4, "cr": 0.26, "cw": 0.0, "p": "zai"},
    "zai/glm-5": {"in": 1.0, "out": 3.2, "cr": 0.2, "cw": 0.0, "p": "zai"},

    # Alibaba Cloud international catalog: help.aliyun.com/en/model-studio/model-pricing
    "dashscope/qwen3.8-max": {"in": 2.0, "out": 6.0, "cr": 0.25, "p": "dashscope"},
}
OFFICIAL_REVIEW_AFTER = date(2026, 11, 21)


def fetch_upstream() -> dict:
    req = urllib.request.Request(UPSTREAM_URL, headers={"User-Agent": "TokenClock-pricing-snapshot"})
    context = ssl.create_default_context()
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    with urllib.request.urlopen(req, timeout=60, context=context) as resp:
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
    for key, official in OFFICIAL_OVERRIDES.items():
        models[key] = dict(official)
    return dict(sorted(models.items()))


def render_snapshot(models: dict) -> str:
    """逐模型一行的 JSON 文本：价格变化在 diff 里一行可见。"""
    meta = {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "unit": "USD/MTok",
        "source": "BerriAI/litellm model_prices_and_context_window.json",
        "officialOverrides": len(OFFICIAL_OVERRIDES),
        "officialReviewAfter": OFFICIAL_REVIEW_AFTER.isoformat(),
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

    if datetime.now(timezone.utc).date() > OFFICIAL_REVIEW_AFTER:
        print(
            "error: OpenAI GPT-5.6 promotional pricing review date has passed; "
            "re-verify official overrides before regenerating",
            file=sys.stderr,
        )
        return 1

    upstream = fetch_upstream()
    models = build_models(upstream)
    if not models:
        print("error: 裁剪后模型数为 0，上游格式可能已变化，拒绝生成", file=sys.stderr)
        return 1
    # 保底：一方核心模型必须在，否则上游改名/结构变化应人工介入
    for must in (
        "claude-sonnet-5", "gpt-5.6-sol", "gemini-3.5-flash", "xai/grok-4.6",
        "deepseek-v4-pro", "moonshot/kimi-k3", "minimax/MiniMax-M2.7",
        "zai/glm-5.1", "dashscope/qwen3.8-max",
    ):
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
