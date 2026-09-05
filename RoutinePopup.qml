import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Conditions.js" as Conditions

// The body of the Omachord bar popup: the active routines, each with a way
// to end it. Kept separate from BarWidget.qml so it can be rendered and
// reviewed without a bar or a layer-shell window.
Column {
  id: popup

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color success: Color.accent
  property string fontFamily: Style.font.family
  property string icon: ""
  property var rows: []
  property bool busy: false
  // Null means an older service only exposes the global busy flag. Newer
  // services publish a per-routine map so unrelated rows remain actionable.
  property var pendingIds: null
  property bool serviceAvailable: true
  property bool integrationOn: true
  property bool integrationBusy: false
  property string summary: ""
  property int cursorIndex: -1
  property bool cursorOnFooter: false
  property date displayNow: new Date()

  signal endRequested(string id)
  signal openRequested()
  signal integrationToggled()
  signal rowHovered(int index)

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color subtle: Qt.darker(foreground, 1.5)

  // Short on purpose: the popup is 380 wide and the window has the long form.
  function rowMeta(row) {
    var parts = []
    var since = Conditions.clockTime(row.activatedAt)
    if (since) parts.push("Since " + since)
    if (row.expiresAt) {
      var left = Conditions.minutesLeft(row.expiresAt, displayNow)
      parts.push(left !== null && left >= 0 ? (left < 1 ? "ending now" : left + " min left") : "until " + Conditions.clockTime(row.expiresAt))
    } else if (row.conditions > 0) parts.push("while conditions hold")
    else {
      var started = Model.triggerLabel(row.trigger)
      if (started) parts.push(started)
    }
    return parts.join(" · ")
  }

  function endingLabel(row) {
    if (row.onEndMode === "none") return "leaves settings as they are"
    var count = Number(row.setterCount || 0)
    if (count > 0) return "restores " + count + (count === 1 ? " setting" : " settings")
    return row.onEndMode === "actions" ? "runs its end actions" : ""
  }

  function rowCaption(row) {
    var parts = [rowMeta(row), endingLabel(row)]
    return parts.filter(function(part) { return part !== "" }).join(" · ")
  }

  function rowBusy(id) {
    if (pendingIds !== null && pendingIds !== undefined)
      return pendingIds[String(id)] === true
    return busy
  }

  spacing: Style.space(14)

  Timer {
    interval: 60000
    repeat: true
    running: popup.visible && popup.rows.length > 0
    onRunningChanged: if (running) popup.displayNow = new Date()
    onTriggered: popup.displayNow = new Date()
  }

  PanelHero {
    width: parent.width
    title: "Omachord"
    meta: popup.rows.length ? (popup.rows.length === 1 ? "1 routine on" : popup.rows.length + " routines on")
      : (popup.serviceAvailable ? (popup.integrationOn ? "Nothing on" : "Off") : "Service unavailable")
    foreground: popup.foreground
    fontFamily: popup.fontFamily
    iconComponent: Component {
      Text {
        textFormat: Text.PlainText
        text: popup.icon
        color: popup.foreground
        opacity: popup.integrationOn ? 1 : 0.5
        font.family: popup.fontFamily
        font.pixelSize: Style.font.display
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      }
    }
    trailingControl: Component {
      ToggleSwitch {
        checked: popup.integrationOn
        busy: popup.integrationBusy
        interactive: popup.serviceAvailable && !popup.integrationBusy
          && (!popup.integrationOn || popup.rows.length === 0)
        foreground: popup.foreground
        accent: popup.accent
        onToggled: popup.integrationToggled()
        Accessible.role: Accessible.CheckBox
        Accessible.name: popup.integrationOn ? "Turn Omachord off" : "Turn Omachord on"
        Accessible.checkable: true
        Accessible.checked: checked
        PanelToolTip {
          visible: parent.containsMouse
          text: popup.integrationOn
            ? (popup.rows.length
              ? "End active routines before turning Omachord off"
              : "Turn Omachord off. Saved routines stay.")
            : "Turn Omachord on"
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: popup.rows.length === 0
    width: parent.width
    text: popup.serviceAvailable
      ? (popup.integrationOn
        ? "Modes show here while they are on, with a way to end them."
        : "Omachord is off. Turn it on to let shortcuts, events, and conditions start routines.")
      : "The Omachord service is not loaded in this shell."
    color: popup.subtle
    font.family: popup.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  Column {
    visible: popup.rows.length > 0
    width: parent.width
    spacing: Style.space(4)

    PanelSectionHeader {
      width: parent.width
      text: "ON NOW"
      foreground: popup.foreground
      fontFamily: popup.fontFamily
    }

    Repeater {
      model: popup.rows

      CursorSurface {
        id: row
        required property var modelData
        required property int index
        readonly property bool cursor: popup.cursorIndex === index && !popup.cursorOnFooter
        width: parent.width
        implicitHeight: rowInner.implicitHeight + Style.space(14)
        radius: Style.cornerRadius
        foreground: popup.foreground
        accent: popup.accent
        hasCursor: cursor || rowHover.hovered
        Accessible.role: Accessible.ListItem
        Accessible.name: String(modelData.name || modelData.id) + ", on"

        HoverHandler {
          id: rowHover
          onHoveredChanged: if (hovered) popup.rowHovered(row.index)
        }

        Row {
          id: rowInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: row.borderLeft + Style.space(10)
          anchors.rightMargin: row.borderRight + Style.space(6)
          spacing: Style.space(10)

          Rectangle {
            id: pulse
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            color: popup.success

            SequentialAnimation on opacity {
              running: pulse.visible && popup.visible
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.35; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
            }
          }

          Column {
            width: parent.width - pulse.width - endButton.width - parent.spacing * 2
            spacing: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: String(row.modelData.name || row.modelData.id)
              color: popup.foreground
              font.family: popup.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: popup.rowCaption(row.modelData)
              visible: text !== ""
              color: popup.dim
              font.family: popup.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: endButton
            readonly property bool ending: popup.rowBusy(row.modelData.id)
            anchors.verticalCenter: parent.verticalCenter
            iconText: ending ? "󰦖" : "󰅙"
            tooltipText: "End " + String(row.modelData.name || row.modelData.id)
            foreground: popup.foreground
            hoverColor: popup.urgent
            hasCursor: row.cursor
            size: Style.spacing.controlHeight
            enabled: !ending && !popup.integrationBusy
            opacity: row.hasCursor || ending ? 1 : 0.45
            onClicked: popup.endRequested(String(row.modelData.id))
            Accessible.role: Accessible.Button
            Accessible.name: "End " + String(row.modelData.name || row.modelData.id)
            Behavior on opacity { NumberAnimation { duration: 120 } }
          }
        }
      }
    }
  }

  PanelSeparator {
    width: parent.width
    foreground: popup.foreground
  }

  Button {
    width: parent.width
    iconText: "󰒓"
    text: "Open Omachord"
    tooltipText: "Enter ends the highlighted routine · o opens Omachord"
    bordered: true
    leftAlign: true
    foreground: popup.foreground
    accent: popup.accent
    hasCursor: popup.cursorOnFooter
    onClicked: popup.openRequested()
    Accessible.role: Accessible.Button
    Accessible.name: "Open the Omachord panel"
  }
}
