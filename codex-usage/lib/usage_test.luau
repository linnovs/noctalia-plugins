--!nonstrict
local Usage = require("./usage")

local function assertEq(a, b, msg)
  if a ~= b then
    error((msg or "assertEq") .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2)
  end
end

-- Team-style: weekly in primary only
local team = Usage.parseUsagePayload({
  rate_limit = {
    primary_window = {
      used_percent = 22,
      limit_window_seconds = 604800,
      reset_at = 1790426679,
    },
    secondary_window = nil,
  },
})
assertEq(team.fiveHour, nil, "no 5h")
assertEq(team.weekly.used, 22, "weekly used")
assertEq(team.weekly.kind, "weekly", "kind")

-- Plus-style both windows (order must not matter if swapped)
local plus = Usage.parseUsagePayload({
  rate_limit = {
    primary_window = { used_percent = 42, limit_window_seconds = 18000, reset_at = 1000 },
    secondary_window = { used_percent = 71, limit_window_seconds = 604800, reset_at = 2000 },
  },
})
assertEq(plus.fiveHour.used, 42)
assertEq(plus.weekly.used, 71)

-- Regression: weekly in primary, 5h in secondary — classify by window seconds, not slot
local swapped = Usage.parseUsagePayload({
  rate_limit = {
    primary_window = { used_percent = 71, limit_window_seconds = 604800, reset_at = 2000 },
    secondary_window = { used_percent = 42, limit_window_seconds = 18000, reset_at = 1000 },
  },
})
assertEq(swapped.fiveHour.used, 42, "swapped fiveHour used")
assertEq(swapped.weekly.used, 71, "swapped weekly used")
assertEq(swapped.fiveHour.kind, "5h", "swapped fiveHour kind")
assertEq(swapped.weekly.kind, "weekly", "swapped weekly kind")

local w5 = plus.fiveHour
assertEq(Usage.percentLeft(42), 58)
assertEq(Usage.formatBarText(w5, 1000 - 3 * 3600 - 12 * 60), "42%  3h 12m")
assertEq(Usage.formatBarText(w5, 1000 - 3 * 3600 - 12 * 60, "used"), "42%  3h 12m")
assertEq(Usage.formatBarText(w5, 1000 - 3 * 3600 - 12 * 60, "left"), "58%  3h 12m")
local ww = plus.weekly
assertEq(Usage.formatBarText(ww, 0), "71%") -- no countdown on weekly bar
assertEq(Usage.formatBarText(ww, 0, "left"), "29%")

local auto = Usage.selectBarWindow(plus, "auto")
assertEq(auto.kind, "5h")
local onlyW = Usage.selectBarWindow(team, "auto")
assertEq(onlyW.kind, "weekly")

print("usage_test Task2 ok")

-- Reject API keys, preserve account identity, and refresh inside the expiry skew.
local missing, reason = Usage.parseAuth({ OPENAI_API_KEY = "test-key" }, 1000)
assertEq(missing, nil)
assertEq(reason, "missing_auth")
local auth = { tokens = { access_token = "header.eyJleHAiOjIwMDB9.signature", refresh_token = "r+/=", account_id = "account-1" }, extra = "preserved" }
local session = Usage.parseAuth(auth, 1000)
assertEq(session.accountId, "account-1")
assertEq(session.expired, false)
assertEq(Usage.parseAuth(auth, 1880).expired, true)

assertEq(Usage.applyRefresh(auth, {access_token = "fresh", expires_in = 3600}, 1000), "fresh")
assertEq(auth.tokens.refresh_token, "r+/=")
assertEq(auth.extra, "preserved")
assertEq(auth.last_refresh, "1970-01-01T00:16:40Z")
assertEq(Usage.applyRefresh(auth, {access_token = "", refresh_token = "bad"}, 1000), nil)
assertEq(auth.tokens.refresh_token, "r+/=")
assertEq(Usage.parseAuth({ tokens = { refresh_token = "recover" } }, 1000).expired, true)
assertEq(Usage.parseAuth({ tokens = { access_token = "opaque" } }, 1000).expired, false)

-- Local calendar arithmetic: later today is one day, not rounded seconds.
local noon = os.time({year=2026, month=11, day=15, hour=12})
assertEq(Usage.calendarDaysLeft(noon, noon + 3600), 1)
assertEq(Usage.calendarDaysLeft(noon, noon + 4 * 86400 - 3600), 4)
assertEq(Usage.calendarDaysLeft(noon, noon - 86400), 1)
-- Luau os.time(table) constructs UTC. These instants straddle the US fall-back
-- while remaining one calendar date apart in HK, UTC, and New York.
assertEq(Usage.calendarDaysLeft(os.time({year=2024,month=11,day=2,hour=12}),
  os.time({year=2024,month=11,day=3,hour=13})), 1)
