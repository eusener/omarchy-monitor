import QtQuick
import qs.Commons
import qs.Commons as Commons

// The complete native panel is the base; the custom editor is its extension.
NativeMonitor {
  id: root
  Component.onCompleted: console.log("Omarchy Monitor 1.2.0 loaded:", root.scalePresets.length, "native scale presets; advanced editor attached")
  preferredWidth: 500
  preferredHeight: 760
  readonly property alias advancedEditor: editor
  extensionContent: editor.content
  extensionInputFocused: editor.inputFocused
  extensionDragging: editor.dragging
  quickChangesBlocked: editor.busy || editor.dirty || editor.pending

  DisplayEditor {
    id: editor
    bar: root.bar
    opened: root.opened
    visible: false
    onMonitorsChanged: root.refresh()
    onFocusRequested: {
      root.focusSection = "advanced"
      root.cursorActive = true
    }
    onPendingVisibleRequested: Qt.callLater(root.ensureExtensionVisible)
  }

  // The same native buttons preview a change through the existing watchdog.
  // One persistence path prevents saved advanced profiles overriding quick scale.
  function setScale(scale) {
    if (root.quickChangesBlocked || !editor.draft[root.focusedMonitor]) return
    editor.setField(root.focusedMonitor, "scale", Number(scale))
    editor.applyDraft()
  }

  function toggleDisplay(name, enabled) {
    if (root.quickChangesBlocked || !name || (enabled && root.enabledDisplayCount <= 1)) return
    var monitor = editor.monitorByName(name)
    if (!monitor) return
    if (monitor.kind === "internal") editor.toggleLaptop(!enabled)
    else {
      editor.setField(name, "disabled", enabled)
      editor.applyDraft()
    }
  }

  onExtensionMoveRequested: function(dx, dy) {
    if (dx !== 0) editor.cycleSelected(dx)
    else if (root.contentScroll) {
      var flick = root.contentScroll
      flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(60)))
    }
  }
  onExtensionActivateRequested: {
    if (editor.pending) editor.keep()
    else if (editor.dirty) editor.applyDraft()
  }
  onExtensionTextKey: function(text) {
    if (text.toLowerCase() === "r") { root.refresh(); editor.refresh() }
    else if (text.toLowerCase() === "u" && editor.pending) editor.revert()
  }

  Commons.ShellIpc {
    target: "eusener.displays"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function keep(): void { if (editor.pending) editor.keep() }
    function revert(): void { if (editor.pending) editor.revert() }
    function discard(): void { editor.discard() }
    function state(): string {
      var result = JSON.parse(root.stateIpc())
      result.primary = editor.primaryName
      result.pending = editor.pending
      result.draft = editor.draft
      return JSON.stringify(result)
    }
  }
}
