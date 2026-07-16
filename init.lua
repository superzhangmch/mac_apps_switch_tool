require("hs.ipc")  -- 允许命令行 `hs -c "..."` 控制（重载/诊断）

-- ===== 快速唤起/切换：Teams / iTerm / Chrome =====
-- 修饰键统一用 ⌘⌃ (cmd+ctrl)，改 MODS 即可整体替换
local MODS = {"cmd", "ctrl"}

local ITERM_BUNDLE  = "com.googlecode.iterm2"
local CHROME_BUNDLE = "com.google.Chrome"

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

-- ===== iTerm (⌘⌃I) / Chrome (⌘⌃C)：同一套"每屏各自轮换"逻辑 =====
-- 不跨屏移动窗口。
-- · 尚未在该 App → 直接把它所有窗口前置（各屏显示各自当前窗口），不轮换（这是"切进来"）
-- · 已经在该 App → 每块屏各自把自己的窗口往后轮一格，并把各屏选中的窗口都抬到前台（这是"连按轮换"）
-- · 该 App 只在一块屏上时，切后把鼠标移到目标窗口正中
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

local function appFrontByDisplay(bundle)   -- displayId -> 该 App 在这块屏上最靠前的窗口
    local map = {}
    for _, w in ipairs(hs.window.orderedWindows()) do   -- 前→后顺序，首个命中即该屏最前
        local a = w:application()
        if a and a:bundleID() == bundle then
            local sid = w:screen() and w:screen():id() or 0
            if map[sid] == nil then map[sid] = w end
        end
    end
    return map
end

local function cycleApp(bundle)
    local app, wins = appWindows(bundle)
    if not app or #wins == 0 then
        hs.application.launchOrFocusByBundleID(bundle)   -- 没开就启动
        return
    end

    -- 按显示器分组（各组内保持 id 升序）
    local byDisplay, order = {}, {}
    for _, w in ipairs(wins) do
        local sid = w:screen() and w:screen():id() or 0
        if not byDisplay[sid] then byDisplay[sid] = {}; order[#order + 1] = sid end
        byDisplay[sid][#byDisplay[sid] + 1] = w
    end

    local activeSid = hs.screen.mainScreen():id()
    local frontApp  = hs.application.frontmostApplication()
    local already   = frontApp and frontApp:bundleID() == bundle
    local focusTarget

    if not already then
        -- 尚未在该 App → 全部前置，显示各屏当前窗口，不轮换
        app:activate(true)
        local fm = appFrontByDisplay(bundle)
        focusTarget = fm[activeSid] or app:focusedWindow() or app:mainWindow() or wins[1]
    else
        -- 已在该 App → 每块屏各推进一格，抬到前台
        local fm = appFrontByDisplay(bundle)
        for _, sid in ipairs(order) do
            local list = byDisplay[sid]
            local cur, curIdx = fm[sid], 0
            for k, w in ipairs(list) do
                if cur and w:id() == cur:id() then curIdx = k; break end
            end
            local nextW = list[(curIdx % #list) + 1]   -- 下一个（循环）；curIdx=0 → 第 1 个
            nextW:unminimize()
            nextW:raise()
            if sid == activeSid then focusTarget = nextW end
        end
        focusTarget = focusTarget or byDisplay[order[1]][1]
    end

    if focusTarget then focusTarget:focus() end       -- 激活 App + 键盘焦点给活跃屏上的那个
    if #order == 1 and focusTarget then centerMouseOn(focusTarget) end
end

hs.hotkey.bind(MODS, "I", wrapFullscreen(function() cycleApp(ITERM_BUNDLE)  end))
hs.hotkey.bind(MODS, "C", wrapFullscreen(function() cycleApp(CHROME_BUNDLE) end))

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
