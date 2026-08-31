import QtQuick
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property var targetWindow: null
  property string value: ""
  property bool recording: false
  property bool captureGranted: false
  property bool captureFocused: false
  property string errorText: ""
  readonly property bool inhibitorActive: shortcutInhibitor.active

  signal captured(string keys)
  signal cleared()

  implicitHeight: content.implicitHeight

  function beginRecording() {
    errorText = ""
    captureGranted = false
    captureFocused = false
    recording = true
    shortcutInhibitor.enabled = true
    activationTimer.restart()
    Qt.callLater(function() { keySink.forceActiveFocus() })
  }

  function stopRecording() {
    recording = false
    captureGranted = false
    captureFocused = false
    shortcutInhibitor.enabled = false
    activationTimer.stop()
  }

  function isModifier(key) {
    return key === Qt.Key_Shift || key === Qt.Key_Control
      || key === Qt.Key_Alt || key === Qt.Key_Meta
      || key === Qt.Key_AltGr || key === Qt.Key_Super_L
      || key === Qt.Key_Super_R
  }

  function keyName(event) {
    var key = event.key
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F35) return "F" + (key - Qt.Key_F1 + 1)

    switch (key) {
      case Qt.Key_Space: return "SPACE"
      case Qt.Key_Tab: return "TAB"
      case Qt.Key_Backtab: return "TAB"
      case Qt.Key_Return: return "RETURN"
      case Qt.Key_Enter: return "ENTER"
      case Qt.Key_Escape: return "ESCAPE"
      case Qt.Key_Backspace: return "BACKSPACE"
      case Qt.Key_Delete: return "DELETE"
      case Qt.Key_Insert: return "INSERT"
      case Qt.Key_Home: return "HOME"
      case Qt.Key_End: return "END"
      case Qt.Key_PageUp: return "PAGEUP"
      case Qt.Key_PageDown: return "PAGEDOWN"
      case Qt.Key_Left: return "LEFT"
      case Qt.Key_Right: return "RIGHT"
      case Qt.Key_Up: return "UP"
      case Qt.Key_Down: return "DOWN"
      case Qt.Key_CapsLock: return "CAPSLOCK"
      case Qt.Key_NumLock: return "NUMLOCK"
      case Qt.Key_ScrollLock: return "SCROLLLOCK"
      case Qt.Key_Print: return "PRINT"
      case Qt.Key_Pause: return "PAUSE"
      case Qt.Key_Menu: return "MENU"
      case Qt.Key_Comma: return "comma"
      case Qt.Key_Period: return "period"
      case Qt.Key_Minus: return "minus"
      case Qt.Key_Equal: return "equal"
      case Qt.Key_Slash: return "slash"
      case Qt.Key_Semicolon: return "SEMICOLON"
      case Qt.Key_Apostrophe: return "APOSTROPHE"
      case Qt.Key_BracketLeft: return "BRACKETLEFT"
      case Qt.Key_BracketRight: return "BRACKETRIGHT"
      case Qt.Key_Backslash: return "BACKSLASH"
      case Qt.Key_QuoteLeft: return "GRAVE"
      case Qt.Key_VolumeUp: return "XF86AudioRaiseVolume"
      case Qt.Key_VolumeDown: return "XF86AudioLowerVolume"
      case Qt.Key_VolumeMute: return "XF86AudioMute"
      case Qt.Key_MicMute: return "XF86AudioMicMute"
      case Qt.Key_MediaPlay: return "XF86AudioPlay"
      case Qt.Key_MediaPause: return "XF86AudioPause"
      case Qt.Key_MediaTogglePlayPause: return "XF86AudioPlay"
      case Qt.Key_MediaNext: return "XF86AudioNext"
      case Qt.Key_MediaPrevious: return "XF86AudioPrev"
      case Qt.Key_MediaStop: return "XF86AudioStop"
      case Qt.Key_MonBrightnessUp: return "XF86MonBrightnessUp"
      case Qt.Key_MonBrightnessDown: return "XF86MonBrightnessDown"
      case Qt.Key_KeyboardBrightnessUp: return "XF86KbdBrightnessUp"
      case Qt.Key_KeyboardBrightnessDown: return "XF86KbdBrightnessDown"
      case Qt.Key_KeyboardLightOnOff: return "XF86KbdLightOnOff"
    }
    return ""
  }

  function chordForEvent(event) {
    var key = keyName(event)
    if (!key) return ""
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    parts.push(key)
    return parts.join(" + ")
  }

  ShortcutInhibitor {
    id: shortcutInhibitor
    window: root.targetWindow
    enabled: false

    onActiveChanged: {
      if (active) {
        root.captureGranted = true
        activationTimer.stop()
        Qt.callLater(function() { keySink.forceActiveFocus() })
      } else if (root.recording && root.captureGranted) {
        Qt.callLater(function() {
          if (root.recording && !shortcutInhibitor.active) {
            root.errorText = "Shortcut capture lost keyboard focus"
            root.stopRecording()
          }
        })
      }
    }
    onCancelled: {
      if (!root.recording) return
      root.errorText = "The compositor ended shortcut capture"
      root.stopRecording()
    }
  }

  Timer {
    id: activationTimer
    interval: 900
    repeat: false
    onTriggered: {
      if (!shortcutInhibitor.active && root.recording) {
        root.errorText = "Hyprland did not grant shortcut capture"
        root.stopRecording()
      }
    }
  }

  Column {
    id: content
    width: parent.width
    spacing: Style.spacing.labelGap

    Text {

      textFormat: Text.PlainText
      text: "Keyboard shortcut"
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      BorderSurface {
        width: parent.width - recordButton.width - clearButton.width - parent.spacing * 2
        height: Math.max(Style.spacing.controlHeight, keysRow.implicitHeight + Style.space(10))
        radius: Style.cornerRadius
        color: root.recording
          ? Style.focusFillFor(Color.foreground, Color.accent)
          : Style.normalFillFor(Color.foreground, Color.accent)
        borderSpec: Border.controlSpec(root.recording ? "focus" : "normal", Color.foreground, Color.accent)

        Row {
          id: keysRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.controlPaddingX
          spacing: Style.space(5)

          Text {

            textFormat: Text.PlainText
            visible: root.value === "" || root.recording
            text: root.recording
              ? (root.inhibitorActive ? "Press a combination..." : "Securing keyboard...")
              : "Not assigned"
            color: Qt.darker(Color.foreground, 1.45)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.recording || !root.value ? [] : root.value.split(" + ")

            BorderSurface {
              required property string modelData
              implicitWidth: keyText.implicitWidth + Style.space(12)
              height: Style.space(24)
              radius: Math.min(Style.cornerRadius, Style.space(4))
              color: Util.alpha(Color.foreground, 0.07)
              borderSpec: Border.flat(Util.alpha(Color.foreground, 0.24), 1)

              Text {

                textFormat: Text.PlainText
                id: keyText
                anchors.centerIn: parent
                text: modelData.toUpperCase()
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }
      }

      Button {
        id: recordButton
        text: root.recording ? "Cancel" : "Record"
        bordered: true
        focusable: true
        onClicked: root.recording ? root.stopRecording() : root.beginRecording()
        Accessible.name: text + " keyboard shortcut"
      }

      Button {
        id: clearButton
        text: "Clear"
        bordered: true
        focusable: true
        enabled: root.value !== "" && !root.recording
        onClicked: root.cleared()
        Accessible.name: "Clear keyboard shortcut"
      }
    }

    Text {

      textFormat: Text.PlainText
      visible: root.errorText !== ""
      width: parent.width
      text: root.errorText
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  FocusScope {
    id: keySink
    anchors.fill: parent
    visible: root.recording
    focus: root.recording
    z: 20

    onActiveFocusChanged: {
      if (activeFocus) {
        root.captureFocused = true
      } else if (root.recording && root.captureFocused) {
        Qt.callLater(function() {
          if (!keySink.activeFocus && root.recording) root.stopRecording()
        })
      }
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (!root.recording || event.isAutoRepeat) {
        event.accepted = root.recording
        return
      }
      if (!shortcutInhibitor.active) {
        event.accepted = true
        return
      }
      if (root.isModifier(event.key)) {
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
        root.stopRecording()
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Backspace && event.modifiers === Qt.NoModifier) {
        root.stopRecording()
        root.cleared()
        event.accepted = true
        return
      }
      var chord = root.chordForEvent(event)
      if (!chord) {
        root.errorText = "That key cannot be represented safely in Hyprland"
        event.accepted = true
        return
      }
      root.stopRecording()
      root.captured(chord)
      event.accepted = true
    }
  }
}
