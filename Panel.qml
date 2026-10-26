import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// BentoSpaces settings, opened by right-clicking the workspaces in the bar. The
// bar widget (BentoSpaces.qml) owns IPC and mirrors these settings to Hyprland.
Panel {
  id: root
  moduleName: "io.github.jjnuthuagen.bentospaces"
  ipcTarget: "io.github.jjnuthuagen.bentospaces"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property int cursorIndex: -1
  // Which chip of a multi-select row the keyboard cursor is on.
  property int chipCursor: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function current() { return hostWidget ? hostWidget.currentSettings() : ({}) }
  function updateSetting(key, value) { if (hostWidget) hostWidget.updateSetting(key, value) }

  readonly property var rows: [
    { key: "fingers", kind: "multi", label: "Fingers",
      options: [{ value: "threeFingers", label: "Three" }, { value: "fourFingers", label: "Four" }] },
    { key: "workspaceSwipe", kind: "toggle", label: "Swipe between workspaces",
      description: "Follows your fingers" },
    { key: "shortSwipe", kind: "choice", label: "Switch after",
      options: [{ value: "short", label: "Short swipe" }, { value: "half", label: "Halfway" }] },
    { key: "stopAtLastWorkspace", kind: "toggle", label: "New workspace only when all are full",
      description: "Past the last one, a swipe only makes a new workspace once every workspace has a window" },
    { key: "windowSwipe", kind: "toggle", label: "Shift + swipe moves the window",
      description: "Carries the focused window to the next workspace" },
    { key: "swipeUpExpose", kind: "toggle", label: "Swipe up for Mission Control",
      description: "All windows at a glance; swipe down to close" },
    { key: "pinchFullscreen", kind: "toggle", label: "Spread for fullscreen",
      description: "Pinch to come back" },
    { key: "pinchMaximize", kind: "choice", label: "Spread makes it",
      options: [{ value: "fullscreen", label: "Fullscreen" }, { value: "maximize", label: "Maximized" }] },
    { key: "resizeOnEdges", kind: "toggle", label: "Drag edges to resize",
      description: "Pull a window's edge or corner. Off stops the cursor watch" },
    { key: "hoverPreview", kind: "toggle", label: "Preview on hover",
      description: "A live thumbnail of the workspace under the pointer" }
  ]

  function rowValue(row) {
    var s = current()
    if (row.key === "shortSwipe") return s.shortSwipe ? "short" : "half"
    if (row.key === "pinchMaximize") return s.pinchMaximize ? "maximize" : "fullscreen"
    return s[row.key]
  }

  function setChoice(row, value) {
    if (row.key === "shortSwipe") value = value === "short"
    else if (row.key === "pinchMaximize") value = value === "maximize"
    updateSetting(row.key, value)
  }

  // Each chip is its own boolean; the last one on stays on, so some gestures
  // always remain.
  function toggleChip(key) {
    var s = current()
    if (s[key] && !(s.threeFingers && s.fourFingers)) return
    updateSetting(key, !s[key])
  }

  function activateRow(index, delta) {
    var row = rows[index]
    if (!row) return
    if (row.kind === "toggle") {
      updateSetting(row.key, !current()[row.key])
      return
    }
    if (row.kind === "multi") {
      toggleChip(row.options[Math.max(0, Math.min(row.options.length - 1, chipCursor))].value)
      return
    }
    var options = row.options
    var at = 0
    for (var i = 0; i < options.length; i++) if (options[i].value === rowValue(row)) at = i
    setChoice(row, options[(at + (delta || 1) + options.length) % options.length].value)
  }

  onOpenedChanged: {
    if (!opened) cursorIndex = -1
    else refreshSetup()
  }

  // ------------------------------------------------------------ Hyprland setup

  // Hyprland loads gestures.lua from a marked block in ~/.config/hypr/input.lua.
  // setup.sh adds or removes that block, and only when a button here is
  // pressed. hyprSetup is "enabled", "manual" or "disabled"; hyprActive says
  // whether Hyprland has the module loaded.
  readonly property string setupScript: Qt.resolvedUrl("setup.sh").toString().replace("file://", "")
  property string hyprSetup: ""
  property bool hyprActive: true

  function refreshSetup() {
    if (!setupStatus.running) setupStatus.running = true
    if (!hyprStatus.running) hyprStatus.running = true
  }

  function runSetup(action) {
    if (setupAction.running) return
    setupAction.command = ["bash", setupScript, action]
    setupAction.running = true
  }

  Process {
    id: setupStatus
    command: ["bash", root.setupScript, "status"]
    stdout: StdioCollector { onStreamFinished: root.hyprSetup = text.trim() }
  }

  Process {
    id: hyprStatus
    command: ["hyprctl", "repl", "return type(BentoSpaces)"]
    stdout: StdioCollector { onStreamFinished: root.hyprActive = text.trim() === "table" }
  }

  Process {
    id: setupAction
    onExited: setupRefreshTimer.restart()
  }

  // setup.sh reloads Hyprland; give it a moment before asking again.
  Timer {
    id: setupRefreshTimer
    interval: 600
    onTriggered: root.refreshSetup()
  }

  // ---------------------------------------------------------------- popup UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          root.cursorIndex = root.cursorIndex < 0 ? 0
            : Math.max(0, Math.min(root.rows.length - 1, root.cursorIndex + dy))
        } else if (dx !== 0 && root.cursorIndex >= 0 && root.rows[root.cursorIndex].kind === "choice") {
          root.activateRow(root.cursorIndex, dx)
        } else if (dx !== 0 && root.cursorIndex >= 0 && root.rows[root.cursorIndex].kind === "multi") {
          var count = root.rows[root.cursorIndex].options.length
          root.chipCursor = Math.max(0, Math.min(count - 1, root.chipCursor + dx))
        }
      }
      onActivateRequested: if (root.cursorIndex >= 0) root.activateRow(root.cursorIndex, 1)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Text {
          text: "BENTOSPACES"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Rectangle {
          visible: !root.hyprActive
          width: parent.width
          implicitHeight: setupColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: Color.accent

          Column {
            id: setupColumn
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: root.hyprSetup === "disabled"
                ? "Hyprland does not load the gestures yet. Enabling adds a marked block to ~/.config/hypr/input.lua (after a backup) and reloads Hyprland."
                : "input.lua has the block, but Hyprland has not loaded it. Check hyprctl configerrors."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              visible: root.hyprSetup === "disabled"
              text: setupAction.running ? "Enabling…" : "Enable in Hyprland"
              bordered: true
              enabled: !setupAction.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.runSetup("enable")
            }
          }
        }

        Repeater {
          model: root.rows

          delegate: Item {
            id: rowItem
            required property var modelData
            required property int index
            width: column.width
            implicitHeight: modelData.kind === "toggle" ? toggle.implicitHeight : choiceRow.implicitHeight

            Toggle {
              id: toggle
              visible: rowItem.modelData.kind === "toggle"
              width: parent.width
              label: rowItem.modelData.label
              description: rowItem.modelData.description || ""
              checked: rowItem.modelData.kind === "toggle" && root.rowValue(rowItem.modelData) === true
              hasCursor: root.cursorIndex === rowItem.index
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.activateRow(rowItem.index, 1)
              onHovered: function(isHovered) { if (isHovered) root.cursorIndex = rowItem.index }
            }

            Item {
              id: choiceRow
              visible: rowItem.modelData.kind === "choice" || rowItem.modelData.kind === "multi"
              width: parent.width
              implicitHeight: Math.max(choiceLabel.implicitHeight, choices.implicitHeight, chips.implicitHeight)

              Text {
                id: choiceLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.modelData.label
                color: root.cursorIndex === rowItem.index ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              ButtonGroup {
                id: choices
                visible: rowItem.modelData.kind === "choice"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                options: rowItem.modelData.options || []
                value: rowItem.modelData.kind === "choice" ? String(root.rowValue(rowItem.modelData)) : ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                focusable: false
                onChanged: function(value) { root.setChoice(rowItem.modelData, value) }
                onHovered: function(i, isHovered) { if (isHovered) root.cursorIndex = rowItem.index }
              }

              // Like the ButtonGroup chips, but every chip toggles on its own.
              Row {
                id: chips
                visible: rowItem.modelData.kind === "multi"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Repeater {
                  model: rowItem.modelData.kind === "multi" ? rowItem.modelData.options : []

                  delegate: Button {
                    required property var modelData
                    required property int index
                    text: modelData.label
                    selected: root.current()[modelData.value] === true
                    hasCursor: root.cursorIndex === rowItem.index && root.chipCursor === index
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.toggleChip(modelData.value)
                    onHovered: function(isHovered) {
                      if (!isHovered) return
                      root.cursorIndex = rowItem.index
                      root.chipCursor = index
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "In the bar: click a window in a mini-map to focus it, middle-click to close, drag it to another workspace, scroll to step."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          visible: root.hyprSetup === "enabled"
          text: setupAction.running ? "Removing…" : "Remove from Hyprland"
          bordered: true
          enabled: !setupAction.running
          foreground: root.dim
          fontFamily: root.fontFamily
          onClicked: root.runSetup("disable")
        }
      }
    }
  }
}
