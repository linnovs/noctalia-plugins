--!nonstrict
-- Host injection keeps HTTP/file effects testable without a running shell.
local ok, Usage = pcall(require, "./lib/usage.luau")
if not ok then
  Usage = require("./lib/usage")
end
local Service = {}
local TOKEN_URL = "https://auth.openai.com/oauth/token"
local BASE_URL = "https://chatgpt.com/backend-api/wham/"

function Service.start(host)
  local inFlight, pending = false, false
  local baseline, accountId, cachePath
  local fetch

  local function current()
    return host.state.get("codex.usage") or {status="loading", fetching=false, warn=false}
  end
  local function publish(value)
    host.state.set("codex.usage", value)
  end
  local function persist(snapshot)
    if cachePath == nil then return end
    -- Explicit allowlist: no auth objects or response bodies enter the cache.
    local encoded = host.json.encode({
      fiveHour=snapshot.fiveHour, weekly=snapshot.weekly,
      credits=snapshot.credits, resetsAvailable=snapshot.resetsAvailable,
      allowed=snapshot.allowed, limitReached=snapshot.limitReached,
      fetchedAt=snapshot.fetchedAt, tokens=snapshot.tokens,
      profileStats=snapshot.profileStats, tokensFetchedAt=snapshot.tokensFetchedAt,
      baseline=baseline, accountId=accountId,
    })
    if type(encoded) == "string" then host.writeFile(cachePath, encoded) end
  end
  local function warn(snapshot)
    snapshot.warn, snapshot.warnReason = false, nil
    snapshot.usedToday, snapshot.todayBudget = nil, nil
    local weekly = snapshot.weekly
    if type(weekly) ~= "table" then return end
    local now = os.time()
    baseline = Usage.nextBaseline(baseline, weekly.used, weekly.resetsAt, os.date("%Y-%m-%d", now), now)
    snapshot.usedToday = Usage.usedToday(weekly.used, baseline.baselineUsed)
    snapshot.todayBudget = Usage.todayBudget(Usage.percentLeft(weekly.used), Usage.calendarDaysLeft(now, weekly.resetsAt))
    if host.getConfig("weekly_warn_mode") == "fixed" then
      local threshold = math.clamp(tonumber(host.getConfig("weekly_warn_percent")) or 80, 1, 100)
      snapshot.warn = Usage.shouldWarnFixed(weekly.used, threshold)
      if snapshot.warn then snapshot.warnReason = "fixed" end
    else
      snapshot.warn = Usage.shouldWarnToday(snapshot.usedToday, snapshot.todayBudget)
      if snapshot.warn then snapshot.warnReason = "today" end
    end
  end
  local function finish(snapshot, save)
    snapshot.fetching = false
    publish(snapshot)
    if save then persist(snapshot) end
    inFlight = false
    if pending then pending = false fetch() end
  end
  local function fail(status)
    local snapshot = table.clone(current())
    snapshot.status = status
    finish(snapshot, false)
  end
  local function authPath()
    local override = host.getenv("CODEX_HOME")
    if type(override) == "string" and override ~= "" then return override .. "/auth.json" end
    return host.expandPath("~/.codex/auth.json")
  end
  local function readAuth(path)
    local raw = host.readFile(path)
    if type(raw) ~= "string" or raw == "" then return nil end
    return host.json.decode(raw)
  end
  local function loadCache()
    local dir = host.pluginDataDir()
    if type(dir) ~= "string" or dir == "" then return end
    cachePath = dir .. "/usage.json"
    local raw = host.readFile(cachePath)
    if type(raw) ~= "string" then return end
    local cached = host.json.decode(raw)
    if type(cached) ~= "table" then return end
    accountId = type(cached.accountId) == "string" and cached.accountId or nil
    baseline = type(cached.baseline) == "table" and cached.baseline or nil
    local function window(value, kind)
      if type(value) ~= "table" or type(value.used) ~= "number" then return nil end
      if value.used ~= value.used then return nil end
      return {kind=kind, used=math.clamp(value.used,0,100),
        resetsAt=tonumber(value.resetsAt), windowSeconds=tonumber(value.windowSeconds)}
    end
    local snapshot = {
      status="loading", fetching=false, warn=false,
      fiveHour=window(cached.fiveHour,"5h"), weekly=window(cached.weekly,"weekly"),
      credits=type(cached.credits)=="table" and cached.credits or nil,
      resetsAvailable=tonumber(cached.resetsAvailable),
      allowed=type(cached.allowed) == "boolean" and cached.allowed or nil,
      limitReached=type(cached.limitReached) == "boolean" and cached.limitReached or nil,
      fetchedAt=tonumber(cached.fetchedAt),
      tokens=type(cached.tokens)=="table" and cached.tokens or nil,
      profileStats=type(cached.profileStats)=="table" and cached.profileStats or nil,
      tokensFetchedAt=tonumber(cached.tokensFetchedAt),
    }
    publish(snapshot)
  end

  fetch = function()
    if inFlight then pending = true return end
    inFlight, pending = true, false
    local path = authPath()
    local decoded = readAuth(path)
    local session = Usage.parseAuth(decoded, os.time())
    if session == nil then fail("missing_auth") return end
    if accountId ~= session.accountId then
      baseline = nil
      publish({status="loading",fetching=false,warn=false})
    end
    accountId = session.accountId
    local loading = table.clone(current())
    loading.fetching = true
    publish(loading)
    local refreshed = false
    local snapshot = table.clone(current())
    local usageOK, profileOK, authError = false, false, nil

    local function refresh(done)
      if refreshed then done(false, "unauthorized") return end
      refreshed = true
      -- Re-read before refresh so a concurrently renewed Codex session is reused.
      local latest = readAuth(path)
      local latestSession = Usage.parseAuth(latest, os.time())
      if latestSession == nil or latestSession.accountId ~= accountId then
        done(false,"unauthorized") return
      end
      if latestSession.token ~= session.token and not latestSession.expired then
        session, decoded = latestSession, latest
        done(true) return
      end
      session, decoded = latestSession, latest
      local body = Usage.refreshBody(session)
      if body == nil then done(false, session.expired and "expired" or "unauthorized") return end
      local started = host.http({url=TOKEN_URL, method="POST",
        headers={"Content-Type: application/json","Accept: application/json"},
        body=host.json.encode(body),
      }, function(res)
        if type(res) ~= "table" or res.ok ~= true or res.status ~= 200 then
          local permanent = res and (res.status == 400 or res.status == 401 or res.status == 403)
          done(false, permanent and "expired" or "error") return
        end
        local payload = host.json.decode(res.body)
        -- Do not overwrite a login changed while the refresh request was in flight.
        local live = readAuth(path)
        local liveSession = Usage.parseAuth(live, os.time())
        if liveSession == nil or liveSession.accountId ~= accountId
          or liveSession.refreshToken ~= session.refreshToken or liveSession.token ~= session.token then
          done(false,"unauthorized") return
        end
        if Usage.applyRefresh(live, payload, os.time()) == nil then done(false,"expired") return end
        local encoded = host.json.encode(live)
        if type(encoded) ~= "string" or host.writeFile(path, encoded) == false then
          done(false,"error") return
        end
        decoded, session = live, Usage.parseAuth(live, os.time())
        done(true)
      end)
      if started == false then done(false,"error") end
    end

    local function request(endpoint, done)
      local function send()
        local headers={"Authorization: Bearer " .. session.token,"Accept: application/json"}
        if session.accountId then table.insert(headers,"ChatGPT-Account-Id: " .. session.accountId) end
        local started = host.http({url=BASE_URL..endpoint,method="GET",headers=headers},function(res)
          if type(res) == "table" and res.status == 401 and not refreshed then
            refresh(function(ok, reason)
              if ok then send() else done(nil,reason) end
            end)
            return
          end
          if type(res) ~= "table" or res.ok ~= true or res.status ~= 200 then
            local unauthorized = res and (res.status == 401 or res.status == 403)
            done(nil,unauthorized and "unauthorized" or "error") return
          end
          done(host.json.decode(res.body),nil)
        end)
        if started == false then done(nil,"error") end
      end
      send()
    end

    local function sync()
      request("usage",function(body,reason)
        local parsed = Usage.parseUsagePayload(body)
        if parsed then
          usageOK = true
          snapshot.fiveHour, snapshot.weekly = parsed.fiveHour, parsed.weekly
          snapshot.credits, snapshot.resetsAvailable = parsed.credits, parsed.resetsAvailable
          snapshot.allowed, snapshot.limitReached = parsed.allowed, parsed.limitReached
          snapshot.fetchedAt = os.time()
          warn(snapshot)
        elseif reason == "unauthorized" or reason == "expired" then
          authError = reason
        end
        request("profiles/me",function(profile,profileReason)
          local stats = Usage.parseProfileStats(profile)
          if stats then
            profileOK = true
            snapshot.profileStats = stats
            snapshot.tokensFetchedAt = os.time()
          elseif profileReason == "unauthorized" or profileReason == "expired" then
            authError = profileReason
          end
          -- Re-select cached buckets at local midnight even if the profile fails.
          if snapshot.profileStats then
            local rows = Usage.calendarTokenRows(snapshot.profileStats,os.date("%Y-%m-%d"))
            snapshot.tokens={today=rows.todayTokens,todayAsOf=rows.todayAsOf,
              thisWeek=rows.thisWeekTokens,lastWeek=rows.lastWeekTokens}
          end
          if usageOK and profileOK then snapshot.status="ok"
          elseif usageOK or profileOK then snapshot.status="partial"
          else snapshot.status=authError or "error" end
          finish(snapshot,usageOK or profileOK)
        end)
      end)
    end
    if session.expired then
      refresh(function(ok,reason) if ok then sync() else fail(reason) end end)
    else
      sync()
    end
  end

  local function update()
    local minutes=math.clamp(tonumber(host.getConfig("refresh_minutes")) or 1,1,1440)
    host.setUpdateInterval(minutes*60000)
    fetch()
  end
  host.state.watch("codex.refresh",function(value)
    if type(value)=="number" then fetch() end
  end)
  loadCache()
  update()
  return {refresh=fetch,update=update,onIpc=function(event) if event=="refresh" then fetch() end end}
end

local driver
function update() if driver then driver.update() end end
function onIpc(event) if driver then driver.onIpc(event) end end
if noctalia ~= nil then driver=Service.start(noctalia) end
return Service
