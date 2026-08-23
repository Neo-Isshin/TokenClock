# Pricing catalog sources

Last verified: 2026-08-23. Catalog values are USD per million tokens unless noted.

TokenClock generates the broad model list from LiteLLM, then applies first-party
sentinel overrides in `scripts/update-pricing-snapshot.py`. The override layer is
intentional: aggregation feeds can lag launches, promotions, or provider price cuts.

| Provider | Verified sentinels | Official source | Important rule |
|---|---|---|---|
| OpenAI | GPT-5.6 Sol `$4 / $0.40 / $20` input/cache/output | [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol) | Requests over 272K input use full-request `2x` input/cache and `1.5x` output rates. API Priority is `2x`; ChatGPT Fast credits are a separate `2.5x` credit metric. Promotional Sol pricing must be reviewed after 2026-11-21. |
| Anthropic | Sonnet 5 `$2 / $0.20 / $10`; Opus 5 `$5 / $0.50 / $25`; Fable 5 `$10 / $1 / $50` | [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) | Catalog cache-write price uses the documented 5-minute write rate; 1-hour writes are a distinct higher rate. |
| Google | Gemini 3.5 Flash `$1.50 / $0.15 / $9`; Gemini 2.5 Pro `$1.25 / $0.125 / $10` | [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing) | Gemini 2.5 Pro requests over 200K input use `$2.50 / $0.25 / $15`. |
| xAI | Grok 4.6 `$2 / $0.50 / $6` | [Grok 4.6](https://docs.x.ai/developers/models/grok-4.6) | Requests over 200K use `$4 / $1 / $12` for the full request. xAI responses may also expose exact billed cost ticks. |
| DeepSeek | V4 Flash `$0.14 / $0.0028 / $0.28`; V4 Pro `$0.435 / $0.003625 / $0.87` | [DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing) | Cache-hit input is priced separately and can be far below cache-miss input. |
| Alibaba Cloud | Qwen 3.8 Max international `$2 / $6`, with cached input tracked separately | [Model Studio pricing](https://help.aliyun.com/en/model-studio/model-pricing) | Prices are regional; the catalog uses the international endpoint rate and aliases unprefixed Qwen names to `dashscope/`. |
| Moonshot / Kimi | K3 `$3 / $0.30 / $15`; K2.7 Code `$0.95 / $0.19 / $4`; K2.6 `$0.95 / $0.16 / $4` | [Kimi pricing index](https://platform.kimi.ai/docs/pricing/chat) | Direct first-party models use `moonshot/` catalog keys; reseller rows remain distinct. |
| MiniMax | M2.7 `$0.30 / $0.06 / $1.20`; Highspeed `$0.60 / $0.06 / $2.40` | [MiniMax pay-as-you-go](https://platform.minimax.io/docs/guides/pricing-paygo) | Prompt cache writes are `$0.375/MTok` for both variants. |
| Z.AI | GLM-5.1 `$1.40 / $0.26 / $4.40`; GLM-5 `$1 / $0.20 / $3.20` | [Z.AI pricing](https://docs.z.ai/guides/overview/pricing) | Direct first-party models use `zai/` keys; unprefixed GLM names resolve to them. |

The displayed dollar amount is always an API-equivalent estimate. Subscription
allowances, workspace credits, promotions, negotiated rates, tool-call charges,
regional premiums, and taxes are not an API list-price total and must not be
presented as an actual subscription bill.
