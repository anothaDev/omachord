import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property var panel: null
  property var win: null
  property string outDir: Quickshell.env("RENDER_OUT")
  property var views: (Quickshell.env("RENDER_VIEWS") || "routines,shortcuts,automations").split(",")
  property int viewIndex: 0
  property int width: Number(Quickshell.env("RENDER_W") || 1080)
  property int height: Number(Quickshell.env("RENDER_H") || 720)
  property bool longShortcutFixture: Quickshell.env("RENDER_LONG_SHORTCUTS") === "1"
  property bool shortcutFixtureInjected: false

  function shortcutFixture() {
    var rows = []
    for (var i = 1; i <= 40; i++) {
      rows.push({
        keys: "SUPER + " + String(i),
        description: "Example shortcut " + String(i),
        editable: true,
        managed: i % 7 === 0
      })
    }
    return rows
  }

  function findWindow(item) {
    for (var i = 0; i < item.data.length; i++) {
      var child = item.data[i]
      if (child && child.contentItem !== undefined && child.title !== undefined) return child
    }
    return null
  }

  function snapNext() {
    if (viewIndex >= views.length) { console.log("RENDER_DONE"); Qt.quit(); return }
    var view = views[viewIndex]
    panel.open(JSON.stringify({ view: view }))
    settle.restart()
  }

  Timer {
    id: settle
    interval: Number(Quickshell.env("RENDER_SETTLE") || 2500)
    onTriggered: {
      var view = root.views[root.viewIndex]
      if (view === "shortcuts" && root.longShortcutFixture && !root.shortcutFixtureInjected) {
        root.panel.bindings = root.shortcutFixture()
        root.shortcutFixtureInjected = true
        interval = 200
        restart()
        return
      }
      var path = root.outDir + "/" + view + ".png"
      console.log("RENDER_STEP grabbing " + view + " visible=" + root.win.visible + " size=" + root.win.width + "x" + root.win.height)
      var content = root.win.contentItem
      var target = null
      for (var c = 0; c < content.children.length; c++) { if (content.children[c] && content.children[c].width > 0) { target = content.children[c]; break } }
      if (!target) target = content.children[0]
      console.log("RENDER_STEP target " + target + " " + (target ? target.width + "x" + target.height : ""))
      target.grabToImage(function(result) {
        var ok = result.saveToFile(path)
        console.log("RENDER_SAVED " + view + " " + ok + " " + result.image.width + "x" + result.image.height)
        if (!ok) { console.error("RENDER_FAIL could not save " + path); Qt.quit(); return }
        root.viewIndex++
        root.snapNext()
      })
    }
  }

  Component.onCompleted: {
    var component = Qt.createComponent("Panel.qml")
    if (component.status !== Component.Ready) { console.error("RENDER_FAIL " + component.errorString()); Qt.quit(); return }
    console.log("RENDER_STEP component ready"); panel = component.createObject(root, {}); console.log("RENDER_STEP object " + (panel ? "ok" : "null"))
    win = findWindow(panel)
    if (!win) { console.error("RENDER_FAIL no window"); Qt.quit(); return }
    console.log("RENDER_STEP window " + win); win.implicitWidth = root.width
    win.implicitHeight = root.height
    snapNext()
  }
}
