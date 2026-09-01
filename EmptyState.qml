import QtQuick
import qs.Commons
import qs.Ui

// Centred placeholder for a list or section with nothing to show: a big
// glyph, a title, a short explanation, and an optional call to action.
Item {
  id: root

  property string glyph: ""
  property string title: ""
  property string body: ""
  property string actionText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal actionClicked()

  width: parent ? parent.width : implicitWidth
  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      visible: root.glyph !== ""
      width: parent.width
      text: root.glyph
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      textFormat: Text.PlainText
      visible: root.title !== ""
      width: parent.width
      text: root.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.body !== ""
      width: parent.width
      text: root.body
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Button {
      visible: root.actionText !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.actionText
      bordered: true
      focusable: true
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.actionClicked()
      Accessible.role: Accessible.Button
      Accessible.name: root.actionText
    }
  }
}
