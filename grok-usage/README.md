# Grok Usage

Shows how much of this week's Grok allowance is left. The bar is the
percentage still unused this cycle. The panel, attached to the bar, leads
with how much is left for today (unused percent times the share of cycle time
still before local midnight, or before reset on the cycle's last day), then
the spent progress bar, each product's share of that pool, how
usage changed per check over the last 6 hours, the reset countdown and local
reset time, how much of the allowance window has passed, and when the reading
was last updated.

## Plugin

| Field | Value |
| --- | --- |
| ID | `linnovs/grok-usage` |
| Entries | Bar widget: `usage`; panel: `panel`; service: `sync` |

## Requirements

Sign in once with the Grok CLI:

```sh
grok login
```

The plugin reads the token that command saves. It does not ask for an xAI API
key: an API key cannot read this weekly allowance.

## Usage

Add the **Grok Usage** widget from the bar's Add-widget picker
(`linnovs/grok-usage:usage`). It shows how much of the week is still unused,
for example `38%` when 62% has been spent.

Left-click opens the panel next to the widget, attached to the bar. The panel
is 320 wide and sized to its content (up to 560): a refresh button at the top
right, how much is left today (unused percent × time until local midnight ÷
time left in the cycle; on the last day of the cycle it uses time until reset
and reads "left until reset"), the percentage spent as a bar, a row for each
product in `productUsage` (Grok Build, Grok Chat, and whatever else the
billing response lists), usage per check over the last 6 hours, the time
until the allowance resets (`3d 14h`, or `14h` / `42m` when less than a day
remains) with the local reset time, how much of the week has passed, when the
reading was last updated, and any status message when a check fails. That
figure recalculates whenever usage changes and as the clock runs.

Open the same panel with:

```sh
noctalia msg panel-toggle linnovs/grok-usage:panel
```

The `sync` service checks usage while the plugin is enabled. It keeps the last
good reading so the bar is not blank on the next login.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `15` | Minutes between automatic checks. Clamped to 1–1440. The panel button does not wait for this. |

## IPC

```sh
noctalia msg plugin linnovs/grok-usage:sync all refresh
```

`refresh` checks usage immediately, the same as the panel button.

## Notes

- The percentage is `creditUsagePercent` from
  `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`. That is the
  weekly pool the Grok usage page shows, not a Monday–Sunday calendar week and
  not a single product's share of the pool. `productUsage` lists those
  shares (`usagePercent` per product). A product row is that product's slice
  of the same pool.
- Each successful check appends the weekly percent to `usage.json` (up to 400
  points in the current allowance window). The panel charts the change between
  15-minute samples over the last 6 hours (not the running weekly total, and
  not every check when refresh is faster than 15 minutes). The line is scaled
  to that span, so a fraction of a percent still shows as a slope. A new
  allowance window drops the old points. A flat line means each 15-minute
  sample in those 6 hours saw the same total.
- The countdown uses that response's period end. Under a day it drops the day
  count; under an hour it shows minutes so it does not sit on `0h`. The clock
  beside it is that same instant in local time. "40% of the week" is how far
  the current period has run, not a second allowance. "Updated 4m ago" is when
  the last successful check finished.
- Network: one HTTPS GET to `cli-chat-proxy.grok.com` per check, with the saved
  login as a bearer token. When that access token is expired, within two
  minutes of expiry, or rejected, the plugin POSTs the saved refresh token to
  `https://auth.x.ai/oauth2/token` and retries the check once. Nothing else is
  contacted.
- Filesystem: reads `~/.grok/auth.json`, or `$GROK_CONFIG_DIR/auth.json` when
  that file exists. When the access token is expired or near expiry, the
  plugin refreshes it with the saved refresh token and writes the new token
  back to that same file. It also writes `usage.json` in the plugin data
  directory (the percentage, product shares, reset time, and up to 400 points
  of this window's weekly total, never the token). Tokens are not
  logged.
- A failed check keeps the last percentage on the bar and says why in the
  panel. Run `grok login` again if the saved login is missing or the refresh
  token is rejected.
