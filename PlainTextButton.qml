import QtQuick
import qs.Commons
import qs.Ui

Button {
  id: root

  property string plainText: ""

  text: ""
  implicitWidth: label.implicitWidth + horizontalPadding * 2 + 2
  implicitHeight: Math.max(Style.spacing.controlHeight, label.implicitHeight + verticalPadding * 2 + 2)

  Text {
    textFormat: Text.PlainText
    id: label
    text: root.plainText
    color: root.selected ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: root.selected
    elide: Text.ElideRight
    anchors.left: root.leftAlign ? parent.left : undefined
    anchors.right: root.leftAlign ? parent.right : undefined
    anchors.leftMargin: root.leftAlign ? root.horizontalPadding : 0
    anchors.rightMargin: root.leftAlign ? root.horizontalPadding : 0
    anchors.horizontalCenter: root.leftAlign ? undefined : parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
  }
}
