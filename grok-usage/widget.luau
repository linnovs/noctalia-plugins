--!nonstrict
-- Bar widget: this week's Grok allowance, as a percentage.

local Usage = require("./lib/usage.luau")

local usage = noctalia.state.get("grok.usage")

local function render()
  local percent = usage and usage.percent
  local icon = "assets/grok_light.webp"
  if noctalia.isDarkMode() then
    icon = "assets/grok_dark.webp"
  end
  barWidget.setImage(icon, false, 18)
  if type(percent) == "number" then
    barWidget.setText(Usage.formatPercent(percent))
    barWidget.setColor("primary")
  else
    barWidget.setText("—")
    if usage == nil or usage.status == "loading" then
      barWidget.setColor("on_surface")
    else
      barWidget.setColor("error")
    end
  end

  local rows = {}
  if type(percent) == "number" then
    table.insert(rows, {
      key = noctalia.tr("widget.week"),
      value = Usage.formatPercent(percent),
    })
  end
  local remaining = usage and Usage.formatRemaining(os.time(), usage.resetsAt)
  if remaining ~= nil then
    table.insert(rows, {
      key = noctalia.tr("widget.resets"),
      value = remaining,
    })
  end
  local status = usage and usage.status
  local statusKey = Usage.statusKey(status)
  if statusKey ~= nil and status ~= "ok" and status ~= "loading" then
    table.insert(rows, {
      key = noctalia.tr("widget.status"),
      value = noctalia.tr(statusKey),
    })
  end
  if #rows == 0 then
    barWidget.setTooltip(noctalia.tr("status.loading"))
  else
    barWidget.setTooltip(rows)
  end
end

noctalia.state.watch("grok.usage", function(value)
  usage = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel("linnovs/grok-usage:panel")
end

render()
