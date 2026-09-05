import QtQuick
import qs.Commons
import qs.Ui

// Labeled async toggle. The entire row owns activation; callers update checked
// and busy in response to clicked(), just as for the bare PendingSwitch.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool checked: false
  property bool busy: false
  property bool interactive: true
  property bool hasCursor: false
  property bool rounded: Style.cornerRadius > 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real titleSize: Style.font.subtitle
  property real descriptionSize: Style.font.caption

  signal clicked()
  signal hovered(bool isHovered)

  readonly property alias containsMouse: mouse.containsMouse
  readonly property bool loadingVisible: track.loadingVisible
  readonly property bool _hot: hasCursor || mouse.containsMouse

  function requestToggle() {
    if (!enabled || !interactive || busy) return false
    clicked()
    return true
  }

  // Busy changes activation, not focus; an existing focus leaves naturally.
  activeFocusOnTab: interactive || activeFocus
  Accessible.role: Accessible.CheckBox
  Accessible.name: label
  Accessible.description: busy ? "Changing state" : description
  Accessible.checkable: true
  Accessible.checked: checked
  Accessible.onPressAction: root.requestToggle()
  Accessible.onToggleAction: root.requestToggle()

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Space || event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
      if (!event.isAutoRepeat) root.requestToggle()
      event.accepted = true
    }
  }

  implicitHeight: Math.max(54, content.implicitHeight + Style.spacing.huge)
  implicitWidth: Style.space(240)
  radius: Style.cornerRadius
  color: Style.controlFill(activeFocus, _hot, foreground, accent)
  borderSpec: Border.controlSpec(activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)

  Behavior on color { ColorAnimation { duration: 100 } }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX

    Column {
      width: Math.max(0, parent.width - track.width - parent.spacing)
      spacing: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        objectName: "pendingToggleLabel"
        text: root.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.titleSize
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        objectName: "pendingToggleDescription"
        visible: root.description !== ""
        text: root.description
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: root.descriptionSize
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    PendingSwitch {
      id: track
      objectName: "pendingToggleSwitch"
      checked: root.checked
      busy: root.busy
      rounded: root.rounded
      foreground: root.foreground
      accent: root.accent
      interactive: false
      cursorRing: false
      Accessible.ignored: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    // The row must consume a busy press without activating on a later release,
    // including when the press lands on its presentation-only switch.
    property bool pressEligible: false
    readonly property bool activationAllowed: root.enabled && root.interactive && !root.busy
    onActivationAllowedChanged: if (!activationAllowed) pressEligible = false
    anchors.fill: parent
    enabled: root.interactive
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: root.hovered(containsMouse)
    onPressed: pressEligible = activationAllowed
    onCanceled: pressEligible = false
    onClicked: {
      var eligible = pressEligible
      pressEligible = false
      root.forceActiveFocus()
      if (eligible) root.requestToggle()
    }
  }
}
