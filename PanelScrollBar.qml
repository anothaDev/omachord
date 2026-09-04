import QtQuick
import QtQuick.Controls as QQC
import qs.Commons

QQC.ScrollBar {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent

  implicitWidth: Style.space(10)
  implicitHeight: Style.space(10)
  padding: Style.space(2)
  hoverEnabled: true
  interactive: true
  policy: QQC.ScrollBar.AsNeeded
  minimumSize: height > 0 ? Math.min(1, Style.space(32) / height) : 0

  contentItem: Rectangle {
    implicitWidth: Style.space(6)
    implicitHeight: Style.space(6)
    radius: Math.min(Style.cornerRadius, Style.space(1))
    color: root.pressed
      ? Style.pressedStateColor(root.foreground, root.accent)
      : (root.hovered
        ? Style.hoverStateColor(root.foreground, root.accent)
        : Style.normalStateColor(root.foreground, root.accent))
    opacity: root.size >= 1 ? 0 : (root.pressed ? 0.9 : (root.hovered ? 0.68 : 0.45))

    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on opacity { NumberAnimation { duration: 100 } }
  }

  background: Item {}
}
