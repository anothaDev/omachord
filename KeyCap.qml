import QtQuick
import qs.Commons
import qs.Ui

// One key of a keyboard chord, drawn as a small key-cap chip. Callers
// Repeat over `keys.split(" + ")` and let the enclosing row announce the
// whole chord, so each cap stays out of the accessibility tree.
BorderSurface {
  id: root

  property string text: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  Accessible.ignored: true

  implicitWidth: cap.implicitWidth + Style.space(10)
  implicitHeight: cap.implicitHeight + Style.space(4)
  radius: Style.cornerRadius
  color: Style.normalFillFor(foreground, accent)
  borderSpec: Border.controlSpec("normal", foreground, accent)

  Text {
    textFormat: Text.PlainText
    id: cap
    anchors.centerIn: parent
    text: root.text.toUpperCase()
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
