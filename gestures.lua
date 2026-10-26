-- BentoSpaces: trackpad gestures for the io.github.jjnuthuagen.bentospaces shell plugin.
--
-- Loaded from ~/.config/hypr/input.lua. Settings are written by the plugin to
-- ~/.local/state/omarchy/bentospaces.conf as plain key=value lines, which are
-- parsed, never executed. The plugin calls BentoSpaces.reload() through
-- `hyprctl eval` after each change, so a settings tweak never needs a full
-- Hyprland reload.
--
-- Hyprland allows one gesture per finger count and direction, so the set is
-- swapped while Mission Control (layer "bentospaces-expose") is on screen:
-- then down closes it; otherwise left/right is the 1:1 workspace swipe and up
-- opens Mission Control. Shift + left/right carries the focused window to the
-- neighbouring workspace; gestures with modifiers are matched separately.
--
-- Workspaces 1..showUpTo always exist (persistent rules), so swipes and the
-- bar agree on them. Past the last one, a new workspace is made only when
-- every workspace already has a window; until then the empty ones are used.
--
-- Derived from Swipe Control (io.github.workingtitle.gestures, MIT).

local M = {}

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.local/state/omarchy/bentospaces.conf"
local EXPOSE_NAMESPACE = "bentospaces-expose"
local IPC = "omarchy-shell -q io.github.jjnuthuagen.bentospaces "

local DEFAULTS = {
  threeFingers = true,
  fourFingers = false,
  workspaceSwipe = true,
  shortSwipe = true,
  stopAtLastWorkspace = true,
  swipeUpExpose = true,
  windowSwipe = true,
  pinchFullscreen = true,
  pinchMaximize = false,
  resizeOnEdges = true,
  showUpTo = 6,
}

local registered = {}
local open_exposes = {}
local mode = "normal"

local function load_settings()
  local settings = {}
  for key, value in pairs(DEFAULTS) do settings[key] = value end

  local file = io.open(SETTINGS_PATH, "r")
  if file then
    for line in file:lines() do
      local key, raw = line:match("^%s*([%a_]+)%s*=%s*(%S+)%s*$")
      if key and type(DEFAULTS[key]) == "boolean" and (raw == "true" or raw == "false") then
        settings[key] = raw == "true"
      elseif key and type(DEFAULTS[key]) == "number" and tonumber(raw) then
        settings[key] = math.floor(tonumber(raw))
      end
    end
    file:close()
  end

  if not settings.threeFingers and not settings.fourFingers then settings.threeFingers = true end
  return settings
end

local function run(cmd)
  return function() hl.dispatch(hl.dsp.exec_cmd(cmd)) end
end

-- Windows per regular workspace, and the highest id in use. A window the
-- titlebars plugin minimised to special:minimized-N counts for workspace N.
local function occupancy()
  local show = M.settings and M.settings.showUpTo or DEFAULTS.showUpTo
  local counts, highest = {}, show
  for id = 1, show do counts[id] = 0 end
  for _, ws in ipairs(hl.get_workspaces()) do
    local home = ws.id >= 1 and ws.id or tonumber(tostring(ws.name):match("^special:minimized%-(%d+)$"))
    if home then
      counts[home] = (counts[home] or 0) + (ws.windows or 0)
      highest = math.max(highest, home)
    end
  end
  return counts, highest
end

local function all_populated(counts, highest)
  for id = 1, highest do
    if (counts[id] or 0) == 0 then return false end
  end
  return true
end

-- The workspace beside the active one in the direction given. Past the last
-- one only when every workspace has a window — then it is a fresh one.
local function neighbour_workspace(direction)
  local active = hl.get_active_workspace()
  if not active or active.id < 1 then return nil end
  local target = active.id + direction
  if target < 1 then return nil end
  local counts, highest = occupancy()
  if target <= highest or all_populated(counts, highest) then return target end
  return nil
end

-- Where a window goes when it is minimised: the next empty workspace after
-- `from`, else the first empty one before it, else a fresh one past the last.
function M.next_empty(from)
  local counts, highest = occupancy()
  for id = from + 1, highest do
    if (counts[id] or 0) == 0 then return id end
  end
  for id = 1, from - 1 do
    if (counts[id] or 0) == 0 then return id end
  end
  return highest + 1
end

-- SUPER + CTRL + LEFT/RIGHT: the neighbouring workspace, by the same rule.
function M.step(direction)
  local target = neighbour_workspace(direction)
  if target then hl.dispatch(hl.dsp.focus({ workspace = tostring(target) })) end
