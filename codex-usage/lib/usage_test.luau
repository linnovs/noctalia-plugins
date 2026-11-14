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

local w5 = plus.fiveHour
assertEq(Usage.percentLeft(42), 58)
assertEq(Usage.formatBarText(w5, 1000 - 3 * 3600 - 12 * 60), "58%  3h 12m")
local ww = plus.weekly
assertEq(Usage.formatBarText(ww, 0), "29%") -- no countdown on weekly bar

local auto = Usage.selectBarWindow(plus, "auto")
assertEq(auto.kind, "5h")
local onlyW = Usage.selectBarWindow(team, "auto")
assertEq(onlyW.kind, "weekly")

print("usage_test Task2 ok")