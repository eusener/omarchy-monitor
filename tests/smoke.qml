import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons
import "Monitor" as Monitor

ShellRoot {
  id: test
  function check(ok, message) { if (!ok) { console.error("TEST_FAILED: " + message); Qt.exit(1) } }
  QtObject {
    id: testBar
    property color foreground: "#eeeeee"
    property color barForeground: foreground
    property color background: "#202020"
    property color urgent: "#ff5555"
    property string fontFamily: "sans-serif"
    property string position: "top"
    property bool foregroundAnimationEnabled: false
    property bool vertical: false
    property int barSize: 36
    property int sizeHorizontal: 36
    property var activePopout: null
    property var clickTargets: []
    property var moduleWidgets: ({})
    property var shell: null
    function hideTooltip(item) {}
    function registerClickTarget(item) {}
    function unregisterClickTarget(item) {}
    function requestPopout(item) { activePopout = item }
    function releasePopout(item) { activePopout = null }
    function notePopoutCard(item, card) {}
    function popoutCardFor(item) { return null }
  }
  Monitor.Monitor { id: widget; bar: testBar }
  Window { id: preview; width: 500; height: 780; visible: true; color: testBar.background }
  property string expectedFocus: Quickshell.env("MONITOR_TEST_FOCUS") || "eDP-1"
  property int expectedDisplays: Number(Quickshell.env("MONITOR_TEST_DISPLAY_COUNT") || "1")
  property var content: null

  function walk(item, visit) {
    visit(item)
    if (item.children) for (var i = 0; i < item.children.length; i++) walk(item.children[i], visit)
  }

  Timer {
    interval: 700; running: true
    onTriggered: {
      test.check(widget.brightnessAvailable === true, "native brightnessAvailable property retained")
      test.check(widget.brightnessPercent === 42, "native brightnessPercent property retained")
      test.check(JSON.stringify(widget.scalePresets) === '["1","1.25","1.6","2","3","4"]', "all original scale presets retained")
      for (var name of ["toggleDisplay", "activeScaleIndex", "effectiveScale", "clampCursor", "moveCursor", "adjustBrightness", "adjustTextSize", "brightnessIpc", "stateIpc"]) {
        test.check(typeof widget[name] === "function", "original method retained: " + name)
      }
      var state = JSON.parse(widget.stateIpc())
      test.check(state.brightness === 42 && state.focusedMonitor === test.expectedFocus, "native state and focused monitor retained")
      test.check(widget.displays.length === test.expectedDisplays && (widget.displays[0].enabled || test.expectedFocus !== "eDP-1"), "native display controls retained")
      test.check(widget.advancedEditor.monitors.length === test.expectedDisplays, "advanced editor helper loads")
      test.check(widget.advancedEditor.draft["eDP-1"].scale === 2, "saved custom draft retained")
      test.check(widget.nearestTextStop(12) === 3, "original text size stops retained")
      var reply = IpcRegistry.call("omarchy.monitor", "brightness", ["64"])
      test.check(reply.ran && reply.output === "got 64", "original brightness IPC retained")
      reply = IpcRegistry.call("eusener.displays", "state", [])
      test.check(reply.ran && JSON.parse(reply.output).brightness === 64, "legacy custom IPC retained")
      for (var i = 0; i < widget.data.length; i++) {
        if (typeof widget.data[i].ensureContent === "function") {
          test.content = widget.data[i].ensureContent()
          break
        }
      }
      test.check(test.content !== null, "native popup content instantiates")
      test.content.parent = preview.contentItem
      test.content.width = 500
      test.content.height = 780
      widget.cursorActive = true
      widget.focusSection = "textsize"
      widget.moveCursor(-1)
      test.check(widget.focusSection === "brightness", "up from text size returns to brightness")
      widget.moveCursor(1)
      test.check(widget.focusSection === "textsize", "down from brightness reaches text size")
      widget.moveCursor(1)
      test.check(widget.focusSection === "scale", "down reaches native scale presets")
      widget.moveCursor(1)
      if (test.expectedDisplays > 1) {
        test.check(widget.focusSection === "monitors", "native on/off monitor section retained")
        widget.moveCursor(1)
        widget.moveCursor(1)
      }
      test.check(widget.focusSection === "advanced", "native navigation reaches advanced editor")
      widget.advancedEditor.setField("eDP-1", "scale", 1.6)
      test.check(widget.advancedEditor.dirty && widget.quickChangesBlocked, "advanced draft blocks conflicting native actions")
      test.check(widget.brightnessPercent === 64, "advanced edits preserve native brightness")
      widget.advancedEditor.discard()
      test.check(!widget.advancedEditor.dirty && !widget.quickChangesBlocked, "discard restores native quick actions")
      widget.focusSection = "brightness"
      widget.brightnessAvailable = false
      test.check(widget.focusSection !== "brightness", "unavailable native brightness cannot keep focus")
      var lastBrightness = widget.brightnessPercent
      widget.focusSection = "brightness"
      widget.adjustBrightness(5)
      test.check(widget.brightnessPercent === lastBrightness, "unavailable native brightness ignores adjustment")
      widget.brightnessAvailable = true
      widget.setTextSize(14)
      widget.setScale("1.6")
      finish.start()
    }
  }
  Timer {
    id: finish; interval: 700
    onTriggered: {
      widget.brightnessAvailable = true
      var nativeScale = false
      var nativeText = false
      var nativeBrightness = false
      var advancedTitle = false
      var plainHardware = false
      test.walk(test.content, function(item) {
        if (item.text !== undefined && item.visible) {
          var label = String(item.text).toLowerCase()
          if (label === "4x") nativeScale = true
          if (label.indexOf("text size") >= 0 || label.indexOf("tamanho do texto") >= 0) nativeText = true
          if (label === "brightness" || label === "brilho") nativeBrightness = true
          if (label.indexOf("advanced display settings") >= 0 || label.indexOf("configurações avançadas") >= 0) advancedTitle = true
          if (label.indexOf("<img") >= 0 && item.textFormat === Text.PlainText) plainHardware = true
        }
      })
      // Availability was changed above; show the brightness row again for the visible UI check.
      widget.brightnessAvailable = true
      test.check(widget.advancedEditor.pending, "native quick-scale action uses custom apply and rollback countdown")
      test.check(widget.contentScroll.contentY <= test.content.extensionAnchor.y + 8, "pending confirmation remains visible at extension top")
      test.check(nativeScale, "native 4x quick-scale button rendered")
      test.check(nativeBrightness, "native brightness section rendered")
      test.check(nativeText, "native text size section rendered")
      test.check(advancedTitle, "advanced editor rendered under original panel")
      test.check(plainHardware, "hardware descriptions rendered as plain text")
      test.check(test.content.implicitHeight > preview.height, "combined panel remains scrollable")
      console.log("MONITOR_QT_TESTS_OK")
      Qt.quit()
    }
  }
}
