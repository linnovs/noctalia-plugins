--!nonstrict
local Widget=require("./widget")
local Panel=require("./panel")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local state={status="ok",fiveHour={kind="5h",used=42,resetsAt=os.time()+11520},
 weekly={kind="weekly",used=71,resetsAt=os.time()+86400},warn=true,warnReason="today",
 usedToday=18,todayBudget=15,credits={balance=20},resetsAvailable=2,
 tokens={today=100,thisWeek=12400000,lastWeek=900000,todayAsOf="2026-11-13"},fetchedAt=os.time()}
local watches, result, config = {}, {}, {show_credits=true,bar_window="auto"}
local host={
 state={get=function() return state end,watch=function(key,cb) watches[key]=cb end,
 set=function(key,value) result.refresh=key end},
 getConfig=function(key) return config[key] end,
 tr=function(key) return key end,isDarkMode=function() return true end,
 setUpdateInterval=function() end,togglePanel=function(id) result.panel=id end,
}
local bar={setImage=function(path) result.icon=path end,setText=function(text) result.text=text end,
 setColor=function(color) result.color=color end,setTooltip=function(rows) result.tooltip=rows end}
local widget=Widget.start(host,bar)
assert(string.find(result.text,"58%%  3h"))
eq(result.color,"warning")
eq(#result.tooltip,2)
widget.onClick()
eq(result.panel,"linnovs/codex-usage:panel")
config.bar_window="weekly"
widget.update()
eq(result.text,"29%")
config.bar_window="5h"
state={status="ok",weekly=state.weekly}
watches["codex.usage"](state)
eq(result.text,"—")
state={status="loading"}
watches["codex.usage"](state)
eq(result.color,"on_surface")

local tree
local primitives={}
for _,name in ipairs({"column","row","label","progress","button","scroll"}) do
 primitives[name]=function(props,children) return {kind=name,props=props,children=children or {}} end
end
local panel={render=function(value) tree=value end,setWantsSecondTicks=function() end}
state={status="partial",fiveHour={kind="5h",used=42,resetsAt=os.time()+100},
 usedToday=18,todayBudget=15,warn=true,warnReason="today",credits={balance="$4.20"},
 tokens={today=100,thisWeek=12400000,lastWeek=900000,todayAsOf="2026-11-13"},fetchedAt=os.time()}
local view=Panel.start(host,panel,primitives)
local function find(node,predicate)
 if predicate(node) then return node end
 for _,child in ipairs(node.children) do local found=find(child,predicate) if found then return found end end
 return nil
end
local function label(text) return find(tree,function(n) return n.kind=="label" and n.props.text==text end) end
eq(tree.kind,"column")
assert(label("58%"))
assert(label("12.4M"))
assert(label("panel.credits"))
assert(label("$4.20"))
assert(label("status.partial"))
assert(find(tree,function(n) return n.kind=="label" and string.find(n.props.text,"2026-11-13",1,true) end))
local button=find(tree,function(n) return n.kind=="button" end)
button.props.onClick()
eq(result.refresh,"codex.refresh")
config.show_credits=false
view.update()
eq(label("panel.credits"),nil)
print("ui_test ok")
