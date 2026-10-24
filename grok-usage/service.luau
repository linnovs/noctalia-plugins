--!nonstrict
-- Fetches this week's Grok allowance and publishes it for the bar and panel.
--
-- Auth is the token `grok login` already saved in ~/.grok/auth.json (or
-- $GROK_CONFIG_DIR/auth.json). The token is sent only to
-- https://cli-chat-proxy.grok.com/v1/billing?format=credits and is never
-- written to the plugin cache or the log.

local Usage = require("./lib/usage.luau")

local BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
local cachePath = nil
local inFlight = false
local pending = false

local function emptyUsage()
  return {
    status = "loading",
    percent = nil,
    resetsAt = nil,
    weekly = true,
    fetchedAt = nil,
    fetching = false,
  }
end

local function current()
  local value = noctalia.state.get("grok.usage")
  if type(value) == "table" then
    return value
  end
  return emptyUsage()
end

local function publish(nextUsage)
  noctalia.state.set("grok.usage", nextUsage)
end

local function withFetchFlag(fetching)
  local previous = current()
  publish({
    status = previous.status,
    percent = previous.percent,
    resetsAt = previous.resetsAt,
    weekly = previous.weekly,
    fetchedAt = previous.fetchedAt,
    fetching = fetching,
  })
end

local function fail(status)
  local previous = current()
  inFlight = false
  publish({
    status = status,
    percent = previous.percent,
    resetsAt = previous.resetsAt,
    weekly = previous.weekly,
    fetchedAt = previous.fetchedAt,
    fetching = false,
  })
  if pending then
    pending = false
    fetch()
  end
end

local function authPath()
  local override = noctalia.getenv("GROK_CONFIG_DIR")
  if type(override) == "string" and override ~= "" then
    local candidate = override .. "/auth.json"
    if noctalia.readFile(candidate) ~= nil then
      return candidate
    end
  end
  return noctalia.expandPath("~/.grok/auth.json")
end

local function persist(snapshot)
  if cachePath == nil then
    return
  end
  local encoded = noctalia.json.encode({
    percent = snapshot.percent,
    resetsAt = snapshot.resetsAt,
    weekly = snapshot.weekly,
    fetchedAt = snapshot.fetchedAt,
  })
  if encoded == nil then
    return
  end
  noctalia.writeFile(cachePath, encoded)
end

local function loadCache()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" or dir == "" then
    return
  end
  cachePath = dir .. "/usage.json"
  local raw = noctalia.readFile(cachePath)
  if type(raw) ~= "string" or raw == "" then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" or type(decoded.percent) ~= "number" then
    return
  end
  publish({
    status = "ok",
    percent = decoded.percent,
    resetsAt = decoded.resetsAt,
    weekly = decoded.weekly ~= false,
    fetchedAt = decoded.fetchedAt,
    fetching = false,
  })
end

function fetch()
  if inFlight then
    pending = true
    return
  end
  inFlight = true
  pending = false
  withFetchFlag(true)

  local raw = noctalia.readFile(authPath())
  if type(raw) ~= "string" or raw == "" then
    fail("missing_auth")
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    fail("error")
    return
  end
  local token, reason = Usage.parseAuth(decoded, os.time())
  if token == nil then
    fail(reason == "expired" and "expired" or "missing_auth")
    return
  end

  local started = noctalia.http({
    url = BILLING_URL,
    method = "GET",
    headers = {
      "Authorization: Bearer " .. token,
      "Accept: application/json",
      "x-xai-token-auth: xai-grok-cli",
    },
  }, function(res)
    inFlight = false
    if type(res) ~= "table" then
      fail("error")
      return
    end
    if res.status == 401 or res.status == 403 then
      fail("unauthorized")
      return
    end
    if res.ok ~= true or res.status ~= 200 then
      noctalia.log("Grok usage request failed: HTTP " .. tostring(res.status))
      fail("error")
      return
    end

    local body = noctalia.json.decode(res.body)
    local parsed, parseReason = Usage.parseBilling(body)
    if parsed == nil then
      noctalia.log("Grok usage response was not a weekly allowance: " .. tostring(parseReason))
      fail("error")
      return
    end

    local snapshot = {
      status = "ok",
      percent = parsed.percent,
      resetsAt = parsed.resetsAt,
      weekly = parsed.weekly,
      fetchedAt = os.time(),
      fetching = false,
    }
    publish(snapshot)
    persist(snapshot)
    if pending then
      pending = false
      fetch()
    end
  end)

  if started == false then
    fail("error")
  end
end

function update()
  local minutes = tonumber(noctalia.getConfig("refresh_minutes")) or 15
  if minutes < 1 then
    minutes = 1
  elseif minutes > 1440 then
    minutes = 1440
  end
  noctalia.setUpdateInterval(minutes * 60 * 1000)
  fetch()
end

function onIpc(event)
  if event == "refresh" then
    fetch()
  end
end

noctalia.state.watch("grok.refresh", function(value)
  if type(value) == "number" then
    fetch()
  end
end)

loadCache()
fetch()
