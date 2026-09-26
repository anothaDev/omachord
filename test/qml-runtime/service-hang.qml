import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// Service processes against fake-hang-runner with short deadlines. Every
// runner that hangs must be stopped and routed through the ordinary failure
// path, so the connection barrier and the manual queue always recover.
ShellRoot {
  id: root
  property var service: null
  property var finished: []
  property int controlExit: -1
  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property string revision: "sha256:" + "e".repeat(64)

  TestCase { id: input; name: "ServiceHang"; when: false }
  FileView { id: callsView; path: root.testDir + "/hang-calls.log"; blockLoading: true; printErrors: false }
  Process {
    id: controlProc
    onExited: function(exitCode) { root.controlExit = exitCode }
  }
  Connections {
    target: root.service
    function onManualFinished(job, result) {
      root.finished = root.finished.concat([{ op: job.op, id: job.id, result: result }])
    }
  }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  function waitFor(predicate, message, timeout) {
    var until = Date.now() + (timeout || 5000)
    while (!predicate() && Date.now() < until) input.wait(20)
    check(predicate(), message + "; calls were:\n" + calls())
  }

  function calls() { callsView.reload(); return String(callsView.text() || "") }

  // Creates or removes marker files in the private test directory.
  function markers(action, names) {
    controlExit = -1
    controlProc.command = [action === "add" ? "touch" : "rm", action === "add" ? "--" : "-f"]
      .concat(names.map(function(name) { return root.testDir + "/" + name }))
    controlProc.running = true
    waitFor(function() { return root.controlExit !== -1 }, "marker helper did not finish")
    check(controlExit === 0, "marker helper failed")
  }

  function lastFinished(op) {
    for (var i = finished.length - 1; i >= 0; i--) if (finished[i].op === op) return finished[i]
    return null
  }

  Timer {
    id: scenario
    interval: 20
    onTriggered: {
      try {
        var component = Qt.createComponent("Service.qml")
        root.check(component.status === Component.Ready, component.errorString())
        // Autostart hangs and ignores SIGTERM, so it needs the kill escalation.
        root.markers("add", ["hang-autostart", "ignore-term-autostart"])
        root.service = component.createObject(root, {
          probeDeadlineMs: 400, connectionDeadlineMs: 400, routineDeadlineMs: 400, watchdogGraceMs: 300
        })
        root.check(!!root.service, "could not create the service")
        root.waitFor(function() { return root.calls().indexOf("START status") !== -1 },
          "a hung autostart that ignores SIGTERM must still be killed and reconciled")
        root.waitFor(function() { return root.service.enabled && root.service.configLoaded
          && root.service.configRevision === root.revision }, "the service did not recover after autostart")

        // A hung connection keeps the barrier until its follow-up status
        // probe settles; here that probe hangs too.
        root.markers("add", ["hang-connect", "hang-status"])
        root.check(root.service.requestConnect(root.revision), "connect was not queued")
        root.check(root.service.connectionBusy, "connect must hold the connection barrier")
        root.waitFor(function() { return !!root.lastFinished("connect") && !root.service.connectionBusy },
          "a hung connect and status probe must release the connection barrier")
        var connect = root.lastFinished("connect").result
        root.check(connect.ok === false && connect.code === "timeout" && connect.error.indexOf("(connect)") !== -1,
          "a stopped connect must report its timeout: " + JSON.stringify(connect))
        root.check(!root.service.enabled, "an unavailable status must keep conditions fail-closed")

        // A hung manual routine worker must free its routine for later work.
        root.markers("remove", ["hang-connect", "hang-status"])
        root.markers("add", ["hang-activate"])
        root.check(root.service.startRoutine("alpha", root.revision), "activation was not queued")
        root.check(root.service.routineBusy("alpha"), "the routine must be busy while its worker runs")
        root.waitFor(function() { return !!root.lastFinished("activate") && !root.service.routineBusy("alpha")
          && !root.service.manualBusy }, "a hung routine worker must be stopped and settle")
        var activate = root.lastFinished("activate").result
        root.check(activate.ok === false && activate.code === "timeout",
          "a stopped routine must report its timeout: " + JSON.stringify(activate))

        // Nothing stays wedged: the next requests run normally.
        root.markers("remove", ["hang-activate"])
        root.check(root.service.requestConnect(root.revision), "a later connect was not queued")
        root.waitFor(function() { var last = root.lastFinished("connect")
          return last && last.result.ok === true && !root.service.connectionBusy && root.service.enabled },
          "the connection path did not recover after the timeouts")
        root.check(root.calls().indexOf("UNEXPECTED") === -1, "the service sent an argv the runner rejects")
        console.log("OMACHORD_QML_TEST_PASS", "service watchdogs")
      } catch (error) {
        console.error("OMACHORD_QML_TEST_FAIL", String(error))
      }
      Qt.quit()
    }
  }

  Component.onCompleted: scenario.start()
}
