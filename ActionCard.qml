import QtQuick
import qs.Commons
import qs.Ui

// One action inside a routine's action list or its end-of-routine list.
// The card only edits the action it was given; the editor owns the draft.
BorderSurface {
  id: card

  required property var modelData
  required property int index
  property int count: 0
  property bool endList: false
  property var typeOptions: []
  property var appOptions: []
  property var commandOptions: []
  property var themeOptions: []
  property string argumentsText: "[]"

  signal typeChanged(string type)
  signal fieldChanged(string key, var value)
  signal textStaged(string key, string value)
  signal argsStaged(string text)
  signal moveRequested(int delta)
  signal removeRequested()

  readonly property string actionType: modelData ? String(modelData.type || "") : ""
  readonly property bool booleanSetter: actionType === "nightlight" || actionType === "dnd" || actionType === "stay-awake"
  readonly property bool setter: booleanSetter || actionType === "theme" || actionType === "brightness"

  function setterLabel() {
    var on = modelData && modelData.value === true
    switch (actionType) {
      case "nightlight": return on ? "Turn night light on" : "Turn night light off"
      case "dnd": return on ? "Turn do not disturb on" : "Turn do not disturb off"
      case "stay-awake": return on ? "Keep the system awake" : "Allow idle lock and screensaver"
    }
    return ""
  }

  implicitHeight: content.implicitHeight + Style.space(24)
  radius: Style.cornerRadius
  color: Util.alpha(Color.foreground, 0.035)
  borderSpec: Border.flat(Util.alpha(Color.foreground, 0.14), 1)

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(12)

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        width: Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        text: String(card.index + 1).padStart(2, "0")
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      ChoicePicker {
        width: parent.width - Style.space(24) - actionButtons.width - parent.spacing * 2
        showLabel: false
        value: card.actionType
        options: card.typeOptions
        onChanged: function(value) { card.typeChanged(value) }
      }

      Row {
        id: actionButtons
        spacing: Style.space(3)
        PanelActionButton {
          iconText: "^"
          tooltipText: "Move earlier"
          focusable: true
          enabled: card.index > 0
          onClicked: card.moveRequested(-1)
        }
        PanelActionButton {
          iconText: "v"
          tooltipText: "Move later"
          focusable: true
          enabled: card.index < card.count - 1
          onClicked: card.moveRequested(1)
        }
        PanelActionButton {
          iconText: "x"
          tooltipText: "Remove action"
          focusable: true
          hoverColor: Color.urgent
          onClicked: card.removeRequested()
        }
      }
    }

    Column {
      visible: card.setter
      width: parent.width
      spacing: Style.space(10)

      Toggle {
        visible: card.booleanSetter
        width: parent.width
        label: card.setterLabel()
        description: card.actionType === "stay-awake"
          ? "Uses the Omarchy idle service, the same state as the stay-awake indicator."
          : "Applied through the Omarchy shell, so the bar indicator follows."
        checked: card.modelData && card.modelData.value === true
        onClicked: card.fieldChanged("value", !checked)
        Accessible.role: Accessible.CheckBox
        Accessible.name: card.setterLabel()
        Accessible.checkable: true
        Accessible.checked: checked
        Accessible.onPressAction: clicked()
      }

      ChoicePicker {
        visible: card.actionType === "theme"
        searchable: true
        width: parent.width
        label: "Theme"
        value: card.modelData && card.modelData.value ? String(card.modelData.value) : ""
        options: card.themeOptions
        placeholderText: "Search installed themes..."
        onChanged: function(value) { card.fieldChanged("value", value) }
      }

      NumberField {
        visible: card.actionType === "brightness"
        label: "Display brightness (%)"
        value: card.modelData && typeof card.modelData.value === "number" ? card.modelData.value : 50
        from: 0
        to: 100
        stepSize: 5
        onModified: function(value) { card.fieldChanged("value", value) }
      }

      Toggle {
        visible: !card.endList
        width: parent.width
        label: "Return to previous state when routine ends"
        description: "The value is recorded before this routine changes it and restored unless you changed it yourself in the meantime."
        checked: card.modelData && card.modelData.restore === true
        onClicked: card.fieldChanged("restore", !checked)
        Accessible.role: Accessible.CheckBox
        Accessible.name: "Restore previous value when routine ends"
        Accessible.checkable: true
        Accessible.checked: checked
        Accessible.onPressAction: clicked()
      }
    }

    Column {
      visible: card.actionType === "microphone-toggle"
      width: parent.width
      spacing: Style.space(10)

      Toggle {
        width: parent.width
        label: "State-dependent sound"
        description: "Play one cue when muted and another when live."
        checked: card.modelData && card.modelData.sound === true
        onClicked: card.fieldChanged("sound", !checked)
        Accessible.role: Accessible.CheckBox
        Accessible.name: "State-dependent microphone sound"
        Accessible.checkable: true
        Accessible.checked: checked
        Accessible.onPressAction: clicked()
      }
      Column {
        visible: card.modelData && card.modelData.sound === true
        width: parent.width
        spacing: Style.spacing.labelGap
        Text {
          textFormat: Text.PlainText
          text: "Muted sound"
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: (card.modelData && card.modelData.mutedSound) || ""
          onTextEdited: card.textStaged("mutedSound", text)
        }
      }
      Column {
        visible: card.modelData && card.modelData.sound === true
        width: parent.width
        spacing: Style.spacing.labelGap
        Text {
          textFormat: Text.PlainText
          text: "Live sound"
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: (card.modelData && card.modelData.liveSound) || ""
          onTextEdited: card.textStaged("liveSound", text)
        }
      }
    }

    ChoicePicker {
      visible: card.actionType === "launch-app"
      searchable: true
      width: parent.width
      label: "Application"
      value: (card.modelData && card.modelData.desktopId) || ""
      options: card.appOptions
      placeholderText: "Search applications..."
      onChanged: function(value) { card.fieldChanged("desktopId", value) }
    }

    Column {
      visible: card.actionType === "omarchy-command"
      width: parent.width
      spacing: Style.space(10)

      ChoicePicker {
        searchable: true
        width: parent.width
        label: "Command"
        value: (card.modelData && card.modelData.route) || ""
        options: card.commandOptions
        placeholderText: "Search Omarchy commands..."
        onChanged: function(value) { card.fieldChanged("route", value) }
      }
      Column {
        width: parent.width
        spacing: Style.spacing.labelGap
        Text {
          textFormat: Text.PlainText
          text: "Arguments as JSON"
          color: Qt.darker(Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: card.argumentsText
          placeholderText: "[\"value\", \"another value\"]"
          onTextEdited: card.argsStaged(text)
        }
      }
    }

    Column {
      visible: card.actionType === "notification"
      width: parent.width
      spacing: Style.space(10)
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.title) || ""
        placeholderText: "Notification title"
        onTextEdited: card.textStaged("title", text)
      }
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.body) || ""
        placeholderText: "Optional detail"
        onTextEdited: card.textStaged("body", text)
      }
      Row {
        width: parent.width
        spacing: Style.space(10)
        ChoicePicker {
          width: Math.min(Style.space(220), parent.width * 0.45)
          label: "Urgency"
          value: (card.modelData && card.modelData.urgency) || "low"
          options: ["low", "normal", "critical"]
          onChanged: function(value) { card.fieldChanged("urgency", value) }
        }
        TextField {
          width: parent.width - parent.spacing - Math.min(Style.space(220), parent.width * 0.45)
          anchors.bottom: parent.bottom
          text: (card.modelData && card.modelData.glyph) || ""
          placeholderText: "Optional glyph"
          onTextEdited: card.textStaged("glyph", text)
        }
      }
    }

    Column {
      visible: card.actionType === "osd"
      width: parent.width
      spacing: Style.space(10)
      Row {
        width: parent.width
        spacing: Style.space(10)
        TextField {
          width: parent.width * 0.34
          text: (card.modelData && card.modelData.icon) || ""
          placeholderText: "Icon name"
          onTextEdited: card.textStaged("icon", text)
        }
        TextField {
          width: parent.width - parent.spacing - parent.width * 0.34
          text: (card.modelData && card.modelData.message) || ""
          placeholderText: "OSD message"
          onTextEdited: card.textStaged("message", text)
        }
      }
      Row {
        spacing: Style.space(16)
        NumberField {
          label: "Progress (-1 hides)"
          value: card.modelData && card.modelData.progress !== undefined ? card.modelData.progress : -1
          from: -1
          to: 100
          onModified: function(value) { card.fieldChanged("progress", value) }
        }
        NumberField {
          label: "Duration (ms)"
          value: (card.modelData && card.modelData.duration) || 0
          from: 0
          to: 60000
          stepSize: 100
          onModified: function(value) { card.fieldChanged("duration", value) }
        }
      }
    }

    Column {
      visible: card.actionType === "sound"
      width: parent.width
      spacing: Style.spacing.labelGap
      Text {
        textFormat: Text.PlainText
        text: "Audio file"
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.path) || ""
        onTextEdited: card.textStaged("path", text)
      }
    }

    NumberField {
      visible: card.actionType === "delay"
      label: "Delay in milliseconds"
      value: (card.modelData && card.modelData.milliseconds) || 0
      from: 0
      to: 300000
      stepSize: 100
      onModified: function(value) { card.fieldChanged("milliseconds", value) }
    }

    Column {
      visible: card.actionType === "exec"
      width: parent.width
      spacing: Style.space(10)
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.program) || ""
        placeholderText: "Executable or absolute path"
        onTextEdited: card.textStaged("program", text)
      }
      TextField {
        width: parent.width
        text: card.argumentsText
        placeholderText: "Arguments as JSON: [\"one\", \"two\"]"
        onTextEdited: card.argsStaged(text)
      }
    }

    Column {
      visible: card.actionType === "shell"
      width: parent.width
      spacing: Style.space(8)
      BorderSurface {
        width: parent.width
        implicitHeight: warningText.implicitHeight + Style.space(16)
        color: Util.alpha(Color.urgent, 0.07)
        borderSpec: Border.flat(Util.alpha(Color.urgent, 0.45), 1)
        radius: Style.cornerRadius
        Text {
          textFormat: Text.PlainText
          id: warningText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(9)
          anchors.rightMargin: Style.space(9)
          text: "Advanced: this command is interpreted by bash and is not sandboxed."
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.command) || ""
        placeholderText: "bash command"
        onTextEdited: card.textStaged("command", text)
      }
    }
  }
}
