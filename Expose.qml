import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Mission Control for one monitor: the monitor's workspaces as a strip of
// thumbnails along the top — 1..showUpTo always, empty or not, then a "+" for
// a new one once all are in use — and the windows of the active workspace spread
// out below with live previews. Click a window to focus it, click a workspace
// to switch to it, or drag a window onto a workspace (or "+") to move it there.
//
// gestures.lua recognises the layer namespace below: while it is on screen,
// swiping down closes it instead of opening a bar popup.
Scope {
  id: root

  property var screen: null
  property bool open: false
  // Drives the enter/leave animation separately from `open`, so the window
  // tiles can glide back to their real positions before the layer unmaps.
  property bool shown: false
  property int selected: -1
  // Workspaces 1..showUpTo are always in the strip; set by the bar widget.
  property int showUpTo: 6
  // toplevel -> icon url; the bar widget's resolver, so both match.
  property var iconFor: null

  readonly property var monitor: screen ? Hyprland.monitorFor(screen) : null
  readonly property var activeWorkspace: monitor ? monitor.activeWorkspace : null
  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property int animationMs: 220

  function show() {
    if (open) return
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    selected = -1
    shown = false
    open = true
    Qt.callLater(function() { root.shown = true })
  }

  function hide() {
    if (!open || !shown) return
    shown = false
    unmapTimer.restart()
  }

  function toggle() { open && shown ? hide() : show() }

  Timer {
    id: unmapTimer
    interval: root.animationMs
    onTriggered: root.open = false
  }

  function dispatch(lua) { Hyprland.dispatch(lua) }

  function focusWindow(toplevel) {
    dispatch("hl.dsp.focus({ window = \"address:0x" + toplevel.address + "\" })")
    hide()
  }

  // Going to a workspace that does not exist yet creates it.
  function focusWorkspace(id) {
    dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
    hide()
  }

  // Switches the workspace shown without leaving Mission Control. Stops at
  // either end of the strip, before the "+".
  function stepWorkspace(delta) {
    var ids = slots.filter(function(s) { return !s.isNew }).map(function(s) { return s.id })
    var index = ids.indexOf(activeId)
    var target = ids[index + delta]
    if (index < 0 || target === undefined) return
    selected = -1
    dispatch("hl.dsp.focus({ workspace = \"" + target + "\" })")
  }

  // Moved by address, so focus stays put. The overlay stays open, and the
  // tile leaves the grid once Hyprland reports the move. A workspace that does
  // not exist yet is created by the move.
  function moveWindow(toplevel, id) {
    if (!toplevel.workspace || toplevel.workspace.id === id) return
    dispatch("hl.dsp.window.move({ workspace = \"" + id + "\", window = \"address:0x"
      + toplevel.address + "\", follow = false })")
    Qt.callLater(Hyprland.refreshToplevels)
  }

  // ------------------------------------------------------------------ model

  readonly property int activeId: activeWorkspace ? activeWorkspace.id : 0

  // The strip: { id, workspace (null until Hyprland creates it), isNew }.
  // 1..showUpTo always, minus any living on another monitor, plus whatever
  // else this monitor has, then one "+" past the highest id in use.
  readonly property var slots: {
    var here = ({})
    var elsewhere = ({})
    var highest = showUpTo
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      var ws = all[i]
      if (ws.id < 1) continue
      if (ws.monitor === root.monitor) here[ws.id] = ws
      else elsewhere[ws.id] = true
      highest = Math.max(highest, ws.id)
    }
    var ids = []
    for (var n = 1; n <= showUpTo; n++) if (!elsewhere[n]) ids.push(n)
    for (var key in here) if (ids.indexOf(Number(key)) === -1) ids.push(Number(key))
    ids.sort(function(a, b) { return a - b })
    var list = ids.map(function(id) { return { id: id, workspace: here[id] || null, isNew: false } })
    // A new workspace only once every one has a window; until then, drop on
    // an empty one.
    var full = list.every(function(slot) { return slot.workspace && slot.workspace.toplevels.values.length > 0 })
    if (full) list.push({ id: highest + 1, workspace: null, isNew: true })
    return list
  }

  function geometry(toplevel) {
    var ipc = toplevel.lastIpcObject || {}
    var at = ipc.at || [0, 0]
    var size = ipc.size || [0, 0]
    var mx = monitor ? monitor.x : 0
    var my = monitor ? monitor.y : 0
    return { x: at[0] - mx, y: at[1] - my, w: Math.max(1, size[0]), h: Math.max(1, size[1]) }
  }

  // Only windows that show at least partly on the monitor, as in Mission
  // Control. Omarchy parks pre-started terminals far off screen; they would
  // take grid slots and show nothing.
  function onScreen(toplevel) {
    var g = geometry(toplevel)
    var scale = monitor && monitor.scale ? monitor.scale : 1
    var width = monitor ? monitor.width / scale : 0
    var height = monitor ? monitor.height / scale : 0
    if (width <= 0 || height <= 0) return true
    return g.x + g.w > 0 && g.y + g.h > 0 && g.x < width && g.y < height
  }

  function windowsOf(workspace) {
    if (!workspace) return []
    var list = []
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      var ipc = t.lastIpcObject || {}
      if (t.workspace === workspace && ipc.hidden !== true && ipc.mapped !== false && onScreen(t)) list.push(t)
    }
    // Reading order of the real layout, so the grid keeps the windows roughly
    // where they were.
    list.sort(function(a, b) {
      var ga = root.geometry(a), gb = root.geometry(b)
      var rowA = Math.round((ga.y + ga.h / 2) / 200), rowB = Math.round((gb.y + gb.h / 2) / 200)
      return rowA !== rowB ? rowA - rowB : (ga.x - gb.x)
    })
    return list
  }

  readonly property var windows: open ? windowsOf(activeWorkspace) : []

  // Rows of tiles that keep each window's aspect ratio. Every row count is
  // tried and the one covering the most area wins; windows are never scaled
  // up past their real size.
  function computeLayout(wins, W, H, gap) {
    var n = wins.length
    if (n === 0 || W <= 0 || H <= 0) return []
    var geos = wins.map(function(t) { return root.geometry(t) })
    var best = null

    for (var r = 1; r <= n; r++) {
      var per = Math.ceil(n / r)
      var rows = []
      for (var i = 0; i < n; i += per) rows.push(geos.slice(i, i + per).map(function(g, k) { return { g: g, index: i + k } }))
      var rowH = (H - gap * (rows.length - 1)) / rows.length
      var area = 0
      var laidRows = []
      for (var j = 0; j < rows.length; j++) {
        var row = rows[j]
        var natural = 0
        for (var k = 0; k < row.length; k++) natural += row[k].g.w / row[k].g.h * rowH
        var fit = Math.min(1, (W - gap * (row.length - 1)) / natural)
        var tiles = []
        var rowHeight = 0
        for (var m = 0; m < row.length; m++) {
          var g = row[m].g
          var h = Math.min(rowH * fit, g.h)
          var w = g.w / g.h * h
          tiles.push({ index: row[m].index, w: w, h: h })
          rowHeight = Math.max(rowHeight, h)
          area += w * h
        }
        laidRows.push({ tiles: tiles, height: rowHeight })
      }
      if (!best || area > best.area) best = { area: area, rows: laidRows }
    }

    var out = []
    var totalH = gap * (best.rows.length - 1)
    for (var a = 0; a < best.rows.length; a++) totalH += best.rows[a].height
    var y = (H - totalH) / 2
    for (var b = 0; b < best.rows.length; b++) {
      var lr = best.rows[b]
      var rowW = gap * (lr.tiles.length - 1)
      for (var c = 0; c < lr.tiles.length; c++) rowW += lr.tiles[c].w
      var x = (W - rowW) / 2
      for (var d = 0; d < lr.tiles.length; d++) {
        var t = lr.tiles[d]
        out[t.index] = { x: x, y: y + (lr.height - t.h) / 2, w: t.w, h: t.h }
        x += t.w + gap
      }
      y += lr.height + gap
    }
    return out
  }

  // ----------------------------------------------------------------- window

  PanelWindow {
    id: overlay
    visible: root.open
    screen: root.screen
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "bentospaces-expose"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property real stripHeight: Math.round(height * 0.14)
    readonly property real stripSpacing: Math.round(margin * 0.4)
    // Thumbnails shrink once there are too many workspaces to fit the strip
    // at full height, so the outer ones never run off the screen.
    readonly property real thumbHeight: {
      var n = Math.max(1, root.slots.length)
      var fitWidth = (width - margin * 2 - stripSpacing * (n - 1)) / n
      return Math.min(stripHeight, Math.floor(fitWidth * height / Math.max(1, width)))
    }
    readonly property real margin: Math.round(width * 0.04)
    readonly property rect gridArea: Qt.rect(margin, stripHeight + margin * 1.4,
      width - margin * 2, height - stripHeight - margin * 2.4)
    readonly property var layout: root.computeLayout(root.windows, gridArea.width, gridArea.height, Math.round(margin * 0.6))

    property var dragWindow: null
    property point dragPoint: Qt.point(0, 0)

    function workspaceAt(x, y) {
      for (var i = 0; i < strip.children.length; i++) {
        var thumb = strip.children[i]
        if (!thumb.slot) continue
        var p = thumb.mapFromItem(content, x, y)
        if (p.x >= 0 && p.y >= 0 && p.x <= thumb.width && p.y <= thumb.height) return thumb.slot
      }
      return null
    }

    Item {
      id: content
      anchors.fill: parent
      focus: true

      // Left/right walk the workspace strip, the other keys the windows of
      // the workspace shown. Enter focuses the picked window, or with none
      // picked closes Mission Control on the workspace shown.
      Keys.onPressed: function(event) {
        var n = root.windows.length
        var key = event.key
        if (key === Qt.Key_Escape) root.hide()
        else if (key === Qt.Key_Left || key === Qt.Key_H) root.stepWorkspace(-1)
        else if (key === Qt.Key_Right || key === Qt.Key_L) root.stepWorkspace(1)
        else if ((key === Qt.Key_Tab || key === Qt.Key_Down || key === Qt.Key_J) && n > 0)
          root.selected = (root.selected + 1) % n
        else if ((key === Qt.Key_Backtab || key === Qt.Key_Up || key === Qt.Key_K) && n > 0)
          root.selected = root.selected < 0 ? n - 1 : (root.selected - 1 + n) % n
        else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
          if (root.selected >= 0 && root.selected < n) root.focusWindow(root.windows[root.selected])
          else root.hide()
        }
        else return
        event.accepted = true
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.62)
        opacity: root.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
      }

      // A click on empty space closes Mission Control, like on macOS.
      MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
      }

      // ------------------------------------------------------- workspace strip

      Row {
        id: strip
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.shown ? overlay.margin * 0.5 : -overlay.stripHeight
        spacing: overlay.stripSpacing
        Behavior on y { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }

        Repeater {
          model: root.slots

          delegate: Item {
            id: thumb
            required property var modelData
            readonly property var slot: modelData
            readonly property var workspace: modelData.workspace
            readonly property bool active: !modelData.isNew && modelData.id === root.activeId
            readonly property bool dropTarget: overlay.dragWindow !== null
              && overlay.workspaceAt(overlay.dragPoint.x, overlay.dragPoint.y) === modelData
            readonly property real ratio: height / Math.max(1, overlay.height)

            height: overlay.thumbHeight
            width: Math.round(height * overlay.width / Math.max(1, overlay.height))

            Rectangle {
              anchors.fill: parent
              color: Color.background
              radius: Style.cornerRadius
              clip: true
              border.width: thumb.active || thumb.dropTarget || thumbMouse.containsMouse ? 2 : 1
              border.color: thumb.active || thumb.dropTarget ? root.accent
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, thumbMouse.containsMouse ? 0.5 : 0.2)

              // The "+": drop a window here for a fresh workspace.
              Text {
                visible: thumb.slot.isNew
                anchors.centerIn: parent
                text: "+"
                color: thumb.dropTarget ? root.accent : root.foreground
                opacity: thumb.dropTarget || thumbMouse.containsMouse ? 1 : 0.5
                font.family: Style.font.family
                font.pixelSize: Math.round(parent.height * 0.45)
              }

              // Each window as a box with its capture and its app icon.
              Repeater {
                model: root.open ? root.windowsOf(thumb.workspace) : []
                delegate: Rectangle {
                  id: thumbWindow
                  required property var modelData
                  readonly property var g: root.geometry(modelData)
                  x: g.x * thumb.ratio + 1
                  y: g.y * thumb.ratio + 1
                  width: Math.max(2, g.w * thumb.ratio - 2)
                  height: Math.max(2, g.h * thumb.ratio - 2)
                  radius: 3
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                  border.width: 1
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)

                  ScreencopyView {
                    anchors.fill: parent
                    anchors.margins: 1
                    captureSource: thumbWindow.modelData.wayland
                    live: false
                  }

                  // The app icon over the bottom of the window, as on macOS; a
                  // window that has never been on screen captures blank, and
                  // this still says what it is.
                  Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Math.round(parent.height * 0.12)
                    width: Math.min(28, parent.width * 0.45, parent.height * 0.45)
                    height: width
                    source: root.iconFor ? root.iconFor(thumbWindow.modelData) : ""
                    sourceSize.width: 64
                    sourceSize.height: 64
                    fillMode: Image.PreserveAspectFit
                  }
                }
              }
            }

            Text {
              anchors.top: parent.bottom
              anchors.topMargin: 4
              anchors.horizontalCenter: parent.horizontalCenter
              text: thumb.slot.isNew ? "New" : (thumb.workspace ? (thumb.workspace.name || String(thumb.slot.id)) : String(thumb.slot.id))
              color: thumb.active ? root.accent : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: thumbMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.focusWorkspace(thumb.slot.id)
            }
          }
        }
      }

      // ---------------------------------------------------------- window grid

      Repeater {
        model: root.windows

        delegate: Item {
          id: tile
          required property var modelData
          required property int index
          readonly property var real: root.geometry(modelData)
          readonly property var slot: overlay.layout[index] || { x: real.x, y: real.y, w: real.w, h: real.h }
          readonly property bool hot: tileMouse.containsMouse || root.selected === index
          readonly property bool dragging: overlay.dragWindow === modelData

          x: root.shown ? overlay.gridArea.x + slot.x : real.x
          y: root.shown ? overlay.gridArea.y + slot.y : real.y
          width: root.shown ? slot.w : real.w
          height: root.shown ? slot.h : real.h
          opacity: dragging ? 0.35 : 1
          z: hot ? 2 : 1

          Behavior on x { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
          Behavior on y { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
          Behavior on width { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }

          ScreencopyView {
            id: preview
            anchors.fill: parent
            captureSource: tile.modelData.wayland
            // Live only while fully shown, not during the open/close glide.
            live: root.shown
          }

          Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            color: "transparent"
            radius: Style.cornerRadius
            border.width: 3
            border.color: root.accent
            visible: tile.hot && root.shown
          }

          Rectangle {
            visible: tile.hot && root.shown
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.bottom
            anchors.topMargin: 8
            width: Math.min(titleText.implicitWidth + 20, overlay.width * 0.4)
            height: titleText.implicitHeight + 8
            radius: height / 2
            color: Color.background

            Text {
              id: titleText
              anchors.centerIn: parent
              width: parent.width - 20
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: tile.modelData.title
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            property point pressPoint

            onEntered: root.selected = -1
            onPressed: function(mouse) { pressPoint = Qt.point(mouse.x, mouse.y) }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              if (!overlay.dragWindow && Math.hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) > 12)
                overlay.dragWindow = tile.modelData
              if (overlay.dragWindow) overlay.dragPoint = mapToItem(content, mouse.x, mouse.y)
            }
            onReleased: function(mouse) {
              if (overlay.dragWindow) {
                var target = overlay.workspaceAt(overlay.dragPoint.x, overlay.dragPoint.y)
                var dragged = overlay.dragWindow
                overlay.dragWindow = null
                if (target) root.moveWindow(dragged, target.id)
              } else {
                root.focusWindow(tile.modelData)
              }
            }
          }
        }
      }

      // The window being dragged, following the pointer at thumbnail size.
      ScreencopyView {
        visible: overlay.dragWindow !== null
        captureSource: overlay.dragWindow ? overlay.dragWindow.wayland : null
        live: false
        width: overlay.stripHeight * 1.2
        height: overlay.dragWindow ? width * root.geometry(overlay.dragWindow).h / root.geometry(overlay.dragWindow).w : 0
        x: overlay.dragPoint.x - width / 2
        y: overlay.dragPoint.y - height / 2
        z: 10
        opacity: 0.9
      }
    }
  }
}
