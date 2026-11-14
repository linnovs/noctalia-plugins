--!nonstrict
-- Pure parsing/formatting for Codex usage windows. No network or noctalia calls.

local Usage = {}

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
  local used = clampUsed(tonumber(field(raw, "usedPercent", "used_percent")))
  local resetsAt = tonumber(field(raw, "resetAt", "reset_at"))
  return {
    kind = kind,
    used = used,
    resetsAt = resetsAt,
    windowSeconds = windowSeconds,
  }
end

local function parseCredits(decoded)
  local raw = field(decoded, "credits", "credits")
  if type(raw) ~= "table" then
    return nil
  end
  local hasCredits = field(raw, "hasCredits", "has_credits")
  local unlimited = raw.unlimited
  local balance = tonumber(field(raw, "balance", "balance"))
  if hasCredits == nil and unlimited == nil and balance == nil then
    return nil
  end
  return {
    hasCredits = hasCredits == true,
    unlimited = unlimited == true,
    balance = balance,
  }
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

  local allowed = field(decoded, "allowed", "allowed")
  if allowed ~= nil then
    allowed = allowed == true
  end
  local limitReached = field(decoded, "limitReached", "limit_reached")
  if limitReached == nil then
    limitReached = field(decoded, "rateLimitReached", "rate_limit_reached")
  end
  if limitReached ~= nil then
    limitReached = limitReached == true
  end

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
  if type(used) ~= "number" then
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

return Usage