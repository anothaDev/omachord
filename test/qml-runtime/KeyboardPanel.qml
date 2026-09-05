import QtQuick

// Only the layer-shell window is stubbed: it has no offscreen backend.
// BarIconButton, PanelController, BrandIcon and the popup body remain real.
Item {
  required property Item anchorItem
  required property QtObject bar
  property var owner
  property bool open: false
  property Item focusTarget
  property int contentWidth
  property int contentHeight
  function fittedContentWidth(value) { return value }
  function fittedContentHeight(value) { return value }
}
