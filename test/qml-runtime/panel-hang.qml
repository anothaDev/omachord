import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// A Panel without a resident service, against fake-hang-runner with short
// deadlines: a hung load, save, or connection change must unlock the panel
// with a clear error instead of leaving it loading or saving forever.
ShellRoot {
  id: root
  property var panel: null
  property int controlExit: -1
  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property string revision: "sha256:" + "e".repeat(64)

  TestCase { id: input; name: "PanelHang"; when: false }
  FileView { id: callsView; path: root.testDir + "/hang-calls.log"; blockLoading: true; printErrors: false }
  Process {
    id: controlProc
    onExited: function(exitCode) { root.controlExit = exitCode }
  }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  function waitFor(predicate, message) {
    var until = Date.now() + 5000
    while (!predicate() && Date.now() < until) input.wait(20)
    check(predicate(), message + "; calls were:\n" + calls())
  }

  function calls() { callsView.reload(); return String(callsView.text() || "") }

  function find(item, predicate) {
    if (!item) return null
    if (predicate(item)) return item
    for (var child of item.children || []) {
      var result = find(child, predicate)
      if (result) return result
    }
    return null
  }

  function editorError() {
    for (var child of panel.data) {
      if (!child || child.contentItem === undefined || child.title === undefined) continue
      var editor = find(child.contentItem, function(item) {
        return item.draft !== undefined && typeof item.save === "function" })
      if (editor) return String(editor.externalError || "")
    }
    return ""
  }

  function markers(action, names) {
    controlExit = -1
    controlProc.command = [action === "add" ? "touch" : "rm", action === "add" ? "--" : "-f"]
      .concat(names.map(function(name) { return root.testDir + "/" + name }))
    controlProc.running = true
    waitFor(function() { return root.controlExit !== -1 }, "marker helper did not finish")
    check(controlExit === 0, "marker helper failed")
  }

  Timer {
    id: scenario
    interval: 20
    onTriggered: {
      try {
        root.markers("add", ["hang-config-snapshot"])
        var component = Qt.createComponent("Panel.qml")
        root.check(component.status === Component.Ready, component.errorString())
        root.panel = component.createObject(root, {
          probeDeadlineMs: 400, connectionDeadlineMs: 400, routineDeadlineMs: 400, watchdogGraceMs: 300
        })
        root.check(!!root.panel, "could not create the panel")
        root.panel.refreshAll()
        root.check(root.panel.loading, "the panel must be loading")
        root.waitFor(function() { return !root.panel.loading }, "a hung configuration load must unlock the panel")
        root.check(!root.panel.configLoaded && root.panel.noticeError
          && root.panel.noticeText.indexOf("(config snapshot) did not finish") !== -1,
          "a stopped load must explain the timeout: " + root.panel.noticeText)

        root.markers("remove", ["hang-config-snapshot"])
        root.panel.refreshAll()
        root.waitFor(function() { return root.panel.configLoaded && root.panel.configRevision === root.revision },
          "the panel did not load after the hung snapshot was stopped")

        root.markers("add", ["hang-config-apply", "ignore-term-config-apply"])
        var routine = root.panel.routineById("alpha")
        root.check(!!routine, "fixture routine is missing")
        root.panel.saveRoutine(routine)
        root.check(root.panel.mutating, "the save must lock the panel")
        root.waitFor(function() { return !root.panel.mutating }, "a hung save that ignores SIGTERM must unlock the panel")
        root.check(root.panel.configRevision === root.revision
          && root.editorError().indexOf("(config apply) did not finish") !== -1,
          "a stopped save must keep the revision and explain the timeout: " + root.editorError())

        root.markers("remove", ["hang-config-apply", "ignore-term-config-apply"])
        root.markers("add", ["hang-connect"])
        root.panel.mutateConnection("connect")
        root.check(root.panel.integrationBusy, "connect must lock the switch")
        root.waitFor(function() { return !root.panel.integrationBusy && !root.panel.mutating },
          "a hung connect must unlock the switch")
        root.check(root.panel.noticeError && root.panel.noticeText.indexOf("(connect) did not finish") !== -1,
          "a stopped connect must explain the timeout: " + root.panel.noticeText)
        root.check(root.calls().indexOf("UNEXPECTED") === -1, "the panel sent an argv the runner rejects")
        console.log("OMACHORD_QML_TEST_PASS", "panel watchdogs")
      } catch (error) {
        console.error("OMACHORD_QML_TEST_FAIL", String(error))
      }
      Qt.quit()
    }
  }

  Component.onCompleted: scenario.start()
}
