--!nonstrict
-- Bar widget: paced daily budget remaining (0–100).

local Usage = require("./lib/usage.luau")

local usage = noctalia.state.get("grok.usage")

local function render()
  local percent = usage and usage.percent
  local left = Usage.percentLeft(percent)
  local now = os.time()
  local utcOffset = Usage.parseUtcOffset(noctalia.formatTime("%z", now))
  local pace, lastDay = Usage.dailyPaceLeft(
    percent,
    now,
    usage and usage.resetsAt,
    utcOffset,
    usage and usage.history
  )
  local dailyText = Usage.formatDailyLeft(pace)

  local icon = "assets/grok_light.webp"
  if noctalia.isDarkMode() then
    icon = "assets/grok_dark.webp"
  end
  barWidget.setImage(icon, false, 18)

  if dailyText ~= nil then
    barWidget.setText(dailyText)
    barWidget.setColor("primary")
  elseif type(left) == "number" then
    barWidget.setText(Usage.formatPercent(left))
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
  if dailyText ~= nil then
    table.insert(rows, {
      key = noctalia.tr(lastDay and "widget.until_reset" or "widget.today"),
      value = dailyText,
    })
  end
  if type(left) == "number" then
    table.insert(rows, {
      key = noctalia.tr("widget.left"),
      value = Usage.formatPercent(left),
    })
  end
  if type(percent) == "number" then
    table.insert(rows, {
      key = noctalia.tr("widget.week"),
      value = Usage.formatPercent(percent),
    })
  end
  local remaining = usage and Usage.formatRemaining(now, usage.resetsAt)
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
