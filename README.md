# mac_apps_switch_tool

A tiny [Hammerspoon](https://www.hammerspoon.org/) config for fast app switching on macOS.

Bind one hotkey per app to wake/switch to it, plus a hotkey that shows **all
Chrome windows** as a large-thumbnail grid in a **fixed, stable order** (so you
build muscle memory instead of hunting through a constantly-reshuffling list).

## Hotkeys

| Shortcut | Action |
|----------|--------|
| `⌘⌃T` | Switch to **Teams** |
| `⌘⌃I` | Switch to **iTerm** |
| `⌘⌃C` | Switch to **Chrome** (its most-recently-used window) |
| `⌘⌃B` | Show **all Chrome windows** as a thumbnail grid (b = browser) |

Switching behavior (`⌘⌃T/I/C`): if the current frontmost window is in native
fullscreen, exit it first; then activate the target app, focus its
most-recently-used window, and (optionally) maximize it.

The Chrome grid (`⌘⌃B`): windows are sorted by window id (assigned at creation,
stable for the window's lifetime) so the order never changes between
invocations. Click a thumbnail or press number keys `1`–`9` to switch; `Esc`
cancels.

## Install

1. Install Hammerspoon:
   ```bash
   brew install --cask hammerspoon
   ```
2. Symlink (or copy) `init.lua` into place:
   ```bash
   ln -sf "$PWD/init.lua" ~/.hammerspoon/init.lua
   ```
3. Launch Hammerspoon and grant **two** permissions in
   *System Settings → Privacy & Security*:
   - **Accessibility** — required for global hotkeys and window control.
   - **Screen Recording** — required for the `⌘⌃B` thumbnails
     (`window:snapshot()`). Without it the grid still works but thumbnails are
     blank. Quit & relaunch Hammerspoon after granting.
4. Click the Hammerspoon menubar icon → **Reload Config** (and tick
   *Launch Hammerspoon at login*).

## Customize

- **Apps / keys**: edit the `APPS` table near the top of `init.lua`. Each entry
  is `{ key, bundle, maximize }`. Find an app's bundle id with
  `osascript -e 'id of app "App Name"'`.
- **Modifier keys**: change `MODS` (default `{"cmd", "ctrl"}`).
- **Grid size**: tweak `margin` / `gap` in the `⌘⌃B` block for bigger cells.

## Notes

- The `require("hs.ipc")` line at the top lets you drive Hammerspoon from the
  shell (`hs -c "hs.reload()"`), handy for reloading/diagnosing remotely.
- Tested on macOS with the new Teams (`com.microsoft.teams2`). For classic
  Teams use `com.microsoft.teams`.
