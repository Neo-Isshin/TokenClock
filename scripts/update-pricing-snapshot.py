#!/usr/bin/env python3
"""Extract TokenClock's compact USD token rates from Ailyre's official-source price board.

The VPS timer reads the local Ailyre data.json atomically. Other callers fetch
https://www.ailyre.com/prices/data.json. No GitHub feed, Actions or manual PR.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import ssl
import urllib.request

UPSTREAM_URL = "https://www.ailyre.com/prices/data.json"
REPO_ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_PATH = REPO_ROOT / "Sources/TokenClock/Resources/pricing-snapshot.json"
PROVIDERS = {"openai": "openai", "anthropic": "anthropic", "google": "gemini", "xai": "xai",
             "deepseek": "deepseek", "kimi": "moonshot", "qwen": "dashscope", "minimax": "minimax", "zai": "zai"}
PREFIXES = {"xai": "xai/", "kimi": "moonshot/", "qwen": "dashscope/", "minimax": "minimax/", "zai": "zai/"}
FIELDS = {"in": "input", "out": "output", "cr": "cache_read", "cw": "cache_write"}


def fetch_upstream():
    local = os.environ.get("TOKENCLOCK_AILYRE_PRICES_FILE")
    if local:
        return json.loads(Path(local).read_text())
    request = urllib.request.Request(UPSTREAM_URL, headers={"User-Agent": "TokenClock-pricing-catalog"})
    context = ssl.create_default_context()
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    with urllib.request.urlopen(request, timeout=30, context=context) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError("Ailyre price response is too large")
        return json.loads(data)


def amount(value):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 10000:
        raise ValueError("invalid USD/MTok price")
    return float(value)


def model_id(row, use_native=True):
    name = str((row.get("native_id") if use_native else None) or row.get("model", "")).strip()
    name = re.sub(r"\s*\([^)]*\)", "", name)
    if row["provider"] == "anthropic":
        name = re.sub(r"(?i)^claude[ -]+(haiku|sonnet|opus|fable|mythos)[ -]+(\d+(?:[.-]\d+)*)",
                      lambda m: "claude-" + m[1].lower() + "-" + m[2].replace(".", "-"), name)
    name = re.sub(r"\s+", "-", name).strip("-")
    if row["provider"] != "minimax":
        name = name.lower()
    # Human labels can include a short release date not used by historical logs.
    if not use_native:
        name = re.sub(r"-\d{4}$", "", name)
    if not name or len(name) > 150 or not re.fullmatch(r"[a-zA-Z0-9./_-]+", name):
        return None
    return PREFIXES.get(row["provider"], "") + name


def rates(row):
    result = {k: amount(row.get(v)) for k, v in FIELDS.items()}
    if result["in"] is None or result["out"] is None:
        raise ValueError("missing input/output rate")
    return {k: v for k, v in result.items() if v is not None}


def unique_rate(rows):
    values = [rates(r) for r in rows]
    if not values:
        return None
    # Variant-dependent rates must not silently be replaced by the cheapest row.
    return values[0] if all(x == values[0] for x in values) else None


def threshold(row):
    text = str(row.get("variant", "")) + " " + str(row.get("model", ""))
    match = re.search(r"(?:≥|>|＞)\s*([\d,.]+)\s*([km])?\s*(?:input\s*)?(?:tokens?)?", text, re.I)
    if not match:
        return None
    value = float(match[1].replace(",", "")) * {"k": 1000, "m": 1000000, None: 1}[match[2].lower() if match[2] else None]
    return int(value) if value > 0 and value.is_integer() else None


def build_models(upstream, previous=None):
    grouped = {}
    for row in upstream["rows"]:
        if not isinstance(row, dict) or row.get("provider") not in PROVIDERS or row.get("category") != "api":
            continue
        if row.get("currency") != "USD" or row.get("unit") != "USD / 1M tokens" or not row.get("original"):
            continue
        if row.get("tier") not in ("standard", "long", "fast"):
            continue
        if re.search(r"embedding|\b(?:audio|image|tts|transcribe|banana|robotics)\b", str(row.get("model", "")), re.I):
            continue
        key = model_id(row)
        if key:
            rates(row)  # Validate every eligible row, including ambiguous groups.
            grouped.setdefault(key, []).append(row)
    models = {}
    for key, rows in grouped.items():
        standard = [r for r in rows if r["tier"] == "standard"]
        base = unique_rate(standard)
        if base is None:
            continue
        old = (previous or {}).get(key, {})
        # Missing cache/advanced fields retain last-known values; absent is not free.
        price = {**old, **base, "p": PROVIDERS[rows[0]["provider"]]}
        long_rows = [r for r in rows if r["tier"] == "long"]
        tiers = {threshold(r) for r in long_rows}
        long = unique_rate(long_rows)
        if long and len(tiers) == 1 and None not in tiers:
            price["lt"] = tiers.pop()
            for field, value in long.items():
                price["l" + field] = value
        fast_rows = [r for r in rows if r["tier"] == "fast" and "ultrafast" not in str(r.get("variant", "")).lower()
                     and threshold(r) is None]
        fast = unique_rate(fast_rows)
        if fast and base["in"] > 0 and base["out"] > 0:
            multiplier = fast["in"] / base["in"]
            shared = [k for k in base if k in fast and base[k] > 0]
            if multiplier >= 1 and all(math.isclose(fast[k] / base[k], multiplier, rel_tol=1e-7) for k in shared):
                price["pm"] = round(multiplier, 8)
        models[key] = price
        # Keep both the documented API ID and the stable human-label spelling.
        alias = model_id(rows[0], use_native=False)
        if alias and alias != key:
            models[alias] = dict(price)
    return dict(sorted(models.items()))


def validated_models(upstream, current):
    if not isinstance(upstream, dict) or not isinstance(upstream.get("rows"), list) or upstream.get("unit") != "USD / 1M tokens":
        raise ValueError("invalid Ailyre price schema/unit")
    if not isinstance(upstream.get("generated_at"), str):
        raise ValueError("missing Ailyre revision")
    previous = current.get("models", {})
    fresh = build_models(upstream, previous)
    if len(fresh) < 40 or not {"openai", "anthropic", "gemini"}.issubset({r["p"] for r in fresh.values()}):
        raise ValueError("Ailyre first-party model coverage is incomplete")
    # Preserve discontinued rows for historical usage. Today's source is leaner
    # than the legacy aggregator, so a ratio against all historical rows is wrong.
    return dict(sorted({**previous, **fresh}.items()))


def snapshot_changed(current, models):
    return current.get("models") != models or current.get("_meta", {}).get("source") != UPSTREAM_URL


def render_snapshot(models, source_generated_at=None):
    meta = {"generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "unit": "USD/MTok", "source": UPSTREAM_URL, "models": len(models)}
    if source_generated_at:
        meta["sourceGeneratedAt"] = source_generated_at
    lines = ['{', '  "_meta": ' + json.dumps(meta, ensure_ascii=False) + ',', '  "models": {']
    for i, (key, value) in enumerate(models.items()):
        lines.append('    ' + json.dumps(key) + ': ' + json.dumps(value, ensure_ascii=False) + (',' if i < len(models) - 1 else ''))
    return '\n'.join(lines + ['  }', '}', ''])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        upstream = fetch_upstream()
        current = json.loads(SNAPSHOT_PATH.read_text()) if SNAPSHOT_PATH.exists() else {}
        models = validated_models(upstream, current)
        if not snapshot_changed(current, models):
            print("Catalog unchanged")
            return 0
        if args.check:
            return 2
        SNAPSHOT_PATH.parent.mkdir(parents=True, exist_ok=True)
        SNAPSHOT_PATH.write_text(render_snapshot(models, upstream["generated_at"]))
        print(f"Updated Ailyre catalog: {len(models)} models")
        return 0
    except (OSError, ValueError, TypeError, OverflowError) as error:
        print(f"Catalog retained: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
