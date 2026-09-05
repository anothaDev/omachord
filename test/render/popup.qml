import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var sampleRows: [
    { id: "focus-at-work", name: "Focus at work", activatedAt: "2026-09-01T09:00:12+02:00", trigger: "condition", keepUntil: "conditions", expiresAt: "", onEndMode: "restore", setterCount: 2, conditions: 1, stateful: true },
    { id: "in-the-dark", name: "In the dark", activatedAt: "2026-09-01T07:41:03+02:00", trigger: "shortcut", keepUntil: { minutes: 90 }, expiresAt: "2026-09-01T10:11:03+02:00", onEndMode: "actions", setterCount: 1, conditions: 0, stateful: true }
  ]
  FloatingWindow {
    id: win
    implicitWidth: 420
    implicitHeight: 330
    color: "#101315"
    visible: true
    Item {
      id: content
      anchors.fill: parent
      Rectangle { anchors.fill: parent; color: "#101315" }
      Rectangle {
        anchors.fill: parent; anchors.margins: 6; color: "transparent"; border.color: "#cacccc"; border.width: 2
        RoutinePopup {
          id: popup
          anchors.fill: parent
          anchors.margins: 16
          success: "#68c98b"; integrationOn: true
          rows: Quickshell.env("WIDGET_EMPTY") === "1" ? [] : root.sampleRows
          cursorIndex: 0
        }
      }
    }
    Timer {
      interval: 1500
      running: true
      onTriggered: content.grabToImage(function(result) {
        var path = Quickshell.env("WIDGET_OUT")
        if (!result.saveToFile(path)) console.error("RENDER_FAIL could not save " + path)
        else console.log("WIDGET_DONE")
        Qt.quit()
      })
    }
  }
}
