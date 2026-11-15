--!nonstrict
local ok, Usage = pcall(require, "./lib/usage.luau")
if not ok then
  Usage = require("./lib/usage")
end
local Panel={}
function Panel.start(host,surface,ui)
  local usage=host.state.get("codex.usage") or {status="loading"}
  local function label(text,color,size)
    return ui.label({text=text,color=color or "on_surface",fontSize=size or 13})
  end
  local function row(key,value)
    return ui.row({justify="space_between",align="center",gap=8},{
      label(host.tr(key),"on_surface_variant"),label(value),
    })
  end
  local function section(children)
    return ui.column({align="stretch",gap=6},children)
  end
  local function render()
    local now=os.time()
    local sections={section({ui.row({align="center",justify="space_between",gap=8},{
      ui.label({text=host.tr("panel.title"),fontSize=16,fontWeight="bold",color="on_surface",flexGrow=1}),
      ui.button({glyph="refresh",variant="ghost",tooltip=host.tr("panel.refresh"),enabled=usage.fetching~=true,
        onClick=function() host.state.set("codex.refresh",os.clock()) end}),
    })})}
    for _,key in ipairs({"fiveHour","weekly"}) do
      local window=usage[key]
      if window then
        local children={
          ui.row({align="center",gap=8},{
            ui.label({text=Usage.formatPercent(Usage.percentLeft(window.used)),fontSize=32,fontWeight="heavy",color="on_surface"}),
            label(host.tr("panel.left"),"on_surface_variant"),
            label(host.tr(key=="fiveHour" and "panel.five_h" or "panel.weekly"),"on_surface_variant"),
          }),
          ui.row({gap=10,align="center",justify="space_between"},{
            ui.progress({progress=math.clamp(window.used/100,0,1),fill=usage.warn and "warning" or "primary",
              track="surface_variant",height=8,radius=4,flexGrow=1}),
            ui.label({text=Usage.formatPercent(window.used),fontWeight="bold",
              color=usage.warn and "warning" or "primary"}),
          }),
        }
        local resetRow={}
        local remaining=Usage.formatRemaining(now,window.resetsAt)
        if remaining then
          table.insert(resetRow,label(host.tr("panel.resets_in").." "..remaining,"on_surface_variant",12))
        end
        local clock=Usage.formatResetClock(window.resetsAt)
        if clock then
          table.insert(resetRow,label(clock,"on_surface_variant",12))
        end
        if #resetRow > 0 then
          table.insert(children,ui.row({align="center",gap=8},resetRow))
        end
        table.insert(sections,section(children))
      end
    end
    if type(usage.usedToday)=="number" then
      local pace={label(host.tr("panel.today_pace")),
        row("panel.used_today",Usage.formatPercent(usage.usedToday)),
        row("panel.today_budget",Usage.formatPercent(usage.todayBudget)),
        label(host.tr("panel.today_budget_note"),"on_surface_variant",12),
      }
      if usage.warn then
        local explanation=host.tr("panel.warn_fixed")
        if usage.warnReason=="today" then
          explanation=host.tr("panel.warn_today").." "..Usage.formatPercent(usage.usedToday)
            .." ≥ "..Usage.formatPercent(usage.todayBudget)
        end
        table.insert(pace,label(explanation,"warning",12))
      end
      table.insert(sections,section(pace))
    elseif usage.warn then
      table.insert(sections,label(host.tr("panel.warn_fixed"),"warning",12))
    end
    local credits=usage.credits
    local balanceText=nil
    if type(credits)=="table" then
      if type(credits.balance)=="string" and credits.balance~="" then
        balanceText=credits.balance
      elseif type(credits.balance)=="number" then
        balanceText=tostring(credits.balance)
      end
    end
    local usefulCredits=type(credits)=="table" and (credits.unlimited or credits.hasCredits or balanceText~=nil)
    if host.getConfig("show_credits")~=false and (usefulCredits or type(usage.resetsAvailable)=="number") then
      local children={label(host.tr("panel.credits"))}
      if usefulCredits then
        if credits.unlimited then table.insert(children,label(host.tr("panel.credits_unlimited")))
        elseif balanceText~=nil then table.insert(children,row("panel.credits_balance",balanceText)) end
      end
      if type(usage.resetsAvailable)=="number" then
        table.insert(children,row("panel.rate_limit_resets",tostring(usage.resetsAvailable)))
      end
      table.insert(sections,section(children))
    end
    local tokens=usage.tokens or {}
    table.insert(sections,section({label(host.tr("panel.tokens_calendar")),
      row("panel.tokens_today",Usage.formatTokenCount(tokens.today)),
      row("panel.tokens_this_week",Usage.formatTokenCount(tokens.thisWeek)),
      row("panel.tokens_last_week",Usage.formatTokenCount(tokens.lastWeek)),
      label(host.tr("panel.tokens_calendar_note"),"on_surface_variant",12),
    }))
    local footer={}
    if type(usage.fetchedAt)=="number" then
      local ago=Usage.formatRemaining(0,math.max(0,now-usage.fetchedAt))
      local text=host.tr("panel.updated_now")
      if now-usage.fetchedAt>=60 then text=host.tr("panel.last_refresh").." · "..ago.." "..host.tr("panel.ago") end
      table.insert(footer,label(text,"on_surface_variant",12))
    end
    table.insert(footer,label(host.tr("status."..(usage.status or "loading")),
      (usage.status=="ok" or usage.status=="loading") and "on_surface_variant" or "error",12))
    if tokens.todayAsOf then
      table.insert(footer,label(host.tr("panel.tokens_as_of").." "..tokens.todayAsOf,"on_surface_variant",12))
    end
    table.insert(sections,section(footer))
    -- Column (not flexGrow scroll): height follows content up to max_height, without
    -- stretching a tall empty viewport when the payload is shorter.
    surface.render(ui.column({align="stretch",gap=12,justify="start"},sections))
  end
  host.state.watch("codex.usage",function(value)
    if type(value)=="table" then usage=value render() end
  end)
  surface.setWantsSecondTicks(true)
  render()
  return {update=render,onOpen=function() usage=host.state.get("codex.usage") or usage render() end}
end
local driver
function update() if driver then driver.update() end end
function onOpen() if driver then driver.onOpen() end end
if noctalia~=nil then driver=Panel.start(noctalia,panel,ui) end
return Panel
