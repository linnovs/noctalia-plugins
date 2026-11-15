--!nonstrict
local ok, Usage = pcall(require, "./lib/usage.luau")
if not ok then
  Usage = require("./lib/usage")
end
local Widget={}
function Widget.start(host,bar)
  local usage=host.state.get("codex.usage") or {status="loading"}
  local function render()
    local now=os.time()
    local selected=Usage.selectBarWindow(usage,host.getConfig("bar_window"))
    bar.setImage(host.isDarkMode() and "assets/codex_dark.webp" or "assets/codex_light.webp",false,18)
    bar.setText(Usage.formatBarText(selected,now))
    local color="primary"
    if selected==nil then
      color=usage.status=="loading" and "on_surface" or "error"
    elseif usage.warn then color="warning" end
    bar.setColor(color)
    local rows={}
    for _,key in ipairs({"fiveHour","weekly"}) do
      local window=usage[key]
      if window then
        local value=host.tr("widget.used").." "..Usage.formatPercent(window.used)
          .." · "..host.tr("widget.left").." "..Usage.formatPercent(Usage.percentLeft(window.used))
        local remaining=Usage.formatRemaining(now,window.resetsAt)
        if remaining then value=value.." · "..host.tr("widget.resets").." "..remaining end
        table.insert(rows,{key=host.tr(key=="fiveHour" and "widget.five_h" or "widget.weekly"),value=value})
      end
    end
    if usage.status and usage.status~="ok" then
      table.insert(rows,{key=host.tr("widget.status"),value=host.tr("status."..usage.status)})
    end
    if #rows==0 then bar.setTooltip(host.tr("status.loading")) else bar.setTooltip(rows) end
  end
  host.state.watch("codex.usage",function(value)
    usage=type(value)=="table" and value or {status="loading"}
    render()
  end)
  local function update()
    host.setUpdateInterval(60000)
    render()
  end
  update()
  return {update=update,onClick=function() host.togglePanel("linnovs/codex-usage:panel") end}
end
local driver
function update() if driver then driver.update() end end
function onClick() if driver then driver.onClick() end end
if noctalia~=nil then driver=Widget.start(noctalia,barWidget) end
return Widget
