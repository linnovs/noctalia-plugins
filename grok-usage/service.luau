--!nonstrict
-- Fetches this week's Grok allowance and publishes it for the bar and panel.
--
-- Auth is the token `grok login` already saved in ~/.grok/auth.json (or
-- $GROK_CONFIG_DIR/auth.json). An expired access token is refreshed with the
-- stored refresh token at the xAI OIDC token endpoint, and the new token is
-- written back to that same file. Tokens are sent only to that endpoint and
-- https://cli-chat-proxy.grok.com/v1/billing?format=credits, and are never
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
    windowStart = nil,
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
    windowStart = previous.windowStart,
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
    windowStart = previous.windowStart,
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
    windowStart = snapshot.windowStart,
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
    windowStart = decoded.windowStart,
    weekly = decoded.weekly ~= false,
    fetchedAt = decoded.fetchedAt,
    fetching = false,
  })
end

local function loadAuth()
  local path = authPath()
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then
    return nil, nil, "missing_auth"
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return nil, nil, "error"
  end
  return path, decoded
end

local function saveAuth(path, decoded)
  local encoded = noctalia.json.encode(decoded)
  if type(encoded) ~= "string" then
    return false
  end
  return noctalia.writeFile(path, encoded) ~= false
end

local function requestBilling(token, allowRefresh, authFile, decoded)
  local started = noctalia.http({
    url = BILLING_URL,
    method = "GET",
    headers = {
      "Authorization: Bearer " .. token,
      "Accept: application/json",
      "x-xai-token-auth: xai-grok-cli",
    },
  }, function(res)
    if type(res) ~= "table" then
      fail("error")
      return
    end
    if (res.status == 401 or res.status == 403) and allowRefresh then
      refreshAuth(authFile, decoded, false)
      return
    end
    inFlight = false
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
      windowStart = parsed.windowStart,
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

function refreshAuth(authFile, decoded, fromExpiry)
  local session = Usage.authSession(decoded, os.time())
  local body = session and Usage.refreshBody(session)
  if body == nil then
    if fromExpiry and session and session.token ~= nil and session.expired ~= true then
      requestBilling(session.token, false, authFile, decoded)
      return
    end
    fail(session and session.expired and "expired" or "missing_auth")
    return
  end

  local started = noctalia.http({
    url = Usage.tokenUrl(session.issuer),
    method = "POST",
    headers = {
      "Content-Type: application/x-www-form-urlencoded",
      "Accept: application/json",
    },
    body = body,
  }, function(res)
    if type(res) ~= "table" or res.ok ~= true or res.status ~= 200 then
      noctalia.log("Grok login refresh failed: HTTP " .. tostring(res and res.status))
      if session.token ~= nil and session.expired ~= true then
        requestBilling(session.token, false, authFile, decoded)
        return
      end
      fail("expired")
      return
    end
    local payload = noctalia.json.decode(res.body)
    local token = Usage.applyRefresh(decoded, payload, os.time())
    if token == nil then
      fail("expired")
      return
    end
    saveAuth(authFile, decoded)
    requestBilling(token, false, authFile, decoded)
  end)

  if started == false then
    fail("error")
  end
end

function fetch()
  if inFlight then
    pending = true
    return
  end
  inFlight = true
  pending = false
  withFetchFlag(true)

  local authFile, decoded, reason = loadAuth()
  if decoded == nil then
    fail(reason or "missing_auth")
    return
  end
  local session = Usage.authSession(decoded, os.time())
  if session == nil then
    fail("missing_auth")
    return
  end
  if session.expired == true or session.token == nil then
    refreshAuth(authFile, decoded, true)
    return
  end
  requestBilling(session.token, true, authFile, decoded)
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
