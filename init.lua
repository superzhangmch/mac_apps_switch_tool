require("hs.ipc")  -- 允许命令行 `hs -c "..."` 控制（重载/诊断）

-- ===== 快速唤起/切换：Teams / iTerm / Chrome =====
-- 行为：若当前最前窗口是原生全屏先退出 -> 激活目标 App -> 聚焦其"最近使用"的窗口
--       maximize=true 的还会把窗口最大化（填满屏幕，非原生全屏）
-- 修饰键统一用 ⌘⌃ (cmd+ctrl)，改 MODS 即可整体替换

local MODS = {"cmd", "ctrl"}

local APPS = {
    { key = "T", bundle = "com.microsoft.teams2",   maximize = false },  -- Teams（不最大化）
    { key = "I", bundle = "com.googlecode.iterm2",  maximize = true },  -- iTerm
    { key = "C", bundle = "com.google.Chrome",      maximize = true },  -- Chrome（激活最近用的窗口）
}

local function focusApp(bundle, maximize)
    -- 激活并切到前台；macOS 会自动聚焦该 App"最近使用"的那个窗口（满足 Chrome 的需求）
    hs.application.launchOrFocusByBundleID(bundle)

    local tries = 0
    local function settle()
        tries = tries + 1
        local app = hs.application.get(bundle)
        local win = app and (app:focusedWindow() or app:mainWindow() or app:allWindows()[1])
        if win then
            win:unminimize()          -- 万一最近那个窗口被最小化了
            win:focus()
            if maximize then win:maximize() end
        elseif tries < 20 then        -- 冷启动可能要等，最多重试 ~3s
            hs.timer.doAfter(0.15, settle)
        end
    end
    hs.timer.doAfter(0.15, settle)
end

for _, a in ipairs(APPS) do
    hs.hotkey.bind(MODS, a.key, function()
        -- 当前最前窗口若处于原生全屏，先退出（避免切走后留下空的全屏 Space）
        local cur = hs.window.focusedWindow()
        if cur and cur:isFullScreen() then
            cur:setFullScreen(false)
            hs.timer.doAfter(0.8, function() focusApp(a.bundle, a.maximize) end)
        else
            focusApp(a.bundle, a.maximize)
        end
    end)
end

-- ===== 列出所有 Chrome 窗口（大缩略图网格，固定顺序）：⌘⌃B (b=browser) =====
-- 按窗口 id 排序（创建时分配、终生不变）→ 每次顺序一致
-- 点缩略图 / 按数字键 1-9 切到该窗口 / Esc 取消
local browserGrid = { canvas = nil, modal = nil, wins = {} }

local function hideGrid()
    if browserGrid.canvas then browserGrid.canvas:delete(); browserGrid.canvas = nil end
    if browserGrid.modal then browserGrid.modal:exit(); browserGrid.modal = nil end
    browserGrid.wins = {}
end

local function pickGrid(n)
    local w = browserGrid.wins[n]
    hideGrid()
    if w then w:unminimize(); w:focus() end
end

hs.hotkey.bind({"cmd", "ctrl"}, "B", function()
    hideGrid()
    local wins = hs.window.filter.new("Google Chrome"):getWindows()
    table.sort(wins, function(a, b) return a:id() < b:id() end)  -- 稳定排序键
    if #wins == 0 then hs.alert.show("没有 Chrome 窗口"); return end
    browserGrid.wins = wins

    local sf      = hs.screen.mainScreen():frame()
    local n       = #wins
    local cols    = math.ceil(math.sqrt(n))
    local rows    = math.ceil(n / cols)
    local margin  = 60
    local gap     = 18
    local titleH  = 24
    local cellW   = (sf.w - margin * 2 - gap * (cols - 1)) / cols
    local cellH   = (sf.h - margin * 2 - gap * (rows - 1)) / rows
    local thumbH  = cellH - titleH

    local c = hs.canvas.new(sf)
    c[#c + 1] = { type = "rectangle", action = "fill", fillColor = { black = 1, alpha = 0.8 } }

    for i, w in ipairs(wins) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local x = margin + col * (cellW + gap)
        local y = margin + row * (cellH + gap)
        c[#c + 1] = {  -- 缩略图（背景框 + 可点击）
            type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 8, yRadius = 8 },
            fillColor = { white = 0.15 }, frame = { x = x, y = y, w = cellW, h = thumbH },
            trackMouseDown = true, id = "win" .. i,
        }
        local snap = w:snapshot()
        if snap then
            c[#c + 1] = {
                type = "image", image = snap, imageScaling = "scaleProportionally",
                frame = { x = x + 6, y = y + 6, w = cellW - 12, h = thumbH - 12 },
                trackMouseDown = true, id = "win" .. i,
            }
        end
        c[#c + 1] = {  -- 序号 + 标题
            type = "text",
            text = string.format("%d.  %s", i, w:title() ~= "" and w:title() or "(无标题)"),
            frame = { x = x, y = y + thumbH + 2, w = cellW, h = titleH },
            textSize = 15, textColor = { white = 1 }, textAlignment = "center",
        }
    end

    c:mouseCallback(function(_, ev, id)
        if ev == "mouseDown" and type(id) == "string" then
            local idx = tonumber(id:match("^win(%d+)$"))
            if idx then pickGrid(idx) end
        end
    end)
    c:show()
    browserGrid.canvas = c

    local m = hs.hotkey.modal.new()
    for k = 1, math.min(n, 9) do m:bind({}, tostring(k), function() pickGrid(k) end) end
    m:bind({}, "escape", function() hideGrid() end)
    m:enter()
    browserGrid.modal = m
end)

hs.alert.show("Hammerspoon ✅  ⌘⌃T/I/C=Teams/iTerm/Chrome  ⌘⌃B=所有Chrome窗口")
