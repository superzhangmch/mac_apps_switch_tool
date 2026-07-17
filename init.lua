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

local function appWindows(bundle)     -- 该 App 的标准窗口，按 id 稳定排序
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

-- ===== iTerm (⌘⌃I)：所有屏一起，每屏各自轮换一格 =====
-- · 尚未在 iTerm → 全部前置（各屏显示当前窗口），不轮换
-- · 已在 iTerm 连按 → 每块屏各推进一格并抬到前台
local function cycleApp(bundle)
    local app, wins = appWindows(bundle)
    if not app or #wins == 0 then
        hs.application.launchOrFocusByBundleID(bundle)   -- 没开就启动
        return
    end

    local byDisplay, order = {}, {}   -- 按显示器分组（组内保持 id 升序）
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
        app:activate(true)
        local fm = appFrontByDisplay(bundle)
        focusTarget = fm[activeSid] or app:focusedWindow() or app:mainWindow() or wins[1]
    else
        local fm = appFrontByDisplay(bundle)
        for _, sid in ipairs(order) do
            local list = byDisplay[sid]
            local cur, curIdx = fm[sid], 0
            for k, w in ipairs(list) do
                if cur and w:id() == cur:id() then curIdx = k; break end
            end
            local nextW = list[(curIdx % #list) + 1]
            nextW:unminimize(); nextW:raise()
            if sid == activeSid then focusTarget = nextW end
        end
        focusTarget = focusTarget or byDisplay[order[1]][1]
    end

    if focusTarget then focusTarget:focus() end
    if #order == 1 and focusTarget then centerMouseOn(focusTarget) end
end

hs.hotkey.bind(MODS, "I", wrapFullscreen(function() cycleApp(ITERM_BUNDLE) end))

-- ===== Chrome：一个键管一块屏的连按轮换 =====
-- 显示器按物理位置从左到右排序：⌘⌃C = 第 1 块(最左)，⌘⌃B = 第 2 块(次左/右)
-- 键盘上 C 在 B 左边，正好对应"左屏 / 右屏"
-- · 尚未在 Chrome → 把该屏当前 Chrome 窗口前置（不轮换）
-- · 已在 Chrome 连按 → 该屏 Chrome 窗口逐个轮换
local function sortedScreens()        -- 从左到右（同列再按上到下）
    local ss = hs.screen.allScreens()
    table.sort(ss, function(a, b)
        local fa, fb = a:frame(), b:frame()
        if fa.x ~= fb.x then return fa.x < fb.x end
        return fa.y < fb.y
    end)
    return ss
end

local function cycleChromeOnScreen(screenPos)
    local app, wins = appWindows(CHROME_BUNDLE)
    if not app or #wins == 0 then
        hs.application.launchOrFocusByBundleID(CHROME_BUNDLE)
        return
    end
    local screens = sortedScreens()
    local scr = screens[screenPos] or screens[#screens]   -- 超出（如只有一块屏）→ 用最后一块
    if not scr then return end
    local sid = scr:id()

    local list = {}                   -- 该屏上的 Chrome 窗口（已 id 升序）
    for _, w in ipairs(wins) do
        if w:screen() and w:screen():id() == sid then list[#list + 1] = w end
    end
    if #list == 0 then hs.alert.show("这块屏上没有 Chrome 窗口"); return end

    local fm = appFrontByDisplay(CHROME_BUNDLE)
    local cur, curIdx = fm[sid], 0
    for k, w in ipairs(list) do if cur and w:id() == cur:id() then curIdx = k; break end end

    local frontApp = hs.application.frontmostApplication()
    local already  = frontApp and frontApp:bundleID() == CHROME_BUNDLE

    local target
    if already and curIdx >= 1 then
        target = list[(curIdx % #list) + 1]        -- 已在 Chrome → 下一个（循环）
    else
        target = list[curIdx >= 1 and curIdx or 1] -- 未在 Chrome → 显示该屏当前（或第一个）
    end
    target:unminimize(); target:raise(); target:focus()
    centerMouseOn(target)
end

hs.hotkey.bind(MODS, "C", wrapFullscreen(function() cycleChromeOnScreen(1) end))  -- 左屏
hs.hotkey.bind(MODS, "B", wrapFullscreen(function() cycleChromeOnScreen(2) end))  -- 右屏

hs.alert.show("Hammerspoon ✅  ⌘⌃T=Teams ⌘⌃I=iTerm  ⌘⌃C/B=Chrome 左屏/右屏")
