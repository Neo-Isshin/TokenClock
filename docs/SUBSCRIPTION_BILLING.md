# Subscription billing and renewal reminders

Implemented on macOS Glass, macOS Normal, Windows, and Linux.

## Account settings
- The quota account pencil editor includes automatic billing metadata, an optional manual override, monthly/yearly/unknown cadence, auto-renew status, and reminders.
- Reminder lead times: **1, 2, 3, 7 calendar days**; default 3 days.
- Manual overrides survive quota refresh and verified account-ID migration.
- Manual recurring dates advance from their original calendar anchor (Jan 31 → Feb 28 → Mar 31; leap years covered).
- Canceled subscriptions use expiry wording. No payments, cancellations, or subscription changes are performed.

## Automatic discovery (verified 2026-09-27)
| Provider | Current support | Boundaries |
| --- | --- | --- |
| Codex / ChatGPT | Existing native OAuth credential + GET /backend-api/subscriptions?account_id=…; active_until, will_renew, billing_period | Undocumented web endpoint, not an app-server billing API. Exact account ID or verified email fallback must match. No browser cookie import; errors fail closed. |
| Cursor | Existing IDE login; GET /api/auth/stripe combined with /api/usage-summary | A confirmed individual monthly subscription can use its billing boundary. Annual plans' monthly usage reset is **not** their renewal date. Team/free/unknown states do not create a guessed renewal. pendingCancellationDate is expiry metadata. |
| Claude Code | Manual fallback | Existing OAuth usage/profile support does not establish the next payment date. Web billing would need a separate authenticated web session; no silent browser-cookie import added. |
| Antigravity / Gemini | Manual fallback | Local model quotas and Google One billing are separate. Google One may be monthly, yearly, or third-party-billed. |
| Grok Bot | Manual fallback | Sand weekly allowance does not prove a subscription renewal. Do not inherit Cursor billing or confuse it with X Premium/SuperGrok. |
| Z.ai / BigModel | Manual fallback | Live existing-key quota response checked: data contains level/limits; nextResetTime is quota reset, not renewal. |

Codex and Cursor refresh opportunistically with quota reads and on a six-hour background check. Billing success is cached six hours, failed reads throttled one hour. Auto metadata older than seven days does not generate new notices. Historical account metadata can still be displayed; it is not a guarantee that an inactive account's payment state is current.

## Notifications
- Existing bell UI; selecting a billing notification opens the relevant account editor (macOS/Linux also opens its quota panel).
- Delivery/read state persists locally; one notification per account/due timestamp.
- Changing lead time does not resend the same notice. Cancellation updates wording without a new delivery.
- Superseded/disabled schedules are hidden while their delivery ledger remains.
- Checks run while TokenClock is running and on startup. This is not an OS background alarm when the app is quit.
- No auth tokens or raw billing response bodies are persisted.

## Evidence
- OpenAI app-server documented account API: https://learn.chatgpt.com/docs/app-server#api-overview-1
- Open-source subscription endpoint reference (research only): https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/OpenAIWeb/OpenAISubscriptionMetadata.swift
- Cursor billing and monthly usage reset rules: https://prod.cursor.com/help/account-and-billing/billing
- Cursor dashboard endpoint reference: https://github.com/ItsJazii/pane/blob/main/docs/providers.md
- Claude billing changes: https://support.claude.com/en/articles/10185996-how-to-change-your-pro-plan-from-monthly-to-annual-billing
- Google One billing options: https://support.google.com/googleone/answer/16476811

Tests cover monthly vs annual billing, cancellation/inactive transitions, exact account/workspace matching, optional legacy storage fields, persistent deduplication, disabled/missing/stale dates, reminder thresholds, month ends, leap years, and manual preference preservation.
