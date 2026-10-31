--!nonstrict
-- Attached panel: refresh, the week's usage as a bar, and time until reset.

local Usage = require("./lib/usage.luau")

local usage = noctalia.state.get("grok.usage") or {
  status = "loading",
  fetching = false,
}

local productFills = { "tertiary", "secondary", "info", "warning", "success" }

local function productSlices(products)
  local slices = {}
  if type(products) ~= "table" then
    return slices
  end
  for _, product in ipairs(products) do
    if type(product) == "table" and type(product.label) == "string" and type(product.percent) == "number" then
      table.insert(slices, {
        label = product.label,
        percent = product.percent,
        fill = productFills[((#slices) % #productFills) + 1],
      })
    end
  end
  return slices
end

local function stackedBar(slices)
  local barWidth = 230
  local used = 0
  for _, slice in ipairs(slices) do
    if slice.percent > 0 then
      used = used + slice.percent
    end
  end
  local scale = used > 100 and (100 / used) or 1
  if used > 100 then
    used = 100
  end
  local segments = {}
  for _, slice in ipairs(slices) do
    if slice.percent > 0 then
      local width = math.max(4, math.floor(barWidth * (slice.percent * scale) / 100))
      table.insert(segments, ui.progress({
        progress = 1,
        fill = slice.fill,
        width = width,
        height = 8,
        radius = 4,
      }))
    end
  end
  local rest = math.floor(barWidth * (100 - used) / 100)
  if rest >= 4 then
    table.insert(segments, ui.progress({
      progress = 1,
      fill = "surface_variant",
      width = rest,
      height = 8,
      radius = 4,
    }))
  end
  if #segments == 0 then
    return ui.progress({
      progress = 0,
      fill = "primary",
      track = "surface_variant",
      width = barWidth,
      height = 8,
      radius = 4,
    })
  end
  return ui.row({ gap = 2, align = "center" }, segments)
end

local function requestRefresh()
  noctalia.state.set("grok.refresh", os.clock())
end

local function render()
  local hasNumber = type(usage.percent) == "number"
  local remaining = Usage.formatRemaining(os.time(), usage.resetsAt)
  local statusKey = Usage.statusKey(usage.status)
  local showStatus = statusKey ~= nil and usage.status ~= "ok" and usage.status ~= "loading"

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 16,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh"),
        enabled = usage.fetching ~= true,
        onClick = requestRefresh,
      }),
    }),
  }

  local slices = productSlices(usage.products)
  local daily, lastDay = Usage.dailyLeft(usage.percent, os.time(), usage.resetsAt)
  local dailyText = Usage.formatDailyLeft(daily)
  if dailyText ~= nil then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.label({
        text = dailyText,
        fontWeight = "bold",
        fontSize = 16,
        color = "primary",
      }),
      ui.label({
        text = noctalia.tr(lastDay and "panel.left_until_reset" or "panel.left_today"),
        color = "on_surface_variant",
      }),
    }))
  end

  if hasNumber then
    local bar = ui.progress({
      progress = Usage.progress(usage.percent),
      fill = "primary",
      track = "surface_variant",
      radius = 4,
      height = 8,
      flexGrow = 1,
    })
    if #slices > 0 then
      bar = stackedBar(slices)
    end
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      bar,
      ui.label({
        text = Usage.formatPercent(usage.percent),
        fontWeight = "bold",
        color = "primary",
      }),
    }))
  end

  if remaining ~= nil then
    local countdown = {
      ui.label({ text = remaining, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = noctalia.tr("panel.until_cycle"), color = "on_surface_variant" }),
    }
    local clock = Usage.formatResetClock(usage.resetsAt)
    if clock ~= nil then
      table.insert(countdown, ui.label({ text = clock, color = "on_surface_variant" }))
    end
    table.insert(children, ui.row({ gap = 6, align = "center" }, countdown))
  elseif not hasNumber and (usage.status == "loading" or usage.fetching == true) then
    table.insert(children, ui.label({
      text = noctalia.tr("status.loading"),
      color = "on_surface_variant",
    }))
  end

  for _, slice in ipairs(slices) do
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = slice.label,
        color = slice.fill,
        flexGrow = 1,
      }),
      ui.box({ width = 72 }, {
        ui.progress({
          progress = Usage.progress(slice.percent),
          fill = slice.fill,
          track = "surface_variant",
          radius = 3,
          height = 4,
          flexGrow = 1,
        }),
      }),
      ui.label({
        text = Usage.formatPercent(slice.percent),
        color = slice.fill,
      }),
    }))
  end

  local series = Usage.graphValues(usage.history, os.time())
  if series ~= nil then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.since_last"),
      color = "on_surface_variant",
      fontSize = 12,
    }))
    table.insert(children, ui.graph({
      values = series,
      color = "primary",
      lineWidth = 2,
      fillOpacity = 0.25,
      height = 48,
    }))
  end

  local elapsed = Usage.weekElapsed(os.time(), usage.windowStart, usage.resetsAt)
  if elapsed ~= nil then
    table.insert(children, ui.label({
      text = Usage.formatPercent(elapsed) .. " " .. noctalia.tr("panel.of_the_week"),
      color = "on_surface_variant",
    }))
  end

  local ago = Usage.formatAgo(os.time(), usage.fetchedAt)
  if ago == "now" then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.updated_now"),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  elseif ago ~= nil then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.updated") .. " " .. ago .. " " .. noctalia.tr("panel.ago"),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end

  if showStatus then
    table.insert(children, ui.label({
      text = noctalia.tr(statusKey),
      color = "error",
      fontSize = 12,
      maxLines = 3,
    }))
  end

  panel.render(ui.column({
    flexGrow = 1,
    align = "stretch",
    gap = showStatus and 14 or 0,
    justify = showStatus and "start" or "space_between",
  }, children))
end

function onOpen()
  usage = noctalia.state.get("grok.usage") or usage
  panel.setWantsSecondTicks(true)
  render()
end

panel.setWantsSecondTicks(true)

function update()
  render()
end

noctalia.state.watch("grok.usage", function(value)
  if type(value) == "table" then
    usage = value
    render()
  end
end)

render()
