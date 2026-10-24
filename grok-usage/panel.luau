--!nonstrict
-- Attached panel: refresh, the week's usage as a bar, and time until reset.

local Usage = require("./lib/usage.luau")

local usage = noctalia.state.get("grok.usage") or {
  status = "loading",
  fetching = false,
}

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

  if hasNumber then
    table.insert(children, ui.row({ gap = 10, align = "center" }, {
      ui.progress({
        progress = Usage.progress(usage.percent),
        fill = "primary",
        track = "surface_variant",
        radius = 4,
        height = 8,
        flexGrow = 1,
      }),
      ui.label({
        text = Usage.formatPercent(usage.percent),
        fontWeight = "bold",
        color = "primary",
      }),
    }))
  end

  if remaining ~= nil then
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = remaining, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = noctalia.tr("panel.until_cycle"), color = "on_surface_variant" }),
    }))
  elseif not hasNumber and (usage.status == "loading" or usage.fetching == true) then
    table.insert(children, ui.label({
      text = noctalia.tr("status.loading"),
      color = "on_surface_variant",
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

  panel.render(ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, children))
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
