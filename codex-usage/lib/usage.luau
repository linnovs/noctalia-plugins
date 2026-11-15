--!nonstrict
-- Pure parsing/formatting for Codex usage windows. No network or noctalia calls.

local Usage = {}

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local THREE_HOURS = 3 * 3600
local SIX_HOURS = 6 * 3600
local SIX_DAYS = 6 * 86400

local function field(source, camel, snake)
  if type(source) ~= "table" then
    return nil
  end
  if source[camel] ~= nil then
    return source[camel]
  end
  return source[snake]
end

local function clampUsed(used)
  if type(used) ~= "number" then
    return 0
  end
  if used < 0 then
    return 0
  end
  if used > 100 then
    return 100
  end
  return used
end

function Usage.classifyWindowSeconds(seconds)
  if type(seconds) ~= "number" then
    return nil
  end
  if seconds >= THREE_HOURS and seconds <= SIX_HOURS then
    return "5h"
  end
  if seconds >= SIX_DAYS then
    return "weekly"
  end
  return nil
end

local function parseRateWindow(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local windowSeconds = tonumber(field(raw, "limitWindowSeconds", "limit_window_seconds"))
  local kind = Usage.classifyWindowSeconds(windowSeconds)
  if kind == nil then
    return nil
  end
  local rawUsed = tonumber(field(raw, "usedPercent", "used_percent"))
  if not finite(rawUsed) then return nil end
  local used = clampUsed(rawUsed)
  local resetsAt = tonumber(field(raw, "resetAt", "reset_at"))
  return {
    kind = kind,
    used = used,
    resetsAt = resetsAt,
    windowSeconds = windowSeconds,
  }
end

local function parseBalance(rawBalance)
  if type(rawBalance) == "number" and finite(rawBalance) then
    return rawBalance
  end
  if type(rawBalance) ~= "string" then
    return nil
  end
  local trimmed = string.match(rawBalance, "^%s*(.-)%s*$")
  if trimmed == nil or trimmed == "" then
    return nil
  end
  -- Keep the display string (e.g. "$4.20"); API often sends currency text, not a bare number.
  return trimmed
end

local function parseCredits(decoded)
  local raw = field(decoded, "credits", "credits")
  if type(raw) ~= "table" then
    return nil
  end
  local hasCredits = field(raw, "hasCredits", "has_credits")
  local unlimited = raw.unlimited
  local balance = parseBalance(field(raw, "balance", "balance"))
  if hasCredits == nil and unlimited == nil and balance == nil then
    return nil
  end
  return {
    hasCredits = hasCredits == true,
    unlimited = unlimited == true,
    balance = balance,
  }
end

local function parseBoolFlag(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then
      return value == true
    end
  end
  return nil
end

function Usage.parseUsagePayload(decoded)
  if type(decoded) ~= "table" then
    return nil, "invalid"
  end
  local rateLimit = field(decoded, "rateLimit", "rate_limit")
  if type(rateLimit) ~= "table" then
    return nil, "invalid"
  end

  local fiveHour = nil
  local weekly = nil

  local function consider(raw)
    local window = parseRateWindow(raw)
    if window == nil then
      return
    end
    if window.kind == "5h" then
      fiveHour = window
    elseif window.kind == "weekly" then
      weekly = window
    end
  end

  consider(field(rateLimit, "primaryWindow", "primary_window"))
  consider(field(rateLimit, "secondaryWindow", "secondary_window"))

  if fiveHour == nil and weekly == nil then
    return nil, "invalid"
  end

  local resetsRaw = field(decoded, "rateLimitResetCredits", "rate_limit_reset_credits")
  local resetsAvailable = nil
  if type(resetsRaw) == "table" then
    resetsAvailable = tonumber(field(resetsRaw, "availableCount", "available_count"))
  end

  -- Live /wham/usage nests these under rate_limit; keep top-level as fallback.
  local allowed = parseBoolFlag(
    field(rateLimit, "allowed", "allowed"),
    field(decoded, "allowed", "allowed")
  )
  local limitReached = parseBoolFlag(
    field(rateLimit, "limitReached", "limit_reached"),
    field(rateLimit, "rateLimitReached", "rate_limit_reached"),
    field(decoded, "limitReached", "limit_reached"),
    field(decoded, "rateLimitReached", "rate_limit_reached")
  )

  local planType = field(decoded, "planType", "plan_type")
  if type(planType) ~= "string" then
    planType = nil
  end

  return {
    fiveHour = fiveHour,
    weekly = weekly,
    credits = parseCredits(decoded),
    resetsAvailable = resetsAvailable,
    allowed = allowed,
    limitReached = limitReached,
    planType = planType,
  }
end

function Usage.percentLeft(used)
  if not finite(used) then
    return nil
  end
  local left = 100 - used
  if left < 0 then
    return 0
  end
  if left > 100 then
    return 100
  end
  return left
end

function Usage.formatPercent(percent)
  if not finite(percent) then
    return "—"
  end
  local rounded = math.floor(percent + 0.5)
  if rounded < 0 then
    rounded = 0
  elseif rounded > 100 then
    rounded = 100
  end
  return tostring(rounded) .. "%"
end

function Usage.formatBarRemaining(now, resetsAt)
  if type(now) ~= "number" or type(resetsAt) ~= "number" then
    return nil
  end
  local seconds = math.floor(resetsAt - now)
  if seconds < 0 then
    seconds = 0
  end
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if hours > 0 then
    return string.format("%dh %dm", hours, minutes)
  end
  return string.format("%dm", minutes)
end

function Usage.formatRemaining(now, resetsAt)
  if type(now) ~= "number" or type(resetsAt) ~= "number" then
    return nil
  end
  local seconds = math.floor(resetsAt - now)
  if seconds < 0 then
    seconds = 0
  end
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  end
  if hours > 0 then
    return string.format("%dh", hours)
  end
  return string.format("%dm", minutes)
end

function Usage.selectBarWindow(windows, mode)
  if type(windows) ~= "table" then
    return nil
  end
  if mode == "5h" then
    return windows.fiveHour
  end
  if mode == "weekly" then
    return windows.weekly
  end
  if windows.fiveHour ~= nil then
    return windows.fiveHour
  end
  return windows.weekly
end

function Usage.formatBarText(window, now)
  if type(window) ~= "table" or type(window.used) ~= "number" then
    return Usage.formatPercent(nil)
  end
  local left = Usage.percentLeft(window.used)
  local text = Usage.formatPercent(left)
  if window.kind == "5h" and type(window.resetsAt) == "number" and type(now) == "number" then
    local countdown = Usage.formatBarRemaining(now, window.resetsAt)
    if countdown ~= nil then
      text = text .. "  " .. countdown
    end
  end
  return text
end

-- Auth tokens are opaque except for the unsigned JWT expiry hint. This hint only
-- schedules refresh; the server validates authentication on every request.
local function nonempty(value)
  if type(value) ~= "string" or string.match(value, "^%s*$") then
    return nil
  end
  return value
end

local function jwtExpiry(token)
  if type(token) ~= "string" then return nil end
  local payload = string.match(token, "^[^.]+%.([^.]+)%.[^.]+$")
  if payload == nil then return nil end
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local acc, bits = 0, 0
  local chars = {}
  for i = 1, #payload do
    local char = string.sub(payload, i, i)
    if char == "=" then break end
    local index = string.find(alphabet, char, 1, true)
    if index == nil then return nil end
    acc = acc * 64 + index - 1
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      table.insert(chars, string.char(math.floor(acc / 2^bits)))
      acc = acc % 2^bits
    end
  end
  return tonumber(string.match(table.concat(chars), '"exp"%s*:%s*(%d+)'))
end

function Usage.parseAuth(decoded, now)
  local tokens = type(decoded) == "table" and decoded.tokens
  if type(tokens) ~= "table" then return nil, "missing_auth" end
  local token = nonempty(tokens.access_token)
  local refresh = nonempty(tokens.refresh_token)
  if token == nil and refresh == nil then return nil, "missing_auth" end
  local expiresAt = jwtExpiry(token)
  return {
    token = token,
    refreshToken = refresh,
    accountId = nonempty(tokens.account_id),
    expiresAt = expiresAt,
    expired = token == nil or (expiresAt ~= nil and now + 120 >= expiresAt),
  }
end

function Usage.refreshBody(session)
  if type(session) ~= "table" or nonempty(session.refreshToken) == nil then return nil end
  return {
    grant_type = "refresh_token",
    refresh_token = session.refreshToken,
    client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
  }
end

function Usage.applyRefresh(decoded, body, now)
  if type(decoded) ~= "table" or type(decoded.tokens) ~= "table"
    or type(body) ~= "table" or nonempty(body.access_token) == nil then return nil end
  decoded.tokens.access_token = body.access_token
  if nonempty(body.refresh_token) then decoded.tokens.refresh_token = body.refresh_token end
  if nonempty(body.id_token) then decoded.tokens.id_token = body.id_token end
  decoded.last_refresh = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
  return body.access_token
end

-- Gregorian date ordinal, independent of DST and the length of a local day.
local function ordinal(year, month, day)
  if month <= 2 then year = year - 1 end
  local era = math.floor(year / 400)
  local yoe = year - era * 400
  local mp = month + (month > 2 and -3 or 9)
  return era * 146097 + yoe * 365 + math.floor(yoe / 4)
    - math.floor(yoe / 100) + math.floor((153 * mp + 2) / 5) + day - 1
end

function Usage.calendarDaysLeft(now, resetsAt)
  if type(now) ~= "number" or type(resetsAt) ~= "number" then return nil end
  local a, b = os.date("*t", now), os.date("*t", resetsAt)
  return math.max(1, ordinal(b.year, b.month, b.day) - ordinal(a.year, a.month, a.day))
end

function Usage.todayBudget(leftover, daysLeft)
  if type(leftover) ~= "number" or type(daysLeft) ~= "number" then return nil end
  return math.max(0, leftover) / math.max(1, daysLeft)
end

function Usage.usedToday(weeklyUsed, baselineUsed)
  if type(weeklyUsed) ~= "number" or type(baselineUsed) ~= "number" then return nil end
  return math.max(0, weeklyUsed - baselineUsed)
end

function Usage.shouldWarnFixed(weeklyUsed, threshold)
  return type(weeklyUsed) == "number" and type(threshold) == "number" and weeklyUsed >= threshold
end

function Usage.shouldWarnToday(usedToday, budget)
  return type(usedToday) == "number" and type(budget) == "number" and usedToday >= budget
end

function Usage.nextBaseline(prev, weeklyUsed, weeklyResetsAt, localDayKey, _now)
  local baseline = weeklyUsed
  if type(prev) == "table" and type(prev.baselineUsed) == "number" then
    if prev.windowKey ~= weeklyResetsAt or weeklyUsed < prev.baselineUsed then
      baseline = 0
    elseif prev.dayKey == localDayKey then
      baseline = prev.baselineUsed
    end
  end
  return {baselineUsed = baseline, dayKey = localDayKey, windowKey = weeklyResetsAt}
end


local function dateOrdinal(value)
  if type(value) ~= "string" then return nil end
  local y, m, d = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if y == nil or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
  local result = ordinal(y, m, d)
  -- Reject impossible dates instead of letting one bad bucket cover another week.
  local nextMonth, nextYear = m + 1, y
  if nextMonth == 13 then nextMonth, nextYear = 1, y + 1 end
  if result >= ordinal(nextYear, nextMonth, 1) then return nil end
  return result
end

function Usage.parseProfileStats(decoded)
  local raw = type(decoded) == "table" and decoded.stats
  if type(raw) ~= "table" then return nil, "invalid" end
  local metadata = type(decoded) == "table" and decoded.metadata
  if type(metadata) == "table" and nonempty(metadata.stats_error) then return nil, "error" end
  local daily, weekly = {}, {}
  local function buckets(source, isWeekly)
    if type(source) ~= "table" then return end
    for _, row in ipairs(source) do
      if type(row) == "table" then
        local date = isWeekly and (row.start_date or row.startDate) or (row.date or row.start_date or row.startDate)
        local tokens = tonumber(row.total_tokens or row.totalTokens or row.tokens)
        if dateOrdinal(date) and tokens and tokens == tokens and tokens >= 0 and tokens < math.huge then
          if isWeekly then
            table.insert(weekly, {start_date=date, tokens=tokens})
          else
            daily[date] = tokens
          end
        end
      end
    end
  end
  buckets(field(raw, "dailyUsageBuckets", "daily_usage_buckets"), false)
  buckets(field(raw, "weeklyUsageBuckets", "weekly_usage_buckets"), true)
  table.sort(weekly, function(a,b) return a.start_date < b.start_date end)
  return {daily=daily, weekly=weekly}
end

function Usage.calendarTokenRows(stats, localTodayYmd)
  if type(stats) ~= "table" then return {} end
  local today = dateOrdinal(localTodayYmd)
  if today == nil then return {} end
  local daily = type(stats.daily) == "table" and stats.daily or {}
  local weekly = type(stats.weekly) == "table" and stats.weekly or {}
  local todayTokens = daily[localTodayYmd]
  if not finite(todayTokens) or todayTokens < 0 then todayTokens = nil end
  local rows = {todayTokens = todayTokens}
  if rows.todayTokens == nil then
    for date, tokens in pairs(daily) do
      if dateOrdinal(date) and finite(tokens) and tokens >= 0 and date < localTodayYmd and (rows.todayAsOf == nil or date > rows.todayAsOf) then
        rows.todayAsOf = date
      end
    end
  end
  -- Select actual calendar coverage, not simply the two newest buckets.
  for _, bucket in ipairs(weekly) do
    local start = type(bucket) == "table" and dateOrdinal(bucket.start_date)
    local tokens = type(bucket) == "table" and bucket.tokens
    if not finite(tokens) or tokens < 0 then continue end
    if start and today >= start and today < start + 7 then
      rows.thisWeekTokens = bucket.tokens
    elseif start and today >= start + 7 and today < start + 14 then
      rows.lastWeekTokens = bucket.tokens
    end
  end
  return rows
end

function Usage.formatTokenCount(n)
  if type(n) ~= "number" then return "—" end
  local function compact(value, suffix)
    return string.gsub(string.format("%.1f", value), "%.0$", "") .. suffix
  end
  if n >= 1000000 then return compact(n / 1000000, "M") end
  if n >= 1000 then return compact(n / 1000, "K") end
  return tostring(math.floor(n))
end

return Usage
