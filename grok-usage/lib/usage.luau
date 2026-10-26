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

local TOKEN_URL = "https://auth.x.ai/oauth2/token"
local REFRESH_SKEW_SECONDS = 120

local function authEntry(decoded)
  if type(decoded) ~= "table" then
    return nil
  end
  if tokenFrom(decoded) ~= nil or type(decoded.refresh_token) == "string" then
    return decoded
  end
  for _, entry in pairs(decoded) do
    if type(entry) == "table" and (tokenFrom(entry) ~= nil or type(entry.refresh_token) == "string") then
      return entry
    end
  end
  return nil
end

-- Access token plus the refresh material `grok login` stores beside it.
-- `expired` is true when the access token is missing or inside the refresh window.
function Usage.authSession(decoded, now)
  local entry = authEntry(decoded)
  if entry == nil then
    return nil, "missing"
  end
  local refreshToken = entry.refresh_token
  if type(refreshToken) ~= "string" or trim(refreshToken) == "" then
    refreshToken = nil
  else
    refreshToken = trim(refreshToken)
  end
  local clientId = entry.oidc_client_id
  if type(clientId) ~= "string" or trim(clientId) == "" then
    clientId = nil
  else
    clientId = trim(clientId)
  end
  local issuer = entry.oidc_issuer
  if type(issuer) ~= "string" or trim(issuer) == "" then
    issuer = "https://auth.x.ai"
  else
    issuer = trim(issuer)
  end
  local expiry = expiryOf(entry)
  local token = tokenFrom(entry)
  local expired = token == nil
  if type(now) == "number" and expiry ~= nil and now + REFRESH_SKEW_SECONDS >= expiry then
    expired = true
  end
  return {
    token = token,
    refreshToken = refreshToken,
    clientId = clientId,
    issuer = issuer,
    expiresAt = expiry,
    expired = expired,
  }
end

function Usage.tokenUrl(issuer)
  if type(issuer) ~= "string" or issuer == "" then
    return TOKEN_URL
  end
  return (string.gsub(issuer, "/+$", "")) .. "/oauth2/token"
end

function Usage.refreshBody(session)
  if type(session) ~= "table" or session.refreshToken == nil or session.clientId == nil then
    return nil
  end
  local function enc(value)
    return (string.gsub(value, "[^%w%-_%.~]", function(char)
      return string.format("%%%02X", string.byte(char))
    end))
  end
  return "grant_type=refresh_token&refresh_token="
    .. enc(session.refreshToken)
    .. "&client_id="
    .. enc(session.clientId)
end

function Usage.formatIso8601(unix)
  if type(unix) ~= "number" then
    return nil
  end
  local parts = os.date("!*t", unix)
  if type(parts) ~= "table" then
    return nil
  end
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02dZ",
    parts.year,
    parts.month,
    parts.day,
    parts.hour,
    parts.min,
    parts.sec
  )
end

-- Writes a successful token response back onto the same auth.json object.
function Usage.applyRefresh(decoded, body, now)
  if type(body) ~= "table" or type(body.access_token) ~= "string" or trim(body.access_token) == "" then
    return nil
  end
  local entry = authEntry(decoded)
  if entry == nil then
    return nil
  end
  entry.key = trim(body.access_token)
  if type(body.refresh_token) == "string" and trim(body.refresh_token) ~= "" then
    entry.refresh_token = trim(body.refresh_token)
  end
  local lifetime = tonumber(body.expires_in)
  if type(now) == "number" and lifetime ~= nil and lifetime > 0 then
    local stamp = Usage.formatIso8601(now + lifetime)
    if stamp ~= nil then
      entry.expires_at = stamp
    end
  end
  return entry.key
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
    windowStart = windowStart,
    weekly = weekly,
    products = Usage.parseProducts(config),
  }
end

local PRODUCT_LABELS = {
  GrokBuild = "Grok Build",
  GrokChat = "Grok Chat",
  GrokImagine = "Grok Imagine",
  GrokTasks = "Grok Tasks",
  Api = "xAI API",
}

