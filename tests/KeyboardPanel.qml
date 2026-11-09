// Offscreen Qt has no layer-shell backend. Substitute only the window host;
// the plugin, lazy content, native UI controls and process/IPC code stay real.
import QtQuick
Item {
  id: root
  property Item anchorItem
  property QtObject bar
  property var owner
  property bool open: false
  property Item focusTarget
  property Component content
  property bool contentRequested: false
  property int contentWidth: 500
  property int contentHeight: 780
  readonly property Item loadedContent: body.item
  readonly property real loadedContentHeight: body.item ? body.item.implicitHeight : 0
  function ensureContent() { contentRequested = true; return body.item }
  function fittedContentWidth(value) { return Math.min(value, 500) }
  function fittedContentHeight(value, cap) { return Math.min(value, cap || 780) }
  width: contentWidth
  height: contentHeight
  Loader { id: body; anchors.fill: parent; active: root.contentRequested; sourceComponent: root.content }
}
