import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// BentoSpaces: workspaces in the bar, each a little box with a mini-map of its windows,
// plus the trackpad side (gestures.lua) and Mission Control (Expose.qml).
//
// In the bar: click a workspace to go there, click a window to focus it,
// middle-click a window to close it, drag a window onto another
// workspace to move the window, scroll to step through workspaces, hover for
// a live thumbnail, right-click for settings.
//
// Derived from Konospaces (konochi.konospaces, MIT) and Swipe Control
// (io.github.workingtitle.gestures, MIT).
BarWidget {
  id: root
  moduleName: "io.github.jjnuthuagen.bentospaces"

  readonly property real iconSize: Style.space(16)
  readonly property real iconSpacing: Style.space(3)

  // ---------------------------------------------------------------- settings

  // Workspaces 1..alwaysShowUpTo (6 by default) are always in the row, empty
  // or not; SUPER + 7..0 still reach the rest, which join the row once used.
  readonly property int alwaysShowUpTo: setting("alwaysShowUpTo", 6)
  readonly property bool hoverPreview: setting("hoverPreview", true) === true

  // Keys the Hyprland side reads, with their defaults. Written to a plain
  // key=value file that gestures.lua parses and never runs as code.
  readonly property var gestureDefaults: ({
    threeFingers: true,
    fourFingers: false,
    workspaceSwipe: true,
    shortSwipe: true,
    stopAtLastWorkspace: true,
    swipeUpExpose: true,
    windowSwipe: true,
    pinchFullscreen: true,
    pinchMaximize: false,
    resizeOnEdges: true
  })

  function currentSettings() {
    var out = { alwaysShowUpTo: alwaysShowUpTo, hoverPreview: hoverPreview, iconPack: iconPack }
    for (var key in gestureDefaults) out[key] = setting(key, gestureDefaults[key]) === true
    return out
  }

  function updateSetting(key, value) {
    var next = currentSettings()
    next[key] = value
    var shellApi = bar ? bar.shell : null
    if (shellApi && typeof shellApi.updateEntryInline === "function")
      shellApi.updateEntryInline(moduleName, next)
  }

  function hyprSettingsText() {
    var s = currentSettings()
    var text = "# Written by the BentoSpaces plugin (io.github.jjnuthuagen.bentospaces).\n"
    for (var key in gestureDefaults) text += key + "=" + s[key] + "\n"
    text += "showUpTo=" + s.alwaysShowUpTo + "\n"
    return text
  }

  // Every per-monitor instance sees the same settings, so writing an identical
  // file is skipped and Hyprland only reloads the gestures on a real change.
  function syncHyprSettings() {
    var text = hyprSettingsText()
    if (hyprSettingsFile.loaded && hyprSettingsFile.text() === text) return
    hyprSettingsFile.setText(text)
  }

  onSettingsChanged: { Qt.callLater(syncHyprSettings); injectPanel() }

  FileView {
    id: hyprSettingsFile
    property bool loaded: false
    path: Quickshell.env("HOME") + "/.local/state/omarchy/bentospaces.conf"
    atomicWrites: true
    printErrors: false
    onLoaded: { loaded = true; Qt.callLater(root.syncHyprSettings) }
    onLoadFailed: Qt.callLater(root.syncHyprSettings)
    // Reload only once the write has landed, or Hyprland reads the old file.
    onSaved: {
      hyprReload.running = false
      hyprReload.running = true
    }
  }

  Process {
    id: hyprReload
    command: ["hyprctl", "eval", "if BentoSpaces then BentoSpaces.reload() end"]
  }

  // ------------------------------------------------------- settings popup

  // The popup is only built the first time it is asked for.
  property bool openWhenLoaded: false
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() {
    if (panelLoader.item) panelLoader.item.open()
    else { openWhenLoaded = true; panelLoader.active = true }
  }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle(); else open() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = root
    if ("hostWidget" in t) t.hostWidget = root
  }

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: false
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(function() {
        root.injectPanel()
        if (root.openWhenLoaded) { root.openWhenLoaded = false; panelLoader.item.open() }
      })
    }
  }

  // ---------------------------------------------------------- Mission Control

  // One overlay per bar, so every monitor shows its own workspaces.
  Expose {
    id: expose
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    showUpTo: root.alwaysShowUpTo
    iconFor: root.windowIcon
  }

  readonly property var exposeOverlay: expose
  function showExpose() { expose.show() }
  function hideExpose() { expose.hide() }
  function toggleExposeHere() { expose.toggle() }

  // An IPC target routes to one instance; it relays to the bars on the other
  // monitors.
  IpcHandler {
    target: "io.github.jjnuthuagen.bentospaces"
    function expose(): void { root.broadcast("showExpose") }
    function closeExpose(): void { root.broadcast("hideExpose") }
    function toggleExpose(): void { root.broadcast("toggleExposeHere") }
    function settings(): void { root.toggle() }
    function describe(): string { return JSON.stringify(root.currentSettings()) }
    // What the mini-map knows about each window, for troubleshooting.
    function windows(): string {
      return JSON.stringify(Hyprland.toplevels.values.map(function(t) {
        var ipc = t.lastIpcObject || {}
        return { title: t.title, workspace: t.workspace ? t.workspace.id : null, at: ipc.at, size: ipc.size }
      }))
    }
  }

  // ------------------------------------------------------------ workspaces

  // Optional icon pack: the name of an icon theme under ~/.local/share/icons
  // (setting `iconPack`). Its scalable/apps icons are tried first, before
  // whatever Qt resolves from the system theme. Empty: the system theme only.
  readonly property string iconPack: setting("iconPack", "")
  readonly property string iconPackDir: Quickshell.env("HOME") + "/.local/share/icons/" + iconPack + "/scalable/apps"
  // Lowercased icon name -> absolute file path, read once at startup.
  property var iconPackIcons: ({})
  // Monitor name -> id of the special workspace open on it (0 for none).
  property var specialWorkspaces: ({})
  readonly property int focusedWorkspaceId: {
    var monitor = Hyprland.focusedMonitor
    var special = monitor ? specialWorkspaces[monitor.name] : 0
    return special || (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0)
  }

  // The starting state comes from what Quickshell already read from
  // Hyprland; after that, events keep it current without asking again.
  function readSpecialWorkspaces() {
    var special = ({})
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      var ipc = monitors[i].lastIpcObject || {}
      special[monitors[i].name] = ipc.specialWorkspace ? (ipc.specialWorkspace.id || 0) : 0
    }
    specialWorkspaces = special
  }

  Component.onCompleted: {
    if (iconPack) iconPackQuery.running = true
    readSpecialWorkspaces()
    Hyprland.refreshToplevels()
  }

  // Only events that can move, add or remove a window ask Quickshell to
  // re-read window geometry; focus, titles, layers and the like do not.
  readonly property var layoutEvents: ({
    openwindow: true, closewindow: true, movewindowv2: true, changefloatingmode: true,
    fullscreen: true, activewindowv2: true, moveworkspacev2: true, minimized: true
  })

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "activespecialv2") {
        // id,name,monitor — id and name are empty when the special closes.
        var parts = String(event.data).split(",")
        var monitor = parts[parts.length - 1]
        var next = Object.assign({}, root.specialWorkspaces)
        next[monitor] = parseInt(parts[0], 10) || 0
        root.specialWorkspaces = next
      } else if (event.name === "monitoraddedv2" || event.name === "monitorremovedv2") {
        Hyprland.refreshMonitors()
        Qt.callLater(root.readSpecialWorkspaces)
      }
      if (root.layoutEvents[event.name]) toplevelRefresh.restart()
    }
  }

  Process {
    id: iconPackQuery
    command: ["ls", root.iconPackDir]
    stdout: StdioCollector {
      onStreamFinished: {
        var plain = ({})
        var symbolic = ({})
        var files = String(text || "").split("\n")
        for (var i = 0; i < files.length; i++) {
          var file = files[i].trim()
          if (!file || !/\.svg$/.test(file)) continue
          var name = file.replace(/\.svg$/, "")
          var path = root.iconPackDir + "/" + file
          if (/-symbolic$/.test(name)) symbolic[name.replace(/-symbolic$/, "").toLowerCase()] = path
          else plain[name.toLowerCase()] = path
        }
        // The full-colour mark wins; -symbolic only fills the gaps.
        for (var key in symbolic) if (!plain[key]) plain[key] = symbolic[key]
        root.iconPackIcons = plain
      }
    }
  }

  function iconPackPath(name) {
    var key = String(name || "").toLowerCase()
    return key ? (root.iconPackIcons[key] || "") : ""
  }

  function webAppEntry(candidates, entries) {
    for (var i = 0; i < entries.length; i++) {
      var command = entries[i].execString || ""
      if (command.indexOf("omarchy-launch-webapp") === -1 && command.indexOf("--app=") === -1) continue
      var match = command.match(/https?:\/\/[^\s"']+/)
      if (!match) continue
      var address = match[0].replace(/^https?:\/\//, "")
      // Chromium uses host + '_' + path, then replaces '/' with '_'.
      if (address.indexOf("/") === -1) address += "/"
      var key = address.replace("/", "_/").replace(/\//g, "_")
      for (var j = 0; j < candidates.length; j++) {
        var candidate = String(candidates[j] || "")
        if (candidate.indexOf("chrome-" + key + "-") === 0 || candidate.indexOf("chromium-" + key + "-") === 0)
          return entries[i]
      }
    }
    return null
  }

  // Icon lookups walk every desktop entry, so each answer is kept per app:
  // a window refresh then costs a table read, not a search.
  property var iconCache: ({})
  onIconPackIconsChanged: iconCache = ({})

  function windowIcon(toplevel) {
    if (!toplevel) return ""
    var ipc = toplevel.lastIpcObject || {}
    var appId = toplevel.wayland ? toplevel.wayland.appId : ""
    var key = [appId, ipc.class, ipc.initialClass, appId || ipc.class ? "" : (ipc.initialTitle || toplevel.title)].join("|")
    var cached = iconCache[key]
    if (cached !== undefined) return cached
    var resolved = resolveIcon(toplevel, ipc, appId)
    iconCache[key] = resolved
    return resolved
  }

  function resolveIcon(toplevel, ipc, appId) {
    var candidates = [appId, ipc.class, ipc.initialClass]
    var entries = DesktopEntries.applications.values
    var entry = webAppEntry(candidates, entries)
    for (var i = 0; i < candidates.length && !entry; i++) {
      if (candidates[i]) entry = DesktopEntries.heuristicLookup(candidates[i])
    }
    // Some clients do not advertise an app ID or class.
    if (!entry && !appId && !ipc.class) {
      for (var j = 0; j < entries.length; j++) {
        if (entries[j].name === toplevel.title || entries[j].name === ipc.initialTitle) {
          entry = entries[j]
          break
        }
      }
    }
    var icon = entry ? entry.icon : (appId || ipc.class || "")
    if (icon.indexOf("/") === 0) return Util.fileUrl(icon)
    // The icon pack first — by the desktop entry's icon name, then by the
    // window's own class — before falling back to Qt's theme lookup.
    var packed = root.iconPackPath(icon)
    for (var k = 0; k < candidates.length && !packed; k++) packed = root.iconPackPath(candidates[k])
    if (packed) return Util.fileUrl(packed)
    var source = icon ? Quickshell.iconPath(icon, true) : ""
    return source || Quickshell.iconPath("application-x-executable")
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  // The Title Bars plugin (marcho78.titlebars) minimises a window
  // from workspace N to special:minimized-N. Those windows are drawn, faded,
  // on workspace N itself. Quickshell does not always carry the "special:"
  // prefix on these names.
  function minimizedHome(workspace) {
    var match = workspace ? String(workspace.name).match(/^(special:)?minimized-(-?\d+)$/) : null
    return match ? parseInt(match[2], 10) : null
  }

  function minimizedWindows(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (root.minimizedHome(values[i]) === id) return values[i].toplevels.values
    }
    return []
  }

  // The fixed range first, so the row keeps its shape as windows come and go;
  // anything else (specials, higher ids) still joins when live.
  readonly property var ids: {
    var out = []
    var values = Hyprland.workspaces.values
    for (var n = 1; n <= root.alwaysShowUpTo; n++) out.push(n)

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      // A per-workspace minimised store shows under its home, not on its own.
      var home = root.minimizedHome(values[i])
      if (home !== null) {
        if (values[i].toplevels.values.length > 0 && out.indexOf(home) === -1) out.push(home)
        continue
      }
      if (out.indexOf(id) !== -1) continue
      if (values[i].toplevels.values.length > 0 || id === root.focusedWorkspaceId) out.push(id)
    }

    out.sort(function(left, right) {
      if ((left < 0) !== (right < 0)) return left < 0 ? 1 : -1
      return left - right
    })
    return out
  }

  function dispatch(lua) { Hyprland.dispatch(lua) }

  // The window with keyboard focus, and only while you are on its workspace:
  // a toplevel's own `activated` stays set after you move to an empty
  // workspace, which would leave a window lit that is not selected.
  function isActive(toplevel) {
    return !!toplevel && toplevel === Hyprland.activeToplevel
      && !!toplevel.workspace && toplevel.workspace.id === root.focusedWorkspaceId
  }

  function windowSelector(toplevel) {
    var ipc = toplevel ? (toplevel.lastIpcObject || {}) : {}
    var address = String((toplevel && toplevel.address) || ipc.address || "")
    if (!address) return ""
    if (address.indexOf("0x") !== 0) address = "0x" + address
    return "address:" + address
  }

  // Focusing by address goes through Hyprland itself, so it works whatever
  // misc:focus_on_activate says. A minimised window comes back this way too:
  // the titlebars plugin watches window.active and moves it home.
  function activateWindow(toplevel) {
    var selector = windowSelector(toplevel)
    if (selector) dispatch("hl.dsp.focus({ window = " + JSON.stringify(selector) + " })")
  }

  function closeWindow(toplevel) {
    var selector = windowSelector(toplevel)
    if (selector) dispatch("hl.dsp.window.close({ window = " + JSON.stringify(selector) + " })")
  }

  function workspaceName(id) {
    var workspace = workspaceById(id)
    // A workspace Hyprland has not created yet has no entry to read a name
    // from — its number is the name, and going there creates it.
    return workspace ? (workspace.name || String(id)) : String(id)
  }

  function moveWindowTo(toplevel, id) {
    var selector = windowSelector(toplevel)
    if (!selector) return
    dispatch("hl.dsp.window.move({ workspace = " + JSON.stringify(workspaceName(id))
      + ", window = " + JSON.stringify(selector) + ", follow = false })")
  }

  function focusWorkspace(id) {
    var workspace = workspaceById(id)
    // The minimised group is a shelf, not a place to go — a press on it
    // restores the window that went there last.
    if (workspace && workspace.name === "special:minimized") {
      var minimised = workspace.toplevels.values
      if (minimised.length > 0) root.activateWindow(minimised[minimised.length - 1])
      return
    }
    var name = workspaceName(id)
    dispatch(name.indexOf("special:") === 0
      ? "hl.dsp.workspace.toggle_special(" + JSON.stringify(name.slice(8)) + ")"
      : "hl.dsp.focus({ workspace = " + JSON.stringify(name) + " })")
  }

  // Scroll steps through the regular workspaces shown in the row, and stops
  // at either end. A touchpad sends small deltas, so they add up first.
  property real wheelAccum: 0
  function scrollBy(delta) {
    wheelAccum += delta
    if (Math.abs(wheelAccum) < 120) return
    var direction = wheelAccum > 0 ? -1 : 1
    wheelAccum = 0
    var regular = ids.filter(function(id) { return id > 0 })
    var index = regular.indexOf(focusedWorkspaceId)
    var target = index < 0 ? regular[0] : regular[index + direction]
    if (target !== undefined) focusWorkspace(target)
  }

  // ------------------------------------------------------------- mini-map

  readonly property real mapHeight: Math.round(root.barSize * 0.66)
  readonly property real markGap: Style.space(2)
  // Space around each window inside the map, so neighbours read apart.
  readonly property real mapGap: 1

  function monitorOf(workspace) {
    return workspace && workspace.monitor ? workspace.monitor : Hyprland.focusedMonitor
  }

  function monitorSize(monitor) {
    var scale = monitor && monitor.scale ? monitor.scale : 1
    return { w: monitor ? monitor.width / scale : 1920, h: monitor ? monitor.height / scale : 1080 }
  }

  function mapWidthFor(workspace) {
    var size = monitorSize(monitorOf(workspace))
    return Math.round(mapHeight * size.w / Math.max(1, size.h))
  }

  // A workspace's windows as rectangles in a mapW x mapH box, laid out as
  // they really are. Omarchy parks pre-started terminals off screen; those
  // are left out.
  function mapRects(workspace, windows, mapW, mapH) {
    var monitor = monitorOf(workspace)
    var size = monitorSize(monitor)
    var ratio = mapW / Math.max(1, size.w)
    var mx = monitor ? monitor.x : 0
    var my = monitor ? monitor.y : 0
    var out = []
    var unknown = []
    for (var i = 0; i < windows.length; i++) {
      var t = windows[i]
      var ipc = t.lastIpcObject || {}
      if (ipc.hidden === true || ipc.mapped === false) continue
      if (!ipc.at || !ipc.size) { unknown.push(t); continue }
      var x0 = Math.max(0, ipc.at[0] - mx), y0 = Math.max(0, ipc.at[1] - my)
      var x1 = Math.min(size.w, ipc.at[0] - mx + ipc.size[0]), y1 = Math.min(size.h, ipc.at[1] - my + ipc.size[1])
      if (x1 <= x0 || y1 <= y0) continue
      out.push({ toplevel: t, floating: ipc.floating === true,
        x: x0 * ratio, y: y0 * ratio, w: (x1 - x0) * ratio, h: (y1 - y0) * ratio })
    }
    // Not described by Hyprland yet (just opened): share the box until the
    // next refresh.
    for (var j = 0; j < unknown.length; j++)
      out.push({ toplevel: unknown[j], floating: false,
        x: mapW * j / unknown.length, y: 0, w: mapW / unknown.length, h: mapH })
    // Tiled first, floating on top, the focused window last of all.
    out.sort(function(a, b) {
      return (a.floating - b.floating) || ((root.isActive(a.toplevel) ? 1 : 0) - (root.isActive(b.toplevel) ? 1 : 0))
    })
    return out
  }

  // Window geometry only reaches Quickshell on a refresh. The layout events
  // above ask for one, and so does pointing at the row (resizing a window
  // sends no event), with bursts folded into one.
  Timer {
    id: toplevelRefresh
    interval: 150
    onTriggered: Hyprland.refreshToplevels()
  }

  // Click focuses the window, middle-click closes it, and a drag carries it
  // to another workspace. Sits above the WidgetButton's own hit area.
  component WindowMouse: MouseArea {
    id: handle
    required property var toplevel
    property Item home: null
    property point pressPoint
    z: 10
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: root.dragWindow ? Qt.ClosedHandCursor : Qt.PointingHandCursor

    onPressed: function(mouse) { pressPoint = Qt.point(mouse.x, mouse.y) }
    onPositionChanged: function(mouse) {
      if (!(pressedButtons & Qt.LeftButton)) return
      if (!root.dragWindow && Math.hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) > 6)
        root.dragWindow = handle.toplevel
      if (root.dragWindow) root.dragPoint = mapToItem(root, mouse.x, mouse.y)
    }
    onReleased: function(mouse) {
      if (root.dragWindow) {
        var target = root.dropButton
        var dragged = root.dragWindow
        root.dragWindow = null
        if (target && target !== handle.home) root.moveWindowTo(dragged, target.modelData)
      } else if (mouse.button === Qt.MiddleButton) {
        root.closeWindow(handle.toplevel)
      } else if (mouse.button === Qt.LeftButton) {
        root.activateWindow(handle.toplevel)
      }
    }
    onCanceled: root.dragWindow = null
  }

  // ---------------------------------------------------------------- drag

  property var dragWindow: null
  property point dragPoint: Qt.point(0, 0)

  function buttonAt(point) {
    for (var i = 0; i < workspaceRepeater.count; i++) {
      var item = workspaceRepeater.itemAt(i)
      if (!item) continue
      var p = item.mapFromItem(root, point.x, point.y)
      if (p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= item.height) return item
    }
    return null
  }

  readonly property var dropButton: dragWindow ? buttonAt(dragPoint) : null

  // ---------------------------------------------------------- hover preview

  property var hoverButton: null
  property bool previewShown: false

  function setHovered(button, hovered) {
    if (hovered) {
      if (!hoverButton) toplevelRefresh.restart()
      hoverButton = button
      if (!previewShown) previewTimer.restart()
    } else if (hoverButton === button) {
      hoverButton = null
      previewLeave.restart()
    }
  }

  Timer {
    id: previewTimer
    interval: 350
    onTriggered: {
      if (!root.hoverButton) return
      Hyprland.refreshToplevels()
      root.previewShown = true
    }
  }

  // Moving between two workspace buttons briefly leaves both; the preview
  // only goes once the pointer has really left the row.
  Timer {
    id: previewLeave
    interval: 120
    onTriggered: if (!root.hoverButton) root.previewShown = false
  }

  // ------------------------------------------------------------------ layout

  readonly property real trailingGap: root.vertical || ids.length === 0 ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.ids.length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      id: workspaceRepeater
      model: root.ids

      WidgetButton {
        id: workspaceButton
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property var openWindows: workspace ? workspace.toplevels.values : []
        // Minimised windows ride along after the open ones.
        readonly property var minimizedWindows: root.minimizedWindows(modelData)
        readonly property var windows: openWindows.concat(minimizedWindows)
        readonly property bool occupied: windows.length > 0
        readonly property bool focused: root.focusedWorkspaceId === modelData
        // Minimised windows land on special:minimized. Its name is not worth
        // printing in the bar — faded icons say it better.
        readonly property bool minimized: !!workspace && workspace.name === "special:minimized"
        readonly property bool dropTarget: root.dropButton === workspaceButton
        // What the mini-map draws, and the faded icons after it: on the
        // shared minimised shelf everything is a faded icon.
        readonly property real mapWidth: root.mapWidthFor(workspace)
        readonly property var rects: minimized ? [] : root.mapRects(workspace, openWindows, mapWidth, root.mapHeight)
        readonly property var shelf: minimized ? openWindows : minimizedWindows

        bar: root.bar
        text: workspace && workspace.name === "special:scratchpad" ? "S" : (workspace && workspace.name.indexOf("special:") === 0 ? workspace.name.slice(8) : (workspace ? workspace.name : String(modelData)))
        labelVisible: false
        // The hover preview carries the titles; the plain tooltip is only for
        // workspaces it does not cover.
        tooltipText: root.hoverPreview && occupied ? "" : (minimized
          ? windows.map(function(window) { return window.title }).join("\n") + "\nClick an icon to restore it"
          : "Workspace " + text)
        opacity: 1
        horizontalMargin: 2.5
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Math.max(Style.space(20), content.implicitWidth + scaledHorizontalMargin * 2)
        fixedHeight: root.vertical ? Math.max(root.barSize, content.implicitHeight + scaledVerticalPadding * 2) : root.barSize
        onPressed: function(button) {
          if (button === Qt.RightButton) root.toggle()
          else if (button === Qt.LeftButton) root.focusWorkspace(modelData)
        }
        onWheelMoved: function(delta) { root.scrollBy(delta) }

        HoverHandler {
          onHoveredChanged: root.setHovered(workspaceButton, hovered)
        }

        // Where a dragged icon would land.
        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          radius: Style.cornerRadius
          color: Color.accent
          opacity: workspaceButton.dropTarget ? 0.18 : 0
          Behavior on opacity { NumberAnimation { duration: 100 } }
        }

        GridLayout {
          id: content
          anchors.centerIn: parent
          // Nudged away from the edge the accent mark sits on, so the mark
          // and the box keep a gap between them.
          anchors.verticalCenterOffset: root.vertical ? 0 : (root.bar && root.bar.position === "top" ? -root.markGap : root.markGap)
          anchors.horizontalCenterOffset: !root.vertical ? 0 : (root.bar && root.bar.position === "left" ? -root.markGap : root.markGap)
          columns: root.vertical ? 1 : 3
          columnSpacing: Style.space(5)
          rowSpacing: Style.space(4)

          Text {
            // A workspace with a mini-map wears its number as a badge in the
            // map's corner instead. No label for the minimised shelf once it
            // holds windows; its icons carry the meaning.
            visible: !mapBox.visible && !(workspaceButton.minimized && workspaceButton.occupied)
            text: workspaceButton.text
            color: workspaceButton.foreground
            // Three steps: here, has windows, empty.
            opacity: workspaceButton.focused ? 1 : (workspaceButton.occupied ? 0.7 : 0.35)
            font.family: workspaceButton.fontFamily
            font.pixelSize: workspaceButton.fontSize
            font.bold: workspaceButton.focused
            renderType: Text.NativeRendering
            Layout.alignment: Qt.AlignCenter
            Behavior on opacity { NumberAnimation { duration: 160 } }
          }

          // The mini-map: the workspace as a tiny screen, its windows drawn
          // where they really are, each with its app icon. Empty workspaces
          // get the same box, so every workspace takes the same space.
          Item {
            id: mapBox
            visible: !workspaceButton.minimized
            implicitWidth: workspaceButton.mapWidth
            implicitHeight: root.mapHeight
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: implicitHeight
            Layout.alignment: Qt.AlignCenter

            Rectangle {
              anchors.fill: parent
              radius: Style.space(3)
              color: Qt.rgba(workspaceButton.foreground.r, workspaceButton.foreground.g, workspaceButton.foreground.b, 0.05)
              border.width: 1
              // The accent stroke above is the selection mark; the box only
              // brightens, so there is one accent stroke, as on other widgets.
              border.color: Qt.rgba(workspaceButton.foreground.r, workspaceButton.foreground.g, workspaceButton.foreground.b,
                workspaceButton.focused ? 0.6 : 0.3)
              Behavior on border.color { ColorAnimation { duration: 160 } }
            }

            Repeater {
              model: workspaceButton.rects

              Rectangle {
                id: winRect
                required property var modelData
                readonly property var toplevel: modelData.toplevel
                readonly property bool active: root.isActive(toplevel)
                readonly property bool dragging: root.dragWindow === toplevel
                readonly property real iconSide: Math.min(root.iconSize, width - 2, height - 2)

                x: modelData.x + root.mapGap
                y: modelData.y + root.mapGap
                width: Math.max(2, modelData.w - root.mapGap * 2)
                height: Math.max(2, modelData.h - root.mapGap * 2)
                radius: Style.space(2)
                color: active ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.3)
                  : Qt.rgba(workspaceButton.foreground.r, workspaceButton.foreground.g, workspaceButton.foreground.b,
                      winMouse.containsMouse ? 0.3 : 0.14)
                border.width: 1
                border.color: active ? Color.accent
                  : Qt.rgba(workspaceButton.foreground.r, workspaceButton.foreground.g, workspaceButton.foreground.b, 0.35)
                opacity: dragging ? 0.3 : 1

                Image {
                  anchors.centerIn: parent
                  visible: winRect.iconSide >= 6
                  width: winRect.iconSide
                  height: winRect.iconSide
                  source: root.windowIcon(winRect.toplevel)
                  sourceSize.width: root.iconSize
                  sourceSize.height: root.iconSize
                  fillMode: Image.PreserveAspectFit
                  // Idle windows dim; the icon pack is already monochrome, so
                  // no per-icon effect layer is needed.
                  opacity: winRect.active ? 1 : 0.55
                }

                WindowMouse {
                  id: winMouse
                  anchors.fill: parent
                  toplevel: winRect.toplevel
                  home: workspaceButton
                }
              }
            }

            // An empty workspace shows its number in the middle of the box.
            Text {
              visible: workspaceButton.rects.length === 0
              anchors.centerIn: parent
              text: workspaceButton.text
              color: workspaceButton.focused ? Color.accent : workspaceButton.foreground
              opacity: workspaceButton.focused ? 1 : 0.45
              font.family: workspaceButton.fontFamily
              font.pixelSize: Math.round(workspaceButton.fontSize * 0.85)
              font.bold: workspaceButton.focused
              renderType: Text.NativeRendering
            }

            // The workspace number, tucked into the top-left corner over the
            // windows. It takes no clicks, so the window under it still does.
            Rectangle {
              visible: workspaceButton.rects.length > 0
              x: 1
              y: 1
              z: 20
              width: Math.max(height, badgeText.implicitWidth + Style.space(3))
              height: Math.round(badgeText.implicitHeight * 0.85)
              radius: Style.space(2)
              color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.85)

              Text {
                id: badgeText
                anchors.centerIn: parent
                text: workspaceButton.text
                color: workspaceButton.focused ? Color.accent : workspaceButton.foreground
                font.family: workspaceButton.fontFamily
                font.pixelSize: Math.max(7, Math.round(workspaceButton.fontSize * 0.55))
                font.bold: true
                renderType: Text.NativeRendering
              }
            }
          }

          // Minimised windows, faded, after the map; a click restores one.
          Item {
            visible: workspaceButton.shelf.length > 0
            implicitWidth: root.vertical ? root.iconSize : workspaceButton.shelf.length * (root.iconSize + root.iconSpacing) - root.iconSpacing
            implicitHeight: root.vertical ? workspaceButton.shelf.length * (root.iconSize + root.iconSpacing) - root.iconSpacing : root.iconSize
            Layout.preferredWidth: implicitWidth
            Layout.preferredHeight: implicitHeight
            Layout.alignment: Qt.AlignCenter

            Repeater {
              model: workspaceButton.shelf
              Image {
                id: shelfIcon
                required property var modelData
                required property int index
                x: root.vertical ? 0 : index * (root.iconSize + root.iconSpacing)
                y: root.vertical ? index * (root.iconSize + root.iconSpacing) : 0
                width: root.iconSize
                height: root.iconSize
                source: root.windowIcon(modelData)
                sourceSize.width: width
                sourceSize.height: height
                fillMode: Image.PreserveAspectFit
                opacity: root.dragWindow === modelData ? 0.15 : (shelfMouse.containsMouse ? 0.7 : 0.3)

                WindowMouse {
                  id: shelfMouse
                  anchors.fill: parent
                  anchors.margins: -root.iconSpacing / 2
                  toplevel: shelfIcon.modelData
                  home: workspaceButton
                }
              }
            }
          }
        }
      }
    }
  }

  // The bar's own accent mark, sliding to the focused workspace — the same
  // colour, thickness and inner-edge placement as the line the bar draws under
  // a widget with an open panel, so it overlines a bottom bar and underlines
  // a top one.
  Rectangle {
    id: marker
    readonly property Item target: {
      var focused = root.focusedWorkspaceId
      for (var i = 0; i < workspaceRepeater.count; i++) {
        var item = workspaceRepeater.itemAt(i)
        if (item && item.modelData === focused) return item
      }
      return null
    }
    readonly property int inset: Style.space(2)
    // The length the bar gives the open-panel mark on an icon widget, so the
    // two strokes match exactly whatever width a workspace's map has.
    readonly property real extent: target
      ? Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55)) : 0
    // No slide on the first placement, only on later moves.
    property bool settled: false

    visible: target !== null
    color: Color.accent
    opacity: 0.9
    radius: Math.min(width, height) / 2
    width: root.vertical ? Style.space(2) : extent
    height: root.vertical ? extent : Style.space(2)
    x: !target ? 0 : root.vertical
      ? (root.bar && root.bar.position === "left" ? target.width - width - inset : inset)
      : target.x + Math.floor((target.width - width) / 2)
    y: !target ? 0 : root.vertical
      ? target.y + Math.floor((target.height - height) / 2)
      : (root.bar && root.bar.position === "top" ? target.height - height - inset : inset)
    z: 50

    Behavior on x { enabled: marker.settled; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: marker.settled; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: marker.settled; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: marker.settled; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    Timer { running: true; interval: 400; onTriggered: marker.settled = true }
  }

  // The icon being dragged, following the pointer.
  Image {
    visible: root.dragWindow !== null
    source: root.dragWindow ? root.windowIcon(root.dragWindow) : ""
    width: root.iconSize * 1.25
    height: width
    sourceSize.width: width
    sourceSize.height: height
    x: root.dragPoint.x - width / 2
    y: root.dragPoint.y - height / 2
    z: 100
  }

  PopupWindow {
    id: previewWindow

    readonly property var button: root.hoverButton
    readonly property var workspace: button ? button.workspace : null
    readonly property var windows: button ? button.openWindows : []
    readonly property var minimized: button ? button.minimizedWindows : []
    readonly property var monitor: workspace && workspace.monitor ? workspace.monitor
      : (Hyprland.focusedMonitor || null)
    readonly property real monitorScale: monitor && monitor.scale ? monitor.scale : 1
    readonly property real monitorWidth: monitor ? monitor.width / monitorScale : 1920
    readonly property real monitorHeight: monitor ? monitor.height / monitorScale : 1080
    readonly property real thumbWidth: Style.space(240)
    readonly property real ratio: thumbWidth / Math.max(1, monitorWidth)

    visible: root.hoverPreview && root.previewShown && button !== null && button.occupied
      && root.dragWindow === null && !root.opened && !!root.QsWindow.window
    color: "transparent"
    implicitWidth: Math.ceil(card.implicitWidth)
    implicitHeight: Math.ceil(card.implicitHeight)

    function geometry(toplevel) {
      var ipc = toplevel.lastIpcObject || {}
      var at = ipc.at || [0, 0]
      var size = ipc.size || [0, 0]
      var mx = monitor ? monitor.x : 0
      var my = monitor ? monitor.y : 0
      return { x: at[0] - mx, y: at[1] - my, w: Math.max(1, size[0]), h: Math.max(1, size[1]) }
    }

    anchor {
      id: previewAnchor
      window: root.QsWindow.window
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        var target = previewWindow.button
        var window = root.QsWindow.window
        if (!target || !window) return
        var w = previewWindow.implicitWidth
        var h = previewWindow.implicitHeight
        var position = root.bar ? root.bar.position : "top"
        var localX = target.width / 2 - w / 2
        var localY = target.height + 6
        if (position === "bottom") localY = -h - 6
        else if (position === "left") { localX = target.width + 6; localY = target.height / 2 - h / 2 }
        else if (position === "right") { localX = -w - 6; localY = target.height / 2 - h / 2 }
        var point = window.contentItem.mapFromItem(target, localX, localY)
        previewAnchor.rect.x = Math.round(point.x)
        previewAnchor.rect.y = Math.round(point.y)
      }
    }

    // Follow the pointer from one workspace to the next.
    onButtonChanged: if (visible) previewAnchor.updateAnchor()

    Rectangle {
      id: card
      readonly property real pad: Style.space(8)
      implicitWidth: previewWindow.thumbWidth + pad * 2
      implicitHeight: column.implicitHeight + pad * 2
      radius: Style.cornerRadius
      color: Color.tooltip.background
      border.width: 1
      border.color: Color.tooltip.border

      Column {
        id: column
        x: card.pad
        y: card.pad
        width: previewWindow.thumbWidth
        spacing: Style.space(6)

        // The workspace as it sits on its monitor, one live capture per window.
        Rectangle {
          visible: previewWindow.windows.length > 0 && !(previewWindow.button && previewWindow.button.minimized)
          width: previewWindow.thumbWidth
          height: Math.round(previewWindow.monitorHeight * previewWindow.ratio)
          radius: Style.cornerRadius
          color: Color.background
          clip: true

          Repeater {
            model: previewWindow.visible ? previewWindow.windows : []
            delegate: ScreencopyView {
              required property var modelData
              readonly property var g: previewWindow.geometry(modelData)
              x: g.x * previewWindow.ratio
              y: g.y * previewWindow.ratio
              width: g.w * previewWindow.ratio
              height: g.h * previewWindow.ratio
              captureSource: modelData.wayland
              // One snapshot when the preview opens; a live stream would
              // re-capture every window each frame.
              live: false
            }
          }
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: previewWindow.button ? (previewWindow.button.minimized ? "Minimised" : "Workspace " + previewWindow.button.text) : ""
          color: Color.tooltip.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Repeater {
          model: previewWindow.windows.concat(previewWindow.minimized).slice(0, 6)
          delegate: Text {
            required property var modelData
            required property int index
            width: column.width
            elide: Text.ElideRight
            text: modelData.title + (index >= previewWindow.windows.length ? "  (minimised)" : "")
            color: Color.tooltip.text
            opacity: root.isActive(modelData) ? 1 : 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
