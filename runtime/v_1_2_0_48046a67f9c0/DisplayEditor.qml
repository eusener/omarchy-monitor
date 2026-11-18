import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Layout.js" as L

// Per-monitor settings for the laptop panel and anything on HDMI / USB-C:
// resolution, refresh rate, custom modes, scale, VRR, rotation, mirroring,
// colour (10-bit, gamut, HDR SDR levels), on/off, primary and arrangement.
//
// Edits collect in a draft. Apply sends the whole layout to displays.py, which
// applies it live and reverts after a countdown unless Keep is pressed; Keep
// saves it to ~/.config/hypr/displays.lua as rules matched by the monitor's
// EDID description, so each monitor keeps its settings on any port.
Item {
  id: root
  property QtObject bar: null
  property bool opened: false
  property bool dragging: false
  signal focusRequested()
  signal pendingVisibleRequested()

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helperPath: pluginDir + "/displays.py"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Live state from displays.py status.
  property var monitors: []
  property string primaryDesc: ""
  property real pendingDeadline: 0
  property int revertSeconds: 15

  // The draft being edited: connector name -> spec (see displays.py).
  property var draft: ({})
  property bool dirty: false
  property string primaryName: ""
  property string selectedName: ""

  property bool busy: false
  property string message: ""
  property bool messageIsError: false
  property real now: Date.now() / 1000
  property bool inputFocused: false

  readonly property bool pending: pendingDeadline > 0
  readonly property int secondsLeft: Math.max(0, Math.ceil(pendingDeadline - now))
  readonly property var selected: monitorByName(selectedName)
  readonly property var selectedSpec: draft[selectedName] || null
  readonly property int enabledCount: monitors.filter(function (m) { return root.draft[m.name] && !root.draft[m.name].disabled }).length

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }


  // ------------------------------------------------------------------ state

  function monitorByName(name) {
    for (var i = 0; i < monitors.length; i++) if (monitors[i].name === name) return monitors[i]
    return null
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function readStatus(text) {
    try {
      var data = JSON.parse(String(text || "").trim().split("\n").pop())
      root.monitors = data.monitors || []
      root.primaryDesc = data.primary || ""
      root.revertSeconds = data.revertSeconds || 15
      root.pendingDeadline = data.pending ? data.pending.deadline : 0
      if (!root.dirty || root.pending) root.resetDraft()
      return true
    } catch (e) {
      return false
    }
  }

  function resetDraft() {
    var d = {}
    var primary = ""
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      d[m.name] = JSON.parse(JSON.stringify(m.spec))
      if (primaryDesc && m.description === primaryDesc) primary = m.name
    }
    if (!primary) {
      for (var j = 0; j < monitors.length; j++) {
        var s = d[monitors[j].name]
        if (!s.disabled && s.x === 0 && s.y === 0) { primary = monitors[j].name; break }
      }
    }
    if (!primary && monitors.length) primary = monitors[0].name
    root.draft = d
    root.primaryName = primary
    root.dirty = false
    if (!monitorByName(selectedName)) {
      var focused = monitors.filter(function (m) { return m.focused })[0]
      root.selectedName = focused ? focused.name : (monitors.length ? monitors[0].name : "")
    }
  }

  function cloneDraft() { return JSON.parse(JSON.stringify(draft)) }

  // Rects on the desktop for monitors that take part in the layout.
  function layoutRects(d) {
    var out = []
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      var s = d[m.name]
      if (!s || s.disabled || s.mirror) continue
      var size = L.logicalSize(s, m.width, m.height)
      out.push({ name: m.name, x: s.x, y: s.y, width: size.width, height: size.height })
    }
    return out
  }

  // After a size change, re-attach monitors in left-to-right order so none
  // overlap and none float free; the primary stays put.
  function relayout(d) {
    var rects = layoutRects(d)
    rects.sort(function (a, b) {
      if (a.name === root.primaryName) return -1
      if (b.name === root.primaryName) return 1
      return a.x - b.x || a.y - b.y
    })
    var placed = []
    for (var i = 0; i < rects.length; i++) {
      var r = rects[i]
      if (placed.length) {
        var p = L.snap(r, placed, 0)
        r.x = p.x; r.y = p.y
      }
      placed.push(r)
      d[r.name].x = r.x
      d[r.name].y = r.y
    }
    normalizeInto(d)
  }

  function normalizeInto(d) {
    var p = d[primaryName]
    if (!p || p.disabled || p.mirror) return
    var ox = p.x, oy = p.y
    for (var k in d) { d[k].x -= ox; d[k].y -= oy }
  }

  function setField(name, key, value) {
    root.focusRequested()
    if (!draft[name]) return
    var d = cloneDraft()
    d[name][key] = value
    if (key === "mode" || key === "scale" || key === "transform" || key === "disabled" || key === "mirror") {
      if (key === "mode") {
        // Keep the scale clean for the new size.
        var size = L.modeSize(value, 0, 0)
        if (size.width) d[name].scale = L.cleanScale(d[name].scale, size.width, size.height)
      }
      relayout(d)
    }
    root.draft = d
    root.dirty = true
    root.message = ""
  }

  function setPrimary(name) {
    root.focusRequested()
    var s = draft[name]
    if (!s || s.disabled || s.mirror) return
    root.primaryName = name
    var d = cloneDraft()
    normalizeInto(d)
    root.draft = d
    root.dirty = true
  }

  // Drop a monitor at desktop coordinates; snap it to its neighbours.
  function moveMonitor(name, x, y) {
    root.focusRequested()
    var d = cloneDraft()
    var rects = layoutRects(d)
    var me = rects.filter(function (r) { return r.name === name })[0]
    if (!me) return
    var others = rects.filter(function (r) { return r.name !== name })
    me.x = Math.round(x); me.y = Math.round(y)
    var p = L.snap(me, others, Math.max(me.width, me.height) * 0.06)
    d[name].x = p.x
    d[name].y = p.y
    normalizeInto(d)
    root.draft = d
    root.dirty = true
  }

  function gdkPreview() {
    var lo = 99
    for (var k in draft) if (!draft[k].disabled && !draft[k].mirror) lo = Math.min(lo, draft[k].scale)
    return lo === 99 ? 1 : Math.max(1, Math.floor(lo + 0.5))
  }

  // --------------------------------------------------------------- actions

  function runHelper(args, success) {
    if (busy) return
    busy = true
    messageIsError = false
    message = strings.t("applying")
    helperProc.successText = success
    helperProc.command = ["python3", root.helperPath].concat(args)
    helperProc.running = true
  }

  function applyDraft() {
    var list = []
    for (var i = 0; i < monitors.length; i++) {
      var s = draft[monitors[i].name]
      if (s) list.push(s)
    }
    runHelper(["apply", JSON.stringify({ primary: primaryName, monitors: list })], strings.t("appliedConfirm"))
  }

  function keep() { runHelper(["keep"], strings.t("saved")) }
  function revert() { runHelper(["revert"], strings.t("reverted")) }

  function discard() {
    root.dirty = false
    resetDraft()
    root.message = ""
  }

  function toggleLaptop(on) {
    laptopProc.command = ["omarchy-hyprland-monitor-internal", on ? "on" : "off"]
    if (!laptopProc.running) laptopProc.running = true
  }

  function cycleSelected(dir) {
    root.focusRequested()
    if (!monitors.length) return
    var i = monitors.findIndex(function (m) { return m.name === root.selectedName })
    i = (i + dir + monitors.length) % monitors.length
    root.selectedName = monitors[i].name
  }

  onOpenedChanged: if (opened) refresh()
  onPendingChanged: if (pending) pendingVisibleRequested()
  onInputFocusedChanged: if (inputFocused) focusRequested()

  Component.onCompleted: refresh()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var n = event.name
      if (n === "monitoraddedv2" || n === "monitorremovedv2" || n === "monitoradded" || n === "monitorremoved" || n === "configreloaded")
        refreshDebounce.restart()
    }
  }

  Timer { id: refreshDebounce; interval: 600; onTriggered: root.refresh() }

  Timer {
    interval: 250
    repeat: true
    running: root.pending
    onTriggered: {
      root.now = Date.now() / 1000
      // The watchdog in displays.py reverts on its own; just pick the result up.
      if (root.now > root.pendingDeadline + 1) root.refresh()
    }
  }

  Process {
    id: statusProc
    command: ["python3", root.helperPath, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.readStatus(text) }
  }

  Process {
    id: helperProc
    property string successText: ""
    property string out: ""
    property string err: ""
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: helperProc.out = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: helperProc.err = String(text || "").trim() }
    onExited: function (exitCode) {
      Qt.callLater(function () {
        root.busy = false
        root.now = Date.now() / 1000
        if (exitCode === 0) {
          root.dirty = false
          root.readStatus(helperProc.out)
          root.messageIsError = false
          root.message = helperProc.successText
        } else {
          root.messageIsError = true
          root.message = strings.t("failed").arg(helperProc.err.split("\n").pop() || ("exit " + exitCode))
          root.refresh()
        }
      })
    }
  }

  Process {
    id: laptopProc
    onExited: refreshDebounce.restart()
  }

  readonly property Component content: Component {
    Column {
              id: column
              width: parent ? parent.width : 0
              spacing: Style.space(12)

              PanelHero {
                width: parent.width
                title: strings.t("advancedTitle")
                meta: strings.tn("connected", root.monitors.length).arg(Commons.I18n.formatNumber(root.monitors.length))
                detail: root.primaryName ? strings.t("primaryIs").arg(root.primaryName) : ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                iconComponent: Component {
                  PlainText {
                    text: root.monitors.length > 1 ? "󰍺" : "󰹑"
                    font.pixelSize: Style.font.display
                  }
                }
              }

              // ---------- Revert countdown ----------
              Rectangle {
                visible: root.pending
                width: parent.width
                implicitHeight: pendingCol.implicitHeight + Style.space(20)
                radius: Style.cornerRadius
                color: Util.alpha(root.accent, 0.12)
                border.color: root.accent
                border.width: Math.max(1, Style.normalBorderWidth)

                Column {
                  id: pendingCol
                  anchors.centerIn: parent
                  width: parent.width - Style.space(20)
                  spacing: Style.space(8)

                  PlainText {
                    width: parent.width
                    text: strings.t("keepQuestion").arg(root.secondsLeft)
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }
                  Row {
                    spacing: Style.space(8)
                    Button {
                      text: strings.t("revert")
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.revert()
                    }
                    Button {
                      text: strings.t("keep")
                      bordered: true
                      active: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.keep()
                    }
                  }
                }
              }

              PlainText {
                visible: root.message !== ""
                width: parent.width
                text: root.message
                color: root.messageIsError ? root.urgent : root.dim
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // ---------- Arrangement map ----------
              PanelSectionHeader {
                text: strings.t("arrangement")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Rectangle {
                id: mapArea
                width: parent.width
                height: Style.space(180)
                radius: Style.cornerRadius
                color: Util.alpha(root.foreground, 0.04)
                border.color: Util.alpha(root.foreground, 0.12)
                border.width: 1

                property bool dragging: false
                onDraggingChanged: root.dragging = dragging
                readonly property var rects: root.layoutRects(root.draft)
                readonly property real pad: Style.space(14)
                readonly property var bounds: {
                  var b = { x0: 0, y0: 0, x1: 1, y1: 1 }
                  if (!rects.length) return b
                  b.x0 = Infinity; b.y0 = Infinity; b.x1 = -Infinity; b.y1 = -Infinity
                  for (var i = 0; i < rects.length; i++) {
                    var r = rects[i]
                    b.x0 = Math.min(b.x0, r.x); b.y0 = Math.min(b.y0, r.y)
                    b.x1 = Math.max(b.x1, r.x + r.width); b.y1 = Math.max(b.y1, r.y + r.height)
                  }
                  return b
                }
                // Leave room around the layout so a monitor can be dragged to any side.
                readonly property real k: {
                  var bw = (bounds.x1 - bounds.x0) * 1.6, bh = (bounds.y1 - bounds.y0) * 1.6
                  return Math.min((width - 2 * pad) / Math.max(1, bw), (height - 2 * pad) / Math.max(1, bh))
                }
                readonly property real ox: (width - (bounds.x1 - bounds.x0) * k) / 2 - bounds.x0 * k
                readonly property real oy: (height - (bounds.y1 - bounds.y0) * k) / 2 - bounds.y0 * k

                PlainText {
                  visible: mapArea.rects.length === 0
                  anchors.centerIn: parent
                  text: strings.t("noLayout")
                  color: root.dim
                }

                Repeater {
                  model: mapArea.rects
                  Rectangle {
                    id: tile
                    required property var modelData
                    property real dx: 0
                    property real dy: 0
                    readonly property bool isSelected: modelData.name === root.selectedName
                    readonly property bool isPrimary: modelData.name === root.primaryName
                    x: mapArea.ox + modelData.x * mapArea.k + dx
                    y: mapArea.oy + modelData.y * mapArea.k + dy
                    width: Math.max(8, modelData.width * mapArea.k - 2)
                    height: Math.max(8, modelData.height * mapArea.k - 2)
                    z: tileMouse.pressed ? 2 : 1
                    radius: Math.max(2, Style.cornerRadius / 2)
                    color: isSelected ? Util.alpha(root.accent, 0.28) : Util.alpha(root.foreground, 0.10)
                    border.color: isSelected ? root.accent : Util.alpha(root.foreground, 0.45)
                    border.width: isSelected ? 2 : 1

                    Column {
                      anchors.centerIn: parent
                      width: parent.width - 6
                      spacing: 1
                      PlainText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: (tile.isPrimary ? "★ " : "") + tile.modelData.name
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      PlainText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: tile.modelData.width + "×" + tile.modelData.height
                        color: root.dim
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        visible: tile.height > Style.space(36)
                      }
                    }

                    MouseArea {
                      id: tileMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                      enabled: !root.busy
                      property point start
                      onPressed: function (e) {
                        root.selectedName = tile.modelData.name
                        start = mapToItem(mapArea, e.x, e.y)
                        mapArea.dragging = true
                      }
                      onPositionChanged: function (e) {
                        if (!pressed) return
                        var p = mapToItem(mapArea, e.x, e.y)
                        tile.dx = p.x - start.x
                        tile.dy = p.y - start.y
                      }
                      onReleased: {
                        mapArea.dragging = false
                        var moved = Math.abs(tile.dx) + Math.abs(tile.dy) > 3
                        var nx = tile.modelData.x + tile.dx / mapArea.k
                        var ny = tile.modelData.y + tile.dy / mapArea.k
                        tile.dx = 0
                        tile.dy = 0
                        if (moved) root.moveMonitor(tile.modelData.name, nx, ny)
                      }
                      onDoubleClicked: root.setPrimary(tile.modelData.name)
                    }
                  }
                }
              }

              PlainText {
                width: parent.width
                text: strings.t("mapHint")
                color: root.dim
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ---------- Monitor picker ----------
              Flow {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.monitors
                  Button {
                    required property var modelData
                    text: L.kindGlyph(modelData.kind) + "  " + modelData.name
                    bordered: true
                    active: modelData.name === root.selectedName
                    opacity: root.draft[modelData.name] && root.draft[modelData.name].disabled ? 0.55 : 1
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onClicked: root.selectedName = modelData.name
                  }
                }
              }

              PanelSeparator { foreground: root.foreground }

              // ---------- Selected monitor ----------
              Column {
                id: details
                visible: root.selected !== null && root.selectedSpec !== null
                width: parent.width
                spacing: Style.space(10)

                readonly property var mon: root.selected || ({ modes: [], kind: "", name: "", description: "" })
                readonly property var spec: root.selectedSpec || ({ mode: "", scale: 1, transform: 0, vrr: 0, mirror: "", bitdepth: 8, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1, disabled: false })
                readonly property var size: L.modeSize(spec.mode, mon.width, mon.height)
                readonly property string resolution: size.width + "x" + size.height
                readonly property var resolutionList: {
                  var list = L.resolutions(mon.modes)
                  if (list.indexOf(resolution) < 0 && size.width) list.unshift(resolution)
                  return list
                }
                readonly property var rates: L.ratesFor(mon.modes, resolution)
                readonly property bool customMode: mon.modes.indexOf(spec.mode + "Hz") < 0 && spec.mode !== "" && spec.mode !== "preferred"
                readonly property bool isInternal: mon.kind === "internal"
                readonly property bool active: !spec.disabled

                PlainText {
                  width: parent.width
                  text: details.mon.description || details.mon.name
                  font.bold: true
                  font.pixelSize: Style.font.subtitle
                  wrapMode: Text.WordWrap
                }
                PlainText {
                  width: parent.width
                  color: root.dim
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  text: {
                    var parts = [strings.t("kind." + (details.mon.kind || "other")), details.mon.name]
                    var inch = L.diagonalInches(details.mon.physicalWidth, details.mon.physicalHeight)
                    if (inch) parts.push(strings.t("inches").arg(Commons.I18n.formatNumber(inch, 1)))
                    parts.push(details.mon.saved ? strings.t("savedProfile") : strings.t("notSaved"))
                    return parts.join("  ·  ")
                  }
                }

                SettingRow {
                  label: strings.t("enabled")
                  hint: details.isInternal ? strings.t("laptopHint") : ""
                  ToggleSwitch {
                    checked: details.active
                    busy: root.busy
                    cursorRing: false
                    foreground: root.foreground
                    onToggled: {
                      if (details.isInternal) root.toggleLaptop(!details.active)
                      else if (details.active && root.enabledCount <= 1) root.message = strings.t("lastScreen")
                      else root.setField(details.mon.name, "disabled", details.active)
                    }
                  }
                }

                SettingRow {
                  visible: details.active && !details.spec.mirror
                  label: strings.t("primary")
                  hint: strings.t("primaryHint")
                  ToggleSwitch {
                    checked: root.primaryName === details.mon.name
                    cursorRing: false
                    foreground: root.foreground
                    onToggled: root.setPrimary(details.mon.name)
                  }
                }

                Column {
                  visible: details.active
                  width: parent.width
                  spacing: Style.space(10)

                  SettingRow {
                    label: strings.t("resolution")
                    Dropdown {
                      width: Style.space(190)
                      showLabel: false
                      fontFamily: root.fontFamily
                      foreground: root.foreground
                      options: details.resolutionList
                      value: details.resolution
                      onPopupOpenChanged: root.inputFocused = popupOpen
                      onChanged: function (v) {
                        var r = L.ratesFor(details.mon.modes, v)
                        root.setField(details.mon.name, "mode", r.length ? r[0].mode : v + "@60")
                      }
                    }
                  }

                  SettingRow {
                    label: strings.t("refresh")
                    visible: details.rates.length > 0
                    Dropdown {
                      width: Style.space(190)
                      showLabel: false
                      fontFamily: root.fontFamily
                      foreground: root.foreground
                      options: details.rates.map(function (r) { return { value: r.mode, label: L.formatHz(r.hz) } })
                      value: details.spec.mode
                      onPopupOpenChanged: root.inputFocused = popupOpen
                      onChanged: function (v) { root.setField(details.mon.name, "mode", v) }
                    }
                  }

                  SettingRow {
                    label: strings.t("customMode")
                    hint: details.customMode ? strings.t("customActive").arg(details.spec.mode) : strings.t("customHint")
                    Row {
                      spacing: Style.space(6)
                      TextField {
                        id: customField
                        width: Style.space(140)
                        placeholderText: "2560x1440@75"
                        foreground: root.foreground
                        font.family: root.fontFamily
                        text: details.customMode ? details.spec.mode : ""
                        onActiveFocusChanged: root.inputFocused = activeFocus
                        onAccepted: customUse.clicked()
                        color: text === "" || L.validCustomMode(text) ? root.foreground : root.urgent
                      }
                      Button {
                        id: customUse
                        text: strings.t("use")
                        bordered: true
                        enabled: L.validCustomMode(customField.text)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: {
                          root.setField(details.mon.name, "mode", customField.text.trim())
                          customField.focus = false
                        }
                      }
                    }
                  }

                  // ---------- VRR ----------
                  Column {
                    width: parent.width
                    spacing: Style.space(6)
                    PlainText { text: strings.t("vrr") }
                    ButtonGroup {
                      options: [
                        { value: "0", label: strings.t("vrr.0") },
                        { value: "1", label: strings.t("vrr.1") },
                        { value: "2", label: strings.t("vrr.2") },
                        { value: "3", label: strings.t("vrr.3") }
                      ]
                      value: String(details.spec.vrr)
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      focusable: false
                      onChanged: function (v) { root.setField(details.mon.name, "vrr", parseInt(v)) }
                    }
                    PlainText {
                      width: parent.width
                      text: details.spec.vrr > 0 && !details.mon.vrrActive && !root.dirty ? strings.t("vrrInactive") : strings.t("vrrHint")
                      color: root.dim
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }

                  // ---------- Rotation ----------
                  Column {
                    width: parent.width
                    spacing: Style.space(6)
                    PlainText { text: strings.t("rotation") }
                    Row {
                      spacing: Style.space(10)
                      ButtonGroup {
                        options: ["0", "1", "2", "3"].map(function (v) { return { value: v, label: (parseInt(v) * 90) + "°" } })
                        value: String(details.spec.transform % 4)
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        focusable: false
                        onChanged: function (v) { root.setField(details.mon.name, "transform", parseInt(v) + (details.spec.transform >= 4 ? 4 : 0)) }
                      }
                      PlainText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: strings.t("flip")
                        font.pixelSize: Style.font.bodySmall
                      }
                      ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        checked: details.spec.transform >= 4
                        cursorRing: false
                        foreground: root.foreground
                        onToggled: root.setField(details.mon.name, "transform", (details.spec.transform % 4) + (checked ? 0 : 4))
                      }
                    }
                  }

                  SettingRow {
                    visible: root.monitors.length > 1
                    label: strings.t("mirror")
                    Dropdown {
                      width: Style.space(190)
                      showLabel: false
                      fontFamily: root.fontFamily
                      foreground: root.foreground
                      options: [{ value: "", label: strings.t("noMirror") }].concat(
                        root.monitors.filter(function (m) { return m.name !== details.mon.name }).map(function (m) { return { value: m.name, label: m.name } }))
                      value: details.spec.mirror || ""
                      onPopupOpenChanged: root.inputFocused = popupOpen
                      onChanged: function (v) {
                        if (v && root.primaryName === details.mon.name) root.primaryName = v
                        root.setField(details.mon.name, "mirror", v)
                      }
                    }
                  }

                  // ---------- Colour ----------
                  PanelSectionHeader {
                    text: strings.t("color")
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  SettingRow {
                    label: strings.t("tenBit")
                    hint: strings.t("tenBitHint")
                    ToggleSwitch {
                      checked: details.spec.bitdepth === 10
                      cursorRing: false
                      foreground: root.foreground
                      onToggled: root.setField(details.mon.name, "bitdepth", checked ? 8 : 10)
                    }
                  }

                  SettingRow {
                    label: strings.t("gamut")
                    Dropdown {
                      width: Style.space(190)
                      showLabel: false
                      fontFamily: root.fontFamily
                      foreground: root.foreground
                      options: L.CM_PRESETS.map(function (c) { return { value: c, label: strings.t("cm." + c) } })
                      value: details.spec.cm
                      onPopupOpenChanged: root.inputFocused = popupOpen
                      onChanged: function (v) {
                        root.setField(details.mon.name, "cm", v)
                        if (v.indexOf("hdr") === 0 && details.spec.bitdepth !== 10) root.setField(details.mon.name, "bitdepth", 10)
                      }
                    }
                  }

                  Column {
                    visible: details.spec.cm.indexOf("hdr") === 0
                    width: parent.width
                    spacing: Style.space(6)

                    PlainText {
                      text: strings.t("sdrBrightness").arg(Commons.I18n.formatNumber(details.spec.sdrbrightness, 2))
                      font.pixelSize: Style.font.bodySmall
                    }
                    PanelSlider {
                      width: parent.width
                      bar: root.bar
                      minimum: 0.5
                      maximum: 2
                      step: 0.05
                      value: details.spec.sdrbrightness
                      onReleased: function (v) { root.setField(details.mon.name, "sdrbrightness", Math.round(v * 100) / 100) }
                    }
                    PlainText {
                      text: strings.t("sdrSaturation").arg(Commons.I18n.formatNumber(details.spec.sdrsaturation, 2))
                      font.pixelSize: Style.font.bodySmall
                    }
                    PanelSlider {
                      width: parent.width
                      bar: root.bar
                      minimum: 0.5
                      maximum: 1.5
                      step: 0.05
                      value: details.spec.sdrsaturation
                      onReleased: function (v) { root.setField(details.mon.name, "sdrsaturation", Math.round(v * 100) / 100) }
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.foreground }

              // ---------- Footer ----------
              Row {
                spacing: Style.space(8)
                layoutDirection: Qt.RightToLeft
                width: parent.width
                Button {
                  text: strings.t("apply")
                  bordered: true
                  active: root.dirty
                  enabled: root.dirty && !root.busy && !root.pending
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.applyDraft()
                }
                Button {
                  text: strings.t("discard")
                  bordered: true
                  enabled: root.dirty && !root.busy
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.discard()
                }
              }

              PlainText {
                width: parent.width
                text: strings.t("footer").arg(root.gdkPreview()).arg(root.revertSeconds)
                color: root.dim
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Item { width: 1; height: Style.space(4) }
            }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // Label (and optional hint) on the left, one control on the right.
  component SettingRow: Item {
    id: settingRow
    property string label: ""
    property string hint: ""
    default property alias control: holder.data
    width: parent ? parent.width : 0
    implicitHeight: Math.max(labels.implicitHeight, holder.childrenRect.height)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: holder.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      PlainText {
        width: parent.width
        text: settingRow.label
        elide: Text.ElideRight
      }
      PlainText {
        visible: settingRow.hint !== ""
        width: parent.width
        text: settingRow.hint
        color: root.dim
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Item {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }
}
