import QtQuick
import qs.Commons
import qs.Ui

// App-local switch. The caller owns checked and the async operation's busy
// state; presentation changes must never change the space reserved for it.
Item {
  id: root

  property bool checked: false
  property bool busy: false
  property bool interactive: true
  property bool hasCursor: false

  // A row explicitly opts out of the ring. Disabling activation does not
  // remove its padding (including while an operation is in flight).
  property bool cursorRing: true
  property int cursorPad: Style.space(6)
  property bool rounded: Style.cornerRadius > 0
  property color foreground: Color.foreground
  property color accent: Color.accent

  property int trackHeight: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
  property int trackWidth: Math.round(trackHeight * 1.9)
  property int knobSize: Math.max(6, Math.round(trackHeight * 0.72))
  property int knobInset: Math.max(1, Math.round((trackHeight - knobSize) / 2))

  signal toggled()
  signal hovered(bool isHovered)

  readonly property alias containsMouse: mouse.containsMouse
  readonly property bool loadingVisible: spinner.visible
  readonly property bool _hot: hasCursor || mouse.containsMouse
  readonly property int _pad: cursorRing ? cursorPad : 0

  implicitWidth: trackWidth + _pad * 2
  implicitHeight: trackHeight + _pad * 2

  function requestToggle() {
    if (!enabled || !interactive || busy) return false
    toggled()
    return true
  }

  // Keep existing focus when activation is suspended. Qt does not allow
  // removing a focused item from the tab chain until focus moves elsewhere.
  activeFocusOnTab: interactive || activeFocus
  Accessible.role: Accessible.CheckBox
  Accessible.checkable: true
  Accessible.checked: checked
  Accessible.description: busy ? "Changing state" : ""
  Accessible.onPressAction: root.requestToggle()
  Accessible.onToggleAction: root.requestToggle()

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Space || event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
      if (!event.isAutoRepeat) root.requestToggle()
      event.accepted = true
    }
  }

  BorderSurface {
    anchors.fill: parent
    visible: root.cursorRing && (root._hot || root.activeFocus)
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.controlSpec(root.activeFocus ? "focus" : "hover-cursor", root.foreground, root.accent)
  }

  BorderSurface {
    id: track
    width: root.trackWidth
    height: root.trackHeight
    anchors.centerIn: parent
    radius: root.rounded ? height / 2 : 0
    color: root.checked
      ? Style.selectedFillFor(root.foreground, root.accent)
      : Style.normalFillFor(root.foreground, root.accent)
    borderSpec: Border.controlSpec(root.checked ? "selected" : "normal", root.foreground, root.accent)

    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      objectName: "pendingSwitchThumb"
      visible: !root.busy
      width: root.knobSize
      height: root.knobSize
      radius: root.rounded ? height / 2 : 0
      x: root.checked ? track.width - width - root.knobInset : root.knobInset
      anchors.verticalCenter: parent.verticalCenter
      color: root.checked ? Style.selectedStateColor(root.foreground, root.accent) : Qt.darker(root.foreground, 1.25)

      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    Text {
      textFormat: Text.PlainText
      id: spinner
      objectName: "pendingSwitchSpinner"
      visible: root.busy && root.visible
      anchors.centerIn: parent
      width: root.knobSize
      height: root.knobSize
      text: "󰦖"
      color: root.checked ? Style.selectedStateColor(root.foreground, root.accent) : Qt.darker(root.foreground, 1.25)
      font.family: Style.font.family
      font.pixelSize: root.knobSize
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      Accessible.ignored: true

      NumberAnimation on rotation {
        objectName: "pendingSwitchSpinnerAnimation"
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        running: spinner.visible
      }
    }
  }

  MouseArea {
    id: mouse
    // Keep busy gestures accepted by this area, but never turn a press that
    // began busy into a new request merely because it settles before release.
    property bool pressEligible: false
    readonly property bool activationAllowed: root.enabled && root.interactive && !root.busy
    // A suspension invalidates the whole gesture, even if it clears again
    // before release. Only a fresh press may become eligible.
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
