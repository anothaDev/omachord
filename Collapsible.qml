import QtQuick
import qs.Commons

// Reveals or hides a block inside a Column without snapping its siblings:
// the clip slides open to the content's height and fades in, and drops
// out of the Column's spacing only once it has actually reached zero.
Item {
  id: root

  property bool shown: true
  property real spacing: Style.space(12)
  default property alias content: inner.data

  clip: true
  width: parent ? parent.width : 0
  visible: height > 0
  height: shown ? inner.implicitHeight : 0
  implicitHeight: height
  opacity: shown ? 1 : 0

  Behavior on height {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }
  Behavior on opacity {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Column {
    id: inner
    width: parent.width
    anchors.bottom: parent.bottom
    spacing: root.spacing
  }
}