end

-- The 1:1 swipe may make a new workspace past the last only while every
-- workspace has a window (or always, with stopAtLastWorkspace off).
local function update_swipe_create()
  if not M.settings then return end
  local counts, highest = occupancy()
  hl.config({ gestures = { workspace_swipe_create_new = not M.settings.stopAtLastWorkspace or all_populated(counts, highest) } })
end

local persistent_rules = {}

local function set_persistent(count)
  for id, rule in pairs(persistent_rules) do rule:set_enabled(id <= count) end
  for id = 1, count do
    if not persistent_rules[id] then
      persistent_rules[id] = hl.workspace_rule({ workspace = tostring(id), persistent = true })
    end
  end
end

local function move_window(direction)
  return function()
    if not hl.get_active_window() then return end
    local target = neighbour_workspace(direction)
    if target then hl.dispatch(hl.dsp.window.move({ workspace = tostring(target) })) end
  end
end

-- Only gestures this file added are unset: Hyprland rejects unsetting one that
-- does not exist, and a user's own gestures on other finger counts stay put.
local function add(fingers, direction, action, mods, extra)
  local spec = { fingers = fingers, direction = direction, action = action, mods = mods }
  for key, value in pairs(extra or {}) do spec[key] = value end
  hl.gesture(spec)
  table.insert(registered, { fingers = fingers, direction = direction, mods = mods })
end

local function clear()
  for _, g in ipairs(registered) do
    hl.gesture({ fingers = g.fingers, direction = g.direction, action = "unset", mods = g.mods })
  end
  registered = {}
end

-- Whether the focused window is fullscreen or maximized right now.
local active_fullscreen = false

local function current_fullscreen()
  local window = hl.get_active_window()
  return window ~= nil and (tonumber(window.fullscreen) or 0) ~= 0
end

-- The whole gesture set for one finger count; three and four fingers can both
-- be on, and then each gets its own copy.
local function apply_fingers(f, s)
  -- The window is dragged along with the fingers, so fingers right carries it
  -- to the workspace on the right.
  if s.windowSwipe then
    add(f, "right", move_window(1), "SHIFT")
    add(f, "left", move_window(-1), "SHIFT")
  end

  -- Spread to go fullscreen, pinch to come back. Hyprland's fullscreen gesture
  -- only toggles, so only the direction that fits the focused window is
  -- registered. "pinchin" is fingers spreading (scale above 1).
  if s.pinchFullscreen and mode ~= "expose" then
    add(f, active_fullscreen and "pinchout" or "pinchin", "fullscreen", nil,
      { mode = s.pinchMaximize and "maximize" or "fullscreen" })
  end

  if s.workspaceSwipe then add(f, "horizontal", "workspace") end

  if mode == "expose" then
    add(f, "down", run(IPC .. "closeExpose"))
  elseif s.swipeUpExpose then
    add(f, "up", run(IPC .. "expose"))
  end
end

local function apply()
  clear()
  active_fullscreen = current_fullscreen()

  local s = M.settings
  update_swipe_create()

  if s.threeFingers then apply_fingers(3, s) end
  if s.fourFingers then apply_fingers(4, s) end
end

-- Omarchy turns blur off globally, and a layer rule cannot blur on its own, so
-- blur is switched on only while Mission Control is on screen and the user's
-- values are put back afterwards.
local EXPOSE_BLUR = { enabled = true, size = 10, passes = 3 }
local saved_blur

local function set_expose_blur(on)
  if on and not saved_blur then
    saved_blur = {}
    for key in pairs(EXPOSE_BLUR) do saved_blur[key] = hl.get_config("decoration.blur." .. key) end
    hl.config({ decoration = { blur = EXPOSE_BLUR } })
  elseif not on and saved_blur then
    hl.config({ decoration = { blur = saved_blur } })
    saved_blur = nil
  end
end

local function update_mode()
  local next_mode = next(open_exposes) and "expose" or "normal"
  if next_mode == mode then return end
  mode = next_mode
  set_expose_blur(mode == "expose")
  apply()
end

-- For `hyprctl repl 'return BentoSpaces.describe()'`.
function M.describe()
  local parts = {}
  for _, g in ipairs(registered) do table.insert(parts, g.fingers .. ":" .. (g.mods and g.mods .. "+" or "") .. g.direction) end
  return mode .. " " .. table.concat(parts, ",")
end