assertEq(Usage.todayBudget(60, 4), 15)
assertEq(Usage.usedToday(58, 40), 18)
assertEq(Usage.usedToday(2, 40), 0)
assertEq(Usage.shouldWarnToday(18, 15), true)
assertEq(Usage.shouldWarnToday(15, 15), true)
assertEq(Usage.shouldWarnToday(14, 15), false)
assertEq(Usage.shouldWarnFixed(80, 80), true)
assertEq(Usage.shouldWarnFixed(79, 80), false)
assertEq(Usage.shouldWarnToday(nil, 15), false)
local baseline = Usage.nextBaseline(nil, 40, 9000, "2026-11-15", 1000)
assertEq(baseline.baselineUsed, 40)
assertEq(Usage.nextBaseline(baseline, 58, 9000, "2026-11-15", 1001).baselineUsed, 40)
assertEq(Usage.nextBaseline(baseline, 58, 9000, "2026-11-16", 1001).baselineUsed, 58)
assertEq(Usage.nextBaseline(baseline, 2, 10000, "2026-11-15", 1001).baselineUsed, 0)
assertEq(Usage.nextBaseline(baseline, 2, 9000, "2026-11-15", 1001).baselineUsed, 0)
print("usage_test Task3 ok")


-- Calendar buckets do not substitute yesterday's count for today.
local stats = Usage.parseProfileStats({stats={
 daily_usage_buckets={{date="2026-11-13",total_tokens=900000}},
 weekly_usage_buckets={{start_date="2026-11-09",total_tokens=12400000},{start_date="2026-11-02",total_tokens=5000000}},
}})
local rows = Usage.calendarTokenRows(stats, "2026-11-15")
assertEq(rows.todayTokens, nil)
assertEq(rows.todayAsOf, "2026-11-13")
assertEq(rows.thisWeekTokens, 12400000)
assertEq(rows.lastWeekTokens, 5000000)
local stale = Usage.calendarTokenRows(stats, "2026-11-23")
assertEq(stale.thisWeekTokens, nil)
assertEq(stale.lastWeekTokens, nil)
assertEq(Usage.calendarTokenRows(stats, "2026-11-13").todayTokens, 900000)
assertEq(Usage.parseProfileStats({}), nil)
assertEq(Usage.formatTokenCount(12400000), "12.4M")
assertEq(Usage.formatTokenCount(900000), "900K")
assertEq(Usage.formatTokenCount(123), "123")
assertEq(Usage.formatTokenCount(nil), "—")
print("usage_test Task4 ok")

-- Public Codex profile daily buckets use start_date and tokens.
local official = Usage.parseProfileStats({stats={daily_usage_buckets={{start_date="2026-11-15",tokens=42}}}})
assertEq(Usage.calendarTokenRows(official, "2026-11-15").todayTokens, 42)
-- Refresh matches the JSON encoding used by the current public Codex client.
local refresh = Usage.refreshBody(session)
assertEq(type(refresh), "table")
assertEq(refresh.grant_type, "refresh_token")
assertEq(refresh.refresh_token, "r+/=")
assertEq(refresh.client_id, "app_EMoamEEZ73f0CkXaXp7hrann")

-- Invalid allowance data must never turn into a fabricated 100% left reading.
assertEq(Usage.parseUsagePayload({rate_limit={primary_window={limit_window_seconds=18000}}}),nil)
assertEq(Usage.parseUsagePayload({rate_limit={primary_window={limit_window_seconds=18000,used_percent=0/0}}}),nil)
assertEq(Usage.parseUsagePayload({rate_limit={primary_window={limit_window_seconds=18000,used_percent=math.huge}}}),nil)
assertEq(Usage.percentLeft(0/0),nil)
assertEq(Usage.formatPercent(0/0),"—")
-- Malformed or incomplete cached statistics should be harmless.
assertEq(Usage.calendarTokenRows({},"2026-11-15").todayTokens,nil)
assertEq(Usage.calendarTokenRows({daily={bad=100},weekly={}},"2026-11-15").todayAsOf,nil)
assertEq(Usage.calendarTokenRows({daily={},weekly={true,4,{start_date="bad",tokens=100}}},"2026-11-15").thisWeekTokens,nil)
assertEq(Usage.parseProfileStats({stats={},metadata={stats_error="unavailable"}}),nil)

-- Credits balance may be a currency string; allowed/limit_reached live under rate_limit.
local liveShape = Usage.parseUsagePayload({
  rate_limit = {
    allowed = false,
    limit_reached = true,
    primary_window = { used_percent = 10, limit_window_seconds = 18000, reset_at = 1 },
  },
  credits = { has_credits = true, unlimited = false, balance = "$4.20" },
})
assertEq(liveShape.credits.balance, "$4.20", "string balance")
assertEq(liveShape.allowed, false, "nested allowed")
assertEq(liveShape.limitReached, true, "nested limit_reached")
local numericCredits = Usage.parseUsagePayload({
  rate_limit = {
    primary_window = { used_percent = 1, limit_window_seconds = 604800, reset_at = 1 },
  },
  credits = { has_credits = true, balance = 4.2 },
})
assertEq(numericCredits.credits.balance, 4.2, "numeric balance")

print("usage_test robustness ok")
