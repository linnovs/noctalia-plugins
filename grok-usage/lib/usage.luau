--!nonstrict
-- Pure parsing for Grok's weekly allowance. No network and no noctalia calls,
-- so the same file can be checked outside the shell.

local Usage = {}

local function trim(value)
  return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function daysFromCivil(year, month, day)
  local y = year
  if month <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  if y < 0 then
    era = math.floor((y - 399) / 400)
  end
  local yoe = y - era * 400
  local shifted = month
  if month > 2 then
    shifted = month - 3
  else
    shifted = month + 9
  end
  local doy = math.floor((153 * shifted + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- UTC instant for an ISO-8601 timestamp. Fractional seconds are ignored.
-- Returns nil when the text is not a timestamp this plugin can trust.
function Usage.parseIso8601(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second, rest = string.match(
    value,
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
  )
  if year == nil then
    return nil
  end
  local unix = daysFromCivil(tonumber(year), tonumber(month), tonumber(day)) * 86400
    + tonumber(hour) * 3600
    + tonumber(minute) * 60
    + tonumber(second)
  rest = string.gsub(rest or "", "^%.%d+", "")
  if rest == "" or rest == "Z" or rest == "z" then
    return unix
  end
  local sign, offsetHour, offsetMinute = string.match(rest, "^([%+%-])(%d%d):?(%d%d)$")
  if sign == nil then
    return nil
  end
  local offset = tonumber(offsetHour) * 3600 + tonumber(offsetMinute) * 60
  if sign == "+" then
    return unix - offset
  end
  return unix + offset
end

local function field(source, camel, snake)
  if type(source) ~= "table" then
    return nil
  end
  if source[camel] ~= nil then
    return source[camel]
  end
  return source[snake]
end

local function tokenFrom(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local key = entry.key or entry.access_token or entry.token
  if type(key) ~= "string" then
    return nil
  end
  key = trim(key)
  if key == "" then
    return nil
  end
  return key
end

local function expiryOf(entry)
  local raw = field(entry, "expiresAt", "expires_at")
  if type(raw) ~= "string" then
    return nil
  end
  return Usage.parseIso8601(raw)
end

-- Picks a non-empty, unexpired token from ~/.grok/auth.json.
-- `now` is unix seconds. Returns token, or nil plus "expired" / "missing".
function Usage.parseAuth(decoded, now)
  if type(decoded) ~= "table" then
    return nil, "missing"
  end
  local best = nil
  local bestExpiry = nil
  local sawExpired = false

  local function consider(entry)
    local key = tokenFrom(entry)
    if key == nil then
      return
    end
    local expiry = expiryOf(entry)
    if expiry ~= nil and type(now) == "number" and now >= expiry then
      sawExpired = true
      return
    end
    local rank = expiry or 0
    if best == nil or rank > (bestExpiry or 0) then
      best = key
      bestExpiry = expiry
    end
  end

  consider(decoded)
  for _, entry in pairs(decoded) do
    consider(entry)
  end

  if best ~= nil then
    return best
  end
  if sawExpired then
    return nil, "expired"
  end
  return nil, "missing"
end

-- Weekly allowance from GET /v1/billing?format=credits.
-- creditUsagePercent is the pool the usage page shows. A GrokBuild slice is a
-- share of that pool, so it is not used as the week total.
-- An omitted percent is 0 only when the response still has a weekly window.
function Usage.parseBilling(decoded)
  if type(decoded) ~= "table" or type(decoded.config) ~= "table" then
    return nil, "invalid"
  end
  local config = decoded.config

  local period = field(config, "currentPeriod", "current_period")
  local periodType = nil
  local resetsAt = nil
  local windowStart = nil
  if type(period) == "table" then
    periodType = period.type
    if type(period["end"]) == "string" then
      resetsAt = Usage.parseIso8601(period["end"])
    end
    if type(period.start) == "string" then
      windowStart = Usage.parseIso8601(period.start)
    end
  end
  if resetsAt == nil then
    local fallback = field(config, "billingPeriodEnd", "billing_period_end")
    if type(fallback) == "string" then
      resetsAt = Usage.parseIso8601(fallback)
    end
  end

  local percent = tonumber(field(config, "creditUsagePercent", "credit_usage_percent"))
  local weekly = periodType == nil or periodType == "USAGE_PERIOD_TYPE_WEEKLY"
  if percent == nil and weekly and windowStart ~= nil and resetsAt ~= nil and resetsAt > windowStart then
    percent = 0
  end
  if percent == nil then
    return nil, "invalid"
  end
  if percent < 0 then
    percent = 0
  elseif percent > 100 then
    percent = 100
  end

  return {
    percent = percent,
    resetsAt = resetsAt,
    weekly = weekly,
  }
end

function Usage.formatPercent(percent)
  if type(percent) ~= "number" then
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

-- "3d 14h" once a day is in, otherwise hours, otherwise minutes.
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

function Usage.progress(percent)
  if type(percent) ~= "number" then
    return 0
  end
  local value = percent / 100
  if value < 0 then
    return 0
  end
  if value > 1 then
    return 1
  end
  return value
end

function Usage.statusKey(status)
  if status == "missing_auth" then
    return "status.missing_auth"
  elseif status == "expired" then
    return "status.expired"
  elseif status == "unauthorized" then
    return "status.unauthorized"
  elseif status == "error" then
    return "status.error"
  elseif status == "loading" then
    return "status.loading"
  end
  return nil
end

return Usage