-- Resize windows by dragging their edges and corners, as on macOS. Omarchy
-- turns this off; while the setting is on, it is switched on with a grab zone
-- wide enough to hit the edge inside the gap, and switching the setting off
-- puts the previous values back and stops the cursor watch.
local EDGE_GRAB_AREA = 20
-- Hyprland's corner zone: rounding + border + 10 px, and Omarchy has no
-- rounding.
local EDGE_CORNER = 12
-- A tiled edge this close to the usable area's border sits against the
-- screen edge or the bar and has nothing to trade space with.
local EDGE_SCREEN_TOLERANCE = 40
local saved_edges
local edge_icon
local edge_timer
local edge_grab = EDGE_GRAB_AREA

local function xy(v)
  if type(v) ~= "table" then return 0, 0 end
  return v.x or v[1] or 0, v.y or v[2] or 0
end

-- The windows of the workspace under the pointer, kept between pointer
-- moves: listing every window 25 times a second while the pointer moves is
-- the costly part. Window events drop the list, and it is re-read anyway
-- every EDGE_CACHE_TICKS ticks so a drag-resize is picked up.
local EDGE_CACHE_TICKS = 12
local edge_windows, edge_windows_ws, edge_ticks = nil, nil, 0

local function workspace_windows(workspace)
  edge_ticks = edge_ticks + 1
  if edge_windows and edge_windows_ws == workspace.id and edge_ticks < EDGE_CACHE_TICKS then
    return edge_windows
  end
  local list = {}
  for _, w in ipairs(hl.get_windows()) do
    if w.mapped and not w.hidden and w.workspace and w.workspace.id == workspace.id then
      local x, y = xy(w.at)
      local width, height = xy(w.size)
      list[#list + 1] = { floating = w.floating, x = x, y = y, w = width, h = height }
    end
  end
  edge_windows, edge_windows_ws, edge_ticks = list, workspace.id, 0
  return list
end

local function forget_edge_windows() edge_windows = nil end

-- Hyprland shows the resize cursor on every edge, also where a tiled window
-- touches the screen and cannot be resized. Whether the cursor is on such an
-- edge decides if the resize cursor may show.
local function edge_icon_allowed(cursor)
  local monitor = hl.get_monitor_at_cursor()
  if not cursor or not monitor then return true end

  local workspace = monitor.active_workspace
  if not workspace then return true end
  local scale = monitor.scale or 1
  local reserved = type(monitor.reserved) == "table" and monitor.reserved or {}
  local area = {
    l = monitor.x + (reserved.left or 0),
    t = monitor.y + (reserved.top or 0),
    r = monitor.x + monitor.width / scale - (reserved.right or 0),
    b = monitor.y + monitor.height / scale - (reserved.bottom or 0),
  }

  local cx, cy = cursor.x, cursor.y
  local found
  for _, w in ipairs(workspace_windows(workspace)) do
    if cx >= w.x - edge_grab and cx <= w.x + w.w + edge_grab and cy >= w.y - edge_grab and cy <= w.y + w.h + edge_grab then
      if not found or (w.floating and not found.floating) then found = w end
    end
  end
  if not found or found.floating then return true end

  local f = found
  if cx >= f.x and cx <= f.x + f.w and cy >= f.y and cy <= f.y + f.h then return true end

  local sides = {}
  if cx < f.x + EDGE_CORNER then sides.l = true elseif cx > f.x + f.w - EDGE_CORNER then sides.r = true end
  if cy < f.y + EDGE_CORNER then sides.t = true elseif cy > f.y + f.h - EDGE_CORNER then sides.b = true end

  local stuck = {
    l = f.x - area.l <= EDGE_SCREEN_TOLERANCE,
    r = area.r - (f.x + f.w) <= EDGE_SCREEN_TOLERANCE,
    t = f.y - area.t <= EDGE_SCREEN_TOLERANCE,
    b = area.b - (f.y + f.h) <= EDGE_SCREEN_TOLERANCE,
  }
  -- A corner counts as resizable when either of its sides is.
  for side in pairs(sides) do
    if not stuck[side] then return true end
  end
  return next(sides) == nil
end

local last_cursor

local function update_edge_icon()
  -- Nothing to decide while the pointer rests.
  local cursor = hl.get_cursor_pos()
  local key = cursor and (math.floor(cursor.x) .. "," .. math.floor(cursor.y)) or ""
  if key == last_cursor and edge_icon ~= nil then return end
  last_cursor = key

  local allowed = edge_icon_allowed(cursor)
  if allowed == edge_icon then return end
  edge_icon = allowed
  hl.config({ general = { hover_icon_on_border = allowed } })
end

local function set_resize_on_edges(on)
  if on then
    if not saved_edges then
      saved_edges = {
        resize_on_border = hl.get_config("general.resize_on_border"),
        extend_border_grab_area = hl.get_config("general.extend_border_grab_area"),
        hover_icon_on_border = hl.get_config("general.hover_icon_on_border"),
      }
    end
    hl.config({ general = {
      resize_on_border = true,
      extend_border_grab_area = math.max(tonumber(saved_edges.extend_border_grab_area) or 0, EDGE_GRAB_AREA),
    } })
    edge_grab = EDGE_GRAB_AREA + (tonumber(hl.get_config("general.border_size")) or 0)
    -- Only worth watching when the resize cursor is wanted at all.
    if saved_edges.hover_icon_on_border ~= false then
      edge_icon = nil
      if edge_timer then edge_timer:set_enabled(true)
      else edge_timer = hl.timer(update_edge_icon, { timeout = 40, type = "repeat" }) end
    end
  elseif saved_edges then
    if edge_timer then edge_timer:set_enabled(false) end
    edge_icon = nil
    hl.config({ general = saved_edges })
    saved_edges = nil
  end
end

-- On macOS a short flick is enough to move on to the next Space. Hyprland
-- snaps back unless the swipe covered half its distance or was fast; the short
-- swipe lowers both thresholds and puts the previous values back when off.
local SHORT_SWIPE = { workspace_swipe_cancel_ratio = 0.3, workspace_swipe_min_speed_to_force = 15 }
local saved_swipe

local function set_short_swipe(on)
  if on then
    if not saved_swipe then
      saved_swipe = {}
      for key in pairs(SHORT_SWIPE) do saved_swipe[key] = hl.get_config("gestures." .. key) end
    end
    hl.config({ gestures = SHORT_SWIPE })
  elseif saved_swipe then
    hl.config({ gestures = saved_swipe })
    saved_swipe = nil
  end
end

function M.reload()
  M.settings = load_settings()
  set_persistent(M.settings.showUpTo)
  set_short_swipe(M.settings.shortSwipe)
  set_resize_on_edges(M.settings.resizeOnEdges)
  apply()
end

-- The events alone can drift (a layer can close while the shell restarts, and
-- Hyprland reuses addresses), so shortly after each event the tracked set is
-- checked against the layers Hyprland actually has mapped.
local function reconcile()
  local present = {}
  for _, layer in ipairs(hl.get_layers({ namespace = EXPOSE_NAMESPACE })) do
    if layer.mapped ~= false then present[layer.address] = true end
  end
  open_exposes = present
  update_mode()
end

local function reconcile_soon()
  hl.timer(reconcile, { timeout = 150, type = "oneshot" })
end

-- Focus moving to another window, or a window entering or leaving fullscreen,
-- can flip which pinch direction fits.
local function refresh_pinch()
  if M.settings and M.settings.pinchFullscreen and current_fullscreen() ~= active_fullscreen then apply() end
end

hl.on("window.active", refresh_pinch)

-- Windows coming, going or moving change whether every workspace is in use.
-- Hyprland updates its counts after the event, so the check waits a moment.
local function update_swipe_create_soon()
  hl.timer(update_swipe_create, { timeout = 50, type = "oneshot" })
end
for _, event in ipairs({ "window.open", "window.close", "window.destroy", "window.move_to_workspace",
                         "workspace.created", "workspace.removed", "workspace.active" }) do
  hl.on(event, update_swipe_create_soon)
  hl.on(event, forget_edge_windows)
end
hl.on("window.fullscreen", forget_edge_windows)
hl.on("window.fullscreen", refresh_pinch)

hl.on("layer.opened", function(layer)
  if not layer or layer.namespace ~= EXPOSE_NAMESPACE then return end
  open_exposes[layer.address] = true
  update_mode()
  reconcile_soon()
end)

hl.on("layer.closed", function(layer)
  if not layer or layer.namespace ~= EXPOSE_NAMESPACE then return end
  open_exposes[layer.address] = nil
  update_mode()
  reconcile_soon()
end)

-- Blur what is behind Mission Control, and let it animate itself.
hl.layer_rule({ match = { namespace = EXPOSE_NAMESPACE }, blur = true, no_anim = true, animation = "none" })

M.reload()
-- Mission Control may already be open when Hyprland reloads.
reconcile_soon()

BentoSpaces = M
return M
