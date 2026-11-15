# Codex Usage

Shows your ChatGPT Codex allowance **left** on the Noctalia bar. Click for
both allowance windows, today's pace, optional credits, and calendar token totals.

| Field | Value |
| --- | --- |
| ID | `linnovs/codex-usage` |
| Requires | Noctalia plugin API 42; ChatGPT sign-in saved by `codex login` |
| Entries | Widget `usage`, attached panel `panel`, background service `sync` |

## Setup

Run `codex login` and sign in with ChatGPT, then enable **Codex Usage** in
Noctalia and add `linnovs/codex-usage:usage` to the bar. The plugin reads
`$CODEX_HOME/auth.json`, or `~/.codex/auth.json` when `CODEX_HOME` is unset.
An explicit `CODEX_HOME` never falls back to another login. Credentials stored
only in an OS keyring are not supported; the ChatGPT tokens must be in that file.
API keys do not provide this ChatGPT allowance and are not used.

## Bar and panel

Auto mode prefers the 5-hour window and otherwise displays weekly allowance.
Windows are identified by their duration, regardless of their primary/secondary
position in the response. For example, 42% used in the 5-hour window displays
`58%  3h 12m` when that much time remains. Weekly mode displays just `29%`
when 71% is used. Below one hour the countdown becomes `12m`.

The tooltip lists used, leftover, and reset time for both available windows.
A warning changes the bar color. Clicking opens the attached panel, with leftover
figures, spent progress bars, reset countdowns, today pace, credits, calendar
tokens, refresh time, and status. Refresh checks immediately. A failed check
keeps the last good numbers; `partial` means only one endpoint succeeded.
Absent windows and token buckets display no invented values.

## Settings

| Key | Default | Behavior |
| --- | --- | --- |
| `bar_window` | `auto` | `auto`, `5h`, or `weekly`; selecting a missing window shows `—` |
| `bar_metric` | `used` | `used` or `left` (remaining) percentage on the bar |
| `refresh_minutes` | `1` | Minutes between checks, clamped to 1–1440 |
| `weekly_warn_mode` | `today` | `today` pace or `fixed` weekly used threshold; color only |
| `weekly_warn_percent` | `80` | Fixed mode warns when weekly used reaches this percentage (1–100) |
| `show_credits` | `true` | Show credits and banked resets when returned by the server |

Today mode uses `budget = weekly allowance left / local calendar days until reset`
(minimum one day) and warns when `used today >= budget`. For example, 60% left
with four days remaining gives a 15 percentage-point budget; 18 points used today
triggers a warning. The budget shrinks as the remaining allowance falls.
Usage today is the change since the first observed sample that local day, not a
reconstruction of usage while the plugin was stopped. A new weekly window clears
the baseline to zero; first-ever observation uses the current usage as baseline.
A reset later today counts as one day. No weekly reset time means the today
budget is unavailable; fixed mode still works.

Calendar tokens come from profile buckets, independently of allowance windows.
Today requires a bucket matching the local date. If the latest bucket is older,
today stays `—` and the footer shows its date. Weekly rows use the supplied
seven-day buckets covering this and last week. Some responses omit weekly
buckets; those rows stay `—`. The plugin does not reinterpret a rolling allowance
as a calendar week or substitute old tokens for today.

## IPC

```sh
noctalia msg plugin linnovs/codex-usage:sync all refresh
noctalia msg panel-toggle linnovs/codex-usage:panel
```

## Network and storage

Each check makes authenticated HTTPS GET requests to:

- `https://chatgpt.com/backend-api/wham/usage`
- `https://chatgpt.com/backend-api/wham/profiles/me`

Requests use a bearer token and the saved ChatGPT account ID when present. An
expired token, a token within two minutes of expiry, or a 401 triggers at most
one refresh through `POST https://auth.openai.com/oauth/token`, followed by a
retry. The refresh uses the Codex public OAuth client and preserves a refresh
token when the response does not replace it. Missing or rejected credentials
are shown in the panel; run `codex login` again to replace them.

The plugin reads and, after successful refresh, writes the same auth file,
preserving other fields. It rechecks that login before saving to avoid replacing
a login that changed during the request. It writes `usage.json` under
`noctalia.pluginDataDir()` with last readings, calendar buckets, refresh times,
account ID, and local-day baseline. Access, refresh, and ID tokens never enter
that cache or logs. Cached numbers are cleared when the account ID changes.
It contacts only `chatgpt.com` and `auth.openai.com`.

## Development checks

From the repository root, with the Luau CLI installed:

```sh
luau codex-usage/lib/usage_test.luau
luau codex-usage/service_test.luau
luau codex-usage/ui_test.luau
```

The service/UI checks use deterministic host boundaries and never read real
credentials or contact the network. A running Noctalia session is needed for
final visual verification, real sign-in, and IPC testing.
