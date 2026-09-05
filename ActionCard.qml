import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One action inside a routine's action list or its end-of-routine list.
// The card only edits the action it was given; the editor owns the draft.
BorderSurface {
  id: card

  required property var modelData
  required property int index
  property int count: 0
  property bool endList: false
  property bool busy: false
  property var typeOptions: []
  property var appOptions: []
  property var commandOptions: []
  property var themeOptions: []
  property string argumentsText: "[]"
  property string errorText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent

  signal typeChanged(string type)
  signal fieldChanged(string key, var value)
  signal textStaged(string key, string value)
  signal argsStaged(string text)
  signal moveRequested(int delta)
  signal removeRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color subtle: Qt.darker(foreground, 1.5)
  readonly property string actionType: modelData ? String(modelData.type || "") : ""
  readonly property bool booleanSetter: actionType === "nightlight" || actionType === "dnd" || actionType === "stay-awake"
  readonly property bool setter: booleanSetter || actionType === "theme" || actionType === "brightness"
  readonly property string ordinal: String(index + 1)

  function setterLabel() {
    var on = modelData && modelData.value === true
    switch (actionType) {
      case "nightlight": return on ? "Turn night light on" : "Turn night light off"
      case "dnd": return on ? "Turn do not disturb on" : "Turn do not disturb off"
      case "stay-awake": return on ? "Keep the system awake" : "Allow idle lock and screensaver"
    }
    return ""
  }

  // After a move the card is rebuilt in its new place; the editor asks the
  // new card to take focus on the button that was just pressed.
  function focusMoveButton(delta) {
    var target = delta < 0 ? moveUp : moveDown
    if (!target.enabled) target = delta < 0 ? moveDown : moveUp
    target.forceActiveFocus()
  }

  implicitHeight: content.implicitHeight + Style.space(24)
  radius: Style.cornerRadius
  color: errorText ? Util.alpha(urgent, 0.10) : Style.normalFillFor(foreground, accent)
  borderSpec: errorText ? Border.flat(Util.alpha(urgent, 0.35), 1) : Border.flat(Util.alpha(foreground, 0.10), 1)
  Behavior on color { ColorAnimation { duration: 120 } }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.spacing.rowGap

    Row {
      width: parent.width
      spacing: Style.spacing.rowGap

      Text {
        textFormat: Text.PlainText
        width: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: card.ordinal
        color: card.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      ChoicePicker {
        width: parent.width - Style.space(18) - actionButtons.width - parent.spacing * 2
        showLabel: false
        value: card.actionType
        options: card.typeOptions
        foreground: card.foreground
        accent: card.accent
        onChanged: function(value) { card.typeChanged(value) }
        Accessible.name: (card.endList ? "End action " : "Action ") + card.ordinal + " type"
      }

      Row {
        id: actionButtons
        spacing: Style.spacing.sm
        PanelActionButton {
          id: moveUp
          iconText: "󰅃"
          tooltipText: "Move earlier"
          focusable: true
          foreground: card.foreground
          size: Style.spacing.controlHeight
          enabled: card.index > 0
          opacity: enabled ? 1 : 0.35
          onClicked: card.moveRequested(-1)
          Accessible.role: Accessible.Button
          Accessible.name: "Move action " + card.ordinal + " earlier"
        }
        PanelActionButton {
          id: moveDown
          iconText: "󰅀"
          tooltipText: "Move later"
          focusable: true
          foreground: card.foreground
          size: Style.spacing.controlHeight
          enabled: card.index < card.count - 1
          opacity: enabled ? 1 : 0.35
          onClicked: card.moveRequested(1)
          Accessible.role: Accessible.Button
          Accessible.name: "Move action " + card.ordinal + " later"
        }
        PanelActionButton {
          iconText: "󰅙"
          tooltipText: "Remove action"
          focusable: true
          foreground: card.foreground
          hoverColor: card.urgent
          size: Style.spacing.controlHeight
          onClicked: card.removeRequested()
          Accessible.role: Accessible.Button
          Accessible.name: "Remove action " + card.ordinal
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: card.errorText !== ""
      width: parent.width
      text: card.errorText
      color: card.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Column {
      visible: card.setter
      width: parent.width
      spacing: Style.spacing.rowGap

      PendingToggle {
        busy: card.busy
        visible: card.booleanSetter
        width: parent.width
        label: card.setterLabel()
        description: card.actionType === "stay-awake"
          ? "Uses the Omarchy idle service, the same state as the stay-awake indicator."
          : "Applied through the Omarchy shell, so the bar indicator follows."
        checked: card.modelData && card.modelData.value === true
        foreground: card.foreground
        accent: card.accent
        activeFocusOnTab: true
        onClicked: card.fieldChanged("value", !checked)
        Accessible.role: Accessible.CheckBox
        Accessible.name: card.setterLabel()
        Accessible.checkable: true
        Accessible.checked: checked
      }

      ChoicePicker {
        visible: card.actionType === "theme"
        searchable: true
        width: parent.width
        label: "Theme"
        value: card.modelData && card.modelData.value ? String(card.modelData.value) : ""
        options: card.themeOptions
        placeholderText: "Search installed themes..."
        foreground: card.foreground
        accent: card.accent
        onChanged: function(value) { card.fieldChanged("value", value) }
        Accessible.name: "Theme"
      }

      NumberField {
        visible: card.actionType === "brightness"
        label: "Display brightness (%)"
        value: card.modelData && typeof card.modelData.value === "number" ? card.modelData.value : 50
        from: 0
        to: 100
        stepSize: 5
        foreground: card.foreground
        accent: card.accent
        onModified: function(value) { card.fieldChanged("value", value) }
        Component.onCompleted: field.Accessible.name = label
      }

      PendingToggle {
        busy: card.busy
        visible: !card.endList
        width: parent.width
        label: "Put it back when the routine ends"
        description: "The value is recorded before this routine changes it and restored unless you changed it yourself in the meantime."
        checked: card.modelData && card.modelData.restore === true
        foreground: card.foreground
        accent: card.accent
        activeFocusOnTab: true
        onClicked: card.fieldChanged("restore", !checked)
        Accessible.role: Accessible.CheckBox
        Accessible.name: "Restore the previous value when the routine ends"
        Accessible.checkable: true
        Accessible.checked: checked
      }
    }

    Column {
      visible: card.actionType === "microphone-toggle"
      width: parent.width
      spacing: Style.spacing.rowGap

      PendingToggle {
        busy: card.busy
        width: parent.width
        label: "State-dependent sound"
        description: "Play one cue when muted and another when live."
        checked: card.modelData && card.modelData.sound === true
        foreground: card.foreground
        accent: card.accent
        activeFocusOnTab: true
        onClicked: card.fieldChanged("sound", !checked)
        Accessible.role: Accessible.CheckBox
        Accessible.name: "State-dependent microphone sound"
        Accessible.checkable: true
        Accessible.checked: checked
      }
      Column {
        visible: card.modelData && card.modelData.sound === true
        width: parent.width
        spacing: Style.spacing.labelGap
        Text {
          textFormat: Text.PlainText
          text: "Muted sound"
          color: card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: (card.modelData && card.modelData.mutedSound) || ""
          foreground: card.foreground
          accent: card.accent
          onTextEdited: card.textStaged("mutedSound", text)
          Accessible.name: "Muted sound file"
        }
      }
      Column {
        visible: card.modelData && card.modelData.sound === true
        width: parent.width
        spacing: Style.spacing.labelGap
        Text {
          textFormat: Text.PlainText
          text: "Live sound"
          color: card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: (card.modelData && card.modelData.liveSound) || ""
          foreground: card.foreground
          accent: card.accent
          onTextEdited: card.textStaged("liveSound", text)
          Accessible.name: "Live sound file"
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
      foreground: card.foreground
      accent: card.accent
      onChanged: function(value) { card.fieldChanged("desktopId", value) }
      Accessible.name: "Application"
    }

    Column {
      visible: card.actionType === "omarchy-command"
      width: parent.width
      spacing: Style.spacing.rowGap

      ChoicePicker {
        searchable: true
        width: parent.width
        label: "Command"
        value: (card.modelData && card.modelData.route) || ""
        options: card.commandOptions
        placeholderText: "Search Omarchy commands..."
        foreground: card.foreground
        accent: card.accent
        onChanged: function(value) { card.fieldChanged("route", value) }
        Accessible.name: "Omarchy command"
      }
      Column {
        width: parent.width
        spacing: Style.spacing.labelGap
        Text {
          textFormat: Text.PlainText
          text: "Arguments as JSON"
          color: card.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: card.argumentsText
          placeholderText: "[\"value\", \"another value\"]"
          foreground: card.foreground
          accent: card.accent
          onTextEdited: card.argsStaged(text)
          Accessible.name: "Arguments as JSON"
        }
      }
    }

    Column {
      visible: card.actionType === "notification"
      width: parent.width
      spacing: Style.spacing.rowGap
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.title) || ""
        placeholderText: "Notification title"
        foreground: card.foreground
        accent: card.accent
        onTextEdited: card.textStaged("title", text)
        Accessible.name: "Notification title"
      }
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.body) || ""
        placeholderText: "Optional detail"
        foreground: card.foreground
        accent: card.accent
        onTextEdited: card.textStaged("body", text)
        Accessible.name: "Notification detail"
      }
      Row {
        width: parent.width
        spacing: Style.spacing.rowGap
        ChoicePicker {
          width: Math.min(Style.space(220), parent.width * 0.45)
          label: "Urgency"
          value: (card.modelData && card.modelData.urgency) || "low"
          options: ["low", "normal", "critical"]
          foreground: card.foreground
          accent: card.accent
          onChanged: function(value) { card.fieldChanged("urgency", value) }
          Accessible.name: "Notification urgency"
        }
        TextField {
          width: parent.width - parent.spacing - Math.min(Style.space(220), parent.width * 0.45)
          anchors.bottom: parent.bottom
          text: (card.modelData && card.modelData.glyph) || ""
          placeholderText: "Optional glyph"
          foreground: card.foreground
          accent: card.accent
          onTextEdited: card.textStaged("glyph", text)
          Accessible.name: "Notification glyph"
        }
      }
    }

    Column {
      visible: card.actionType === "osd"
      width: parent.width
      spacing: Style.spacing.rowGap
      Row {
        width: parent.width
        spacing: Style.spacing.rowGap
        TextField {
          width: parent.width * 0.34
          text: (card.modelData && card.modelData.icon) || ""
          placeholderText: "Icon name"
          foreground: card.foreground
          accent: card.accent
          onTextEdited: card.textStaged("icon", text)
          Accessible.name: "OSD icon name"
        }
        TextField {
          width: parent.width - parent.spacing - parent.width * 0.34
          text: (card.modelData && card.modelData.message) || ""
          placeholderText: "OSD message"
          foreground: card.foreground
          accent: card.accent
          onTextEdited: card.textStaged("message", text)
          Accessible.name: "OSD message"
        }
      }
      Row {
        spacing: Style.spacing.panelGap
        NumberField {
          label: "Progress (-1 hides)"
          value: card.modelData && card.modelData.progress !== undefined ? card.modelData.progress : -1
          from: -1
          to: 100
          foreground: card.foreground
          accent: card.accent
          onModified: function(value) { card.fieldChanged("progress", value) }
          Component.onCompleted: field.Accessible.name = label
        }
        NumberField {
          label: "Duration (ms)"
          value: (card.modelData && card.modelData.duration) || 0
          from: 0
          to: 60000
          stepSize: 100
          foreground: card.foreground
          accent: card.accent
          onModified: function(value) { card.fieldChanged("duration", value) }
          Component.onCompleted: field.Accessible.name = label
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
        color: card.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.path) || ""
        foreground: card.foreground
        accent: card.accent
        onTextEdited: card.textStaged("path", text)
        Accessible.name: "Audio file path"
      }
    }

    NumberField {
      visible: card.actionType === "delay"
      label: "Delay in milliseconds"
      value: (card.modelData && card.modelData.milliseconds) || 0
      from: 0
      to: 300000
      stepSize: 100
      foreground: card.foreground
      accent: card.accent
      onModified: function(value) { card.fieldChanged("milliseconds", value) }
      Component.onCompleted: field.Accessible.name = label
    }

    Column {
      visible: card.actionType === "exec"
      width: parent.width
      spacing: Style.spacing.rowGap
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.program) || ""
        placeholderText: "Executable or absolute path"
        foreground: card.foreground
        accent: card.accent
        onTextEdited: card.textStaged("program", text)
        Accessible.name: "Program to run"
      }
      TextField {
        width: parent.width
        text: card.argumentsText
        placeholderText: "Arguments as JSON: [\"one\", \"two\"]"
        foreground: card.foreground
        accent: card.accent
        onTextEdited: card.argsStaged(text)
        Accessible.name: "Program arguments as JSON"
      }
    }

    Column {
      visible: card.actionType === "shell"
      width: parent.width
      spacing: Style.spacing.rowGap
      BorderSurface {
        width: parent.width
        implicitHeight: warningText.implicitHeight + Style.space(16)
        color: Util.alpha(card.urgent, 0.10)
        borderSpec: Border.flat(Util.alpha(card.urgent, 0.35), 1)
        radius: Style.cornerRadius
        Text {
          textFormat: Text.PlainText
          id: warningText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.rightMargin: Style.spacing.rowPaddingX
          text: "Advanced: this command is interpreted by bash and is not sandboxed."
          color: card.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
      TextField {
        width: parent.width
        text: (card.modelData && card.modelData.command) || ""
        placeholderText: "bash command"
        foreground: card.foreground
        accent: card.accent
        onTextEdited: card.textStaged("command", text)
        Accessible.name: "Shell command"
      }
    }
  }
}
