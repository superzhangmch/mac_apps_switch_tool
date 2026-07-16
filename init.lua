require("hs.ipc")  -- 允许命令行 `hs -c "..."` 控制（重载/诊断）

-- ===== 快速唤起/切换：Teams / iTerm / Chrome =====
-- 修饰键统一用 ⌘⌃ (cmd+ctrl)，改 MODS 即可整体替换
local MODS = {"cmd", "ctrl"}

local ITERM_BUNDLE  = "com.googlecode.iterm2"
local CHROME_BUNDLE = "com.google.Chrome"
local CYCLE_BURST   = 1.2   -- 秒：此间隔内再次按同一键视为"连按轮换"

local function centerMouseOn(win)     -- 把鼠标移到窗口正中
    if not win then return end
    local f = win:frame()
    hs.mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + f.h / 2 })
end

local function wrapFullscreen(fn)     -- 当前最前窗口若为原生全屏，先退出再执行 fn
    return function()
        local cur = hs.window.focusedWindow()
        if cur and cur:isFullScreen() then
            cur:setFullScreen(false)
            hs.timer.doAfter(0.8, fn)   -- 等 Space 切换动画稳定
        else
            fn()
        end
    end
end

-- ===== Teams (⌘⌃T)：激活 → 聚焦最近使用的窗口 → 移鼠标到窗口正中（不最大化）=====
local function focusApp(bundle, maximize, moveMouse)
    hs.application.launchOrFocusByBundleID(bundle)   -- macOS 会自动聚焦该 App 最近使用的窗口
    local tries = 0
    local function settle()
        tries = tries + 1
        local app = hs.application.get(bundle)
        local win = app and (app:focusedWindow() or app:mainWindow() or app:allWindows()[1])
        if win then
            win:unminimize()
            win:focus()
            if maximize then win:maximize() end
            if moveMouse then hs.timer.doAfter(maximize and 0.2 or 0, function() centerMouseOn(win) end) end
        elseif tries < 20 then        -- 冷启动可能要等，最多重试 ~3s
            hs.timer.doAfter(0.15, settle)
        end
    end
    hs.timer.doAfter(0.15, settle)
end

hs.hotkey.bind(MODS, "T", wrapFullscreen(function()
    focusApp("com.microsoft.teams2", false, true)   -- 不最大化，切后移鼠标
end))