function Usage.productLabel(raw)
  if type(raw) ~= "string" then
    return nil
  end
  raw = trim(raw)
  if raw == "" or #raw > 64 then
    return nil
  end
  if PRODUCT_LABELS[raw] ~= nil then
    return PRODUCT_LABELS[raw]
  end
  return raw
end

-- Slices of the same weekly pool. Each percent is that product's share of the
-- pool, not a second allowance. Unknown or empty names are skipped. At most
-- eight rows, in the order the billing response listed them.
function Usage.parseProducts(config)
  local raw = field(config, "productUsage", "product_usage")
  if type(raw) ~= "table" then
    return {}
  end
  local products = {}
  local count = 0
  for _, item in ipairs(raw) do
    if count >= 8 then
      break
    end
    if type(item) == "table" then
      local label = Usage.productLabel(item.product)
      local percent = tonumber(field(item, "usagePercent", "usage_percent"))
      if label ~= nil then
        if percent == nil then
          percent = 0
        elseif percent < 0 then
          percent = 0
        elseif percent > 100 then
          percent = 100
        end
        count = count + 1
        products[count] = { label = label, percent = percent }
      end
    end
  end
  return products
end

local MAX_HISTORY = 24

-- Appends one reading. A new allowance window drops the previous week's points.
-- Identical consecutive percents still record time so the trend can say "flat".
function Usage.appendHistory(history, windowStart, fetchedAt, percent)
  local nextHistory = {}
  if type(history) == "table" then
    for _, point in ipairs(history) do
      if type(point) == "table"
        and type(point.at) == "number"
        and type(point.percent) == "number"
        and point.windowStart == windowStart
      then
        table.insert(nextHistory, {
          at = point.at,
          percent = point.percent,
          windowStart = windowStart,
        })
      end
    end
  end
  if type(fetchedAt) == "number" and type(percent) == "number" then
    table.insert(nextHistory, {
      at = fetchedAt,
      percent = percent,
      windowStart = windowStart,
    })
  end
  while #nextHistory > MAX_HISTORY do
    table.remove(nextHistory, 1)
  end
  return nextHistory
end

-- Change in the weekly total since the previous reading in this window.
-- Positive means more of the allowance was spent.
function Usage.trendDelta(history)
  if type(history) ~= "table" or #history < 2 then
    return nil
  end
  local previous = history[#history - 1]
  local latest = history[#history]
  if type(previous) ~= "table" or type(latest) ~= "table" then
    return nil
  end
  if type(previous.percent) ~= "number" or type(latest.percent) ~= "number" then
    return nil
  end
  return latest.percent - previous.percent
end

function Usage.formatDelta(delta)
  if type(delta) ~= "number" then
    return nil
  end
  local rounded = math.floor(math.abs(delta) + 0.5)
  if rounded == 0 then
    return "0%"
  end
  local text = tostring(rounded) .. "%"
  if delta > 0 then
    return "+" .. text
  end
  return "-" .. text
end

function Usage.formatResetClock(resetsAt)
  if type(resetsAt) ~= "number" then
    return nil
  end
  local clock = os.date("%a %H:%M", resetsAt)
  if type(clock) ~= "string" or clock == "" then
    return nil
  end
  return clock
end

-- Share of the allowance window that has already passed, 0–100.
function Usage.weekElapsed(now, windowStart, resetsAt)
  if type(now) ~= "number" or type(windowStart) ~= "number" or type(resetsAt) ~= "number" then
    return nil
  end
  local span = resetsAt - windowStart
  if span <= 0 then
    return nil
  end
  local done = now - windowStart
  if done < 0 then
    done = 0
  elseif done > span then
    done = span
  end
  return done / span * 100
end

-- "now" under a minute, otherwise "4m" / "2h" / "3d".
function Usage.formatAgo(now, thenAt)
  if type(now) ~= "number" or type(thenAt) ~= "number" then
    return nil
  end
  local seconds = math.floor(now - thenAt)
  if seconds < 60 then
    return "now"
  end
  local days = math.floor(seconds / 86400)
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor(seconds / 60)
  if days > 0 then
    return tostring(days) .. "d"
  end
  if hours > 0 then
    return tostring(hours) .. "h"
  end
  return tostring(minutes) .. "m"
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
