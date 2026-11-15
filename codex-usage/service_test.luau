--!nonstrict
-- Exercise the real sync driver with deterministic file/HTTP boundaries.
local Service = require("./service")
local function eq(a,b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function fixture()
  local saved, requests, watches, values = {}, {}, {}, {}
  local auth = {tokens={access_token="access", refresh_token="refresh", account_id="account"}, other="keep"}
  local usage = {rate_limit={primary_window={used_percent=40,limit_window_seconds=604800,reset_at=os.time()+4*86400}}}
  local objects = {auth=auth, usage=usage, profile={stats={daily_usage_buckets={{start_date=os.date("%Y-%m-%d"),tokens=100}}}}, fresh={access_token="new-access",refresh_token="new-refresh"}}
  local serial = 0
  local host = {
    getenv=function(key) return key == "CODEX_HOME" and "/codex" or nil end,
    expandPath=function() return "/default/auth.json" end,
    pluginDataDir=function() return "/data" end,
    readFile=function(path) return saved[path] or (path == "/codex/auth.json" and "auth" or nil) end,
    writeFile=function(path, value) saved[path]=value return true end,
    getConfig=function(key) return ({weekly_warn_mode="today",refresh_minutes=1})[key] end,
    setUpdateInterval=function(value) values.interval=value end,
    state={get=function(key) return values[key] end, set=function(key,value) values[key]=value end,
      watch=function(key,callback) watches[key]=callback end},
    json={decode=function(key) return objects[key] end, encode=function(value)
      serial += 1 local key="encoded"..serial objects[key]=value return key
    end},
    http=function(req,callback) table.insert(requests,{req=req,callback=callback}) return true end,
  }
  local function respond(index, status, body)
    requests[index].callback({ok=status==200,status=status,body=body})
  end
  return host, requests, respond, values, saved, objects, watches
end

local host, requests, respond, values, saved, objects, watches = fixture()
local driver = Service.start(host)
eq(#requests,1)
eq(requests[1].req.url,"https://chatgpt.com/backend-api/wham/usage")
eq(requests[1].req.headers[1],"Authorization: Bearer access")
eq(requests[1].req.headers[3],"ChatGPT-Account-Id: account")
driver.refresh() -- coalesce a second refresh while in flight
respond(1,200,"usage")
eq(requests[2].req.url,"https://chatgpt.com/backend-api/wham/profiles/me")
respond(2,200,"profile")
eq(values["codex.usage"].weekly.used,40)
eq(values["codex.usage"].tokens.today,100)
eq(#requests,3)
respond(3,200,"usage")
respond(4,500,"")
eq(values["codex.usage"].status,"partial")
eq(values["codex.usage"].tokens.today,100)
eq(values["codex.usage"].fetching,false)
local cache = objects[saved["/data/usage.json"]]
eq(cache.tokens.today,100)
eq(cache.access_token,nil)
eq(cache.refresh_token,nil)
eq(cache.baseline.baselineUsed,40)
driver.update()
eq(values.interval,60000)
respond(5,401,"")
eq(requests[6].req.url,"https://auth.openai.com/oauth/token")
eq(objects[requests[6].req.body].refresh_token,"refresh")
respond(6,200,"fresh")
eq(objects[saved["/codex/auth.json"]].tokens.access_token,"new-access")
eq(objects[saved["/codex/auth.json"]].other,"keep")
eq(requests[7].req.headers[1],"Authorization: Bearer new-access")
respond(7,401,"") -- one refresh only
respond(8,500,"") -- profile still attempted independently
eq(values["codex.usage"].status,"unauthorized")
eq(values["codex.usage"].weekly.used,40)
eq(values["codex.usage"].fetching,false)

-- Usage failure does not prevent a successful profile update.
local h,r,reply,v = fixture()
local d=Service.start(h)
reply(1,500,"")
reply(2,200,"profile")
eq(v["codex.usage"].status,"partial")
eq(v["codex.usage"].tokens.today,100)
eq(v["codex.usage"].weekly,nil)

-- Missing auth starts no network work; explicit CODEX_HOME never falls back.
local h2,r2,_,v2 = fixture()
h2.readFile=function() return nil end
Service.start(h2)
eq(#r2,0)
eq(v2["codex.usage"].status,"missing_auth")
-- Expired access refreshes before GET; a rejected refresh settles the driver.
local h3,r3,reply3,v3,s3,o3=fixture()
o3.auth.tokens.access_token="h.eyJleHAiOjF9.s"
local d3=Service.start(h3)
eq(r3[1].req.url,"https://auth.openai.com/oauth/token")
reply3(1,400,"")
eq(v3["codex.usage"].status,"expired")
eq(v3["codex.usage"].fetching,false)
d3.onIpc("refresh")
eq(#r3,2)

-- Synchronous failure to start a request still releases the in-flight guard.
local h4,r4,_,v4=fixture()
h4.http=function() return false end
local d4=Service.start(h4)
eq(v4["codex.usage"].status,"error")
eq(v4["codex.usage"].fetching,false)
d4.refresh()
eq(v4["codex.usage"].fetching,false)

-- A concurrent account change must never be overwritten by refresh completion.
local h5,r5,reply5,v5,s5,o5=fixture()
Service.start(h5)
reply5(1,401,"")
o5.auth={tokens={access_token="other-access",refresh_token="other-refresh",account_id="other"}}
reply5(2,200,"fresh")
eq(s5["/codex/auth.json"],nil)
reply5(3,401,"")
eq(v5["codex.usage"].status,"unauthorized")
eq(o5.auth.tokens.access_token,"other-access")

-- Stale cached daily buckets are reselected against the current local date.
local h6,r6,reply6,v6,s6,o6=fixture()
o6.cache={accountId="account",weekly={used=42,kind="weekly",resetsAt=os.time()+86400},
 profileStats={daily={["2000-01-01"]=999},weekly={}},tokens={today=999},
 baseline={baselineUsed=40,dayKey="2000-01-01",windowKey=123}}
s6["/data/usage.json"]="cache"
Service.start(h6)
reply6(1,500,"") reply6(2,500,"")
eq(v6["codex.usage"].tokens.today,nil)
eq(v6["codex.usage"].tokens.todayAsOf,"2000-01-01")
eq(v6["codex.usage"].weekly.used,42)
print("service_test ok")