-- ===== iTerm (⌘⌃I) / Chrome (⌘⌃C)：同一套"连按轮换"逻辑 =====
-- 不跨屏移动窗口（避免搞混哪个在哪块屏）：
-- · 若每块屏上的窗口都 ≤1 个 → 一次把该 App 所有窗口全抬到前台（各屏一个，全看得见）
-- · 若某块屏上有 ≥2 个窗口（会互相遮挡）→ 短时间内连按，从最近使用的开始逐个轮换
-- · 该 App 只在一块屏上时，切后把鼠标移到目标窗口正中（多屏时不移）
local function appWindows(bundle)      -- 该 App 的标准窗口，按 id 稳定排序
    local app = hs.application.get(bundle)
    if not app then return nil, {} end
    local wins = {}
    for _, w in ipairs(app:allWindows()) do
        if w:isStandard() then wins[#wins + 1] = w end
    end
    table.sort(wins, function(a, b) return a:id() < b:id() end)
    return app, wins
end

local function maxPerScreen(wins)      -- 单块屏上最多有几个窗口
    local per, mx = {}, 0
    for _, w in ipairs(wins) do
        local sid = w:screen() and w:screen():id() or 0
        per[sid] = (per[sid] or 0) + 1
        if per[sid] > mx then mx = per[sid] end
    end
    return mx
end

local function distinctScreens(wins)   -- 窗口分布在几块屏上
    local seen, n = {}, 0
    for _, w in ipairs(wins) do
        local sid = w:screen() and w:screen():id() or 0
        if not seen[sid] then seen[sid] = true; n = n + 1 end
    end
    return n
end

local function cycleApp(bundle, state)
    local app, wins = appWindows(bundle)
    if not app or #wins == 0 then
        hs.application.launchOrFocusByBundleID(bundle)   -- 没开就启动
        return
    end

    local single = distinctScreens(wins) == 1   -- 只在一块屏上
    local target                                 -- 最终聚焦的窗口

    if maxPerScreen(wins) <= 1 then
        -- 每块屏都 ≤1 个窗口 → 全部抬到前台，不轮换
        app:activate(true)
        state.idx, state.last = 0, 0
        target = app:focusedWindow() or app:mainWindow() or wins[1]
    else
        -- 同屏有多个窗口会遮挡 → 连按逐个轮换（不移动窗口位置）
        local now = hs.timer.secondsSinceEpoch()
        if now - state.last < CYCLE_BURST and state.idx >= 1 then
            state.idx = (state.idx % #wins) + 1    -- 连按：下一个（循环）
        else
            local mru = app:focusedWindow() or app:mainWindow() or wins[1]  -- 首次：从最近使用的开始
            state.idx = 1
            for k, w in ipairs(wins) do if w == mru then state.idx = k; break end end
        end
        state.last = now
        target = wins[state.idx]
        if target then target:unminimize(); target:focus() end
    end

    if single and target then centerMouseOn(target) end
end

local itermState  = { idx = 0, last = 0 }
local chromeState = { idx = 0, last = 0 }
hs.hotkey.bind(MODS, "I", wrapFullscreen(function() cycleApp(ITERM_BUNDLE,  itermState)  end))
hs.hotkey.bind(MODS, "C", wrapFullscreen(function() cycleApp(CHROME_BUNDLE, chromeState) end))

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

hs.hotkey.bind(MODS, "B", function()
    hideGrid()
    -- 用 app:allWindows() 而非 hs.window.filter.new（后者每次新建都很重，是"慢"的主因）
    local _, wins = appWindows(CHROME_BUNDLE)
    if #wins == 0 then hs.alert.show("没有 Chrome 窗口"); return end
    browserGrid.wins = wins

    local sf      = hs.screen.mainScreen():frame()
    local n       = #wins

    -- 给每个显示器一个短标签：D1=按 allScreens 顺序，主屏加 *
    local screenLabel, primary = {}, hs.screen.primaryScreen()
    for si, s in ipairs(hs.screen.allScreens()) do
        screenLabel[s:id()] = "D" .. si .. (s:id() == primary:id() and "*" or "")
    end
    local multiDisplay = #hs.screen.allScreens() > 1

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

    local cells = {}   -- 记录每格位置，供异步填缩略图
    for i, w in ipairs(wins) do
        local x = margin + ((i - 1) % cols) * (cellW + gap)
        local y = margin + math.floor((i - 1) / cols) * (cellH + gap)
        cells[i] = { x = x, y = y }
        c[#c + 1] = {  -- 缩略图背景框（可点击）
            type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 8, yRadius = 8 },
            fillColor = { white = 0.15 }, frame = { x = x, y = y, w = cellW, h = thumbH },
            trackMouseDown = true, id = "win" .. i,
        }
        local title = w:title() ~= "" and w:title() or "(无标题)"
        local sc = w:screen()
        local dlab = sc and screenLabel[sc:id()] or "?"
        c[#c + 1] = {  -- 序号 +（多屏时）显示器标记 + 标题
            type = "text",
            text = multiDisplay and string.format("%d.  [%s] %s", i, dlab, title)
                                 or string.format("%d.  %s", i, title),
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
    c:show()                       -- 先立刻显示（框+标题），缩略图随后补上
    browserGrid.canvas = c

    hs.timer.doAfter(0, function() -- snapshot 较慢，挪到下一轮事件循环，避免卡住弹出
        if browserGrid.canvas ~= c then return end   -- 已被关掉就别画了
        for i, w in ipairs(wins) do
            if browserGrid.canvas ~= c then return end
            local snap = w:snapshot()
            if snap then
                c[#c + 1] = {
                    type = "image", image = snap, imageScaling = "scaleProportionally",
                    frame = { x = cells[i].x + 6, y = cells[i].y + 6, w = cellW - 12, h = thumbH - 12 },
                    trackMouseDown = true, id = "win" .. i,
                }
            end
        end
    end)

    local m = hs.hotkey.modal.new()
    for k = 1, math.min(n, 9) do m:bind({}, tostring(k), function() pickGrid(k) end) end
    m:bind({}, "escape", function() hideGrid() end)
    m:enter()
    browserGrid.modal = m
end)

hs.alert.show("Hammerspoon ✅  ⌘⌃T/I/C=Teams/iTerm/Chrome  ⌘⌃B=所有Chrome窗口")
