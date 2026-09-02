import Quickshell
import Quickshell.Io
import QtQuick

// Drives Service.qml against a fake runner (test/qml-runtime/fake-runner) that
// records every call. The toggles directory is the only condition input the
// harness controls, so the routine under test uses an omarchy-toggle condition.
ShellRoot {
  id: root

  property var service: null
  property int phase: 0
  property string calls: ""

  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property string flagPath: testDir + "/state/omarchy/toggles/scratch"
  readonly property string callsPath: testDir + "/runner-calls.log"
  readonly property string holdDeactivatePath: testDir + "/hold-deactivate"

  function finish(passed, detail) {
    if (passed) console.log("OMACHORD_QML_TEST_PASS")
    else console.error("OMACHORD_QML_TEST_FAIL", detail || "service runtime test failed")
  }

  function readCalls() {
    callsView.reload()
    return String(callsView.text() || "")
  }

  FileView {
    id: callsView
    path: root.callsPath
    printErrors: false
    blockLoading: true
  }

  Process {
    id: touchFlag
    command: ["touch", root.flagPath]
  }

  Process {
    id: removeFlag
    command: ["rm", "-f", root.flagPath]
  }

  Process {
    id: restoreFlag
    command: ["touch", root.flagPath]
    onExited: function() {
      root.service.applyToggles(["scratch"])
      root.service.evaluate()
      releaseDeactivate.running = true
    }
  }

  Process {
    id: releaseDeactivate
    command: ["rm", "-f", root.holdDeactivatePath]
  }

  Timer {
    id: poll
    interval: 100
    repeat: true
    onTriggered: {
      var text = root.readCalls()
      if (root.phase === 1 && text.indexOf("activate scratch-routine condition sha256:test\n") !== -1) {
        var status = JSON.parse(root.service.statusJson())
        if (!status.enabled || !status.ready) {
          poll.stop()
          root.finish(false, "service reported not ready after activation: " + root.service.statusJson())
          return
        }
        root.phase = 2
        settle.start()
        return
      }
      if (root.phase === 3 && text.indexOf("deactivate scratch-routine condition sha256:test\n") !== -1) {
        root.phase = 4
        restoreFlag.running = true
        return
      }
      if (root.phase === 4 && text.indexOf("EARLY activation before logs") !== -1) {
        poll.stop()
        root.finish(false, "service activated before startup latches were seeded:\n" + text)
        return
      }
      if (root.phase === 4) {
        var activations = 0
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++)
          if (lines[i].indexOf("activate ") === 0) activations++
        if (activations === 2) {
          poll.stop()
          root.finish(true, "")
        }
      }
    }
  }

  // After activation the routine stays active while the flag holds, so a few
  // more evaluation rounds must not activate it again.
  Timer {
    id: settle
    interval: 1500
    repeat: false
    onTriggered: {
      root.service.evaluate()
      Qt.callLater(function() {
        root.phase = 3
        removeFlag.running = true
      })
    }
  }

  Timer {
    id: deadline
    interval: 20000
    repeat: false
    onTriggered: {
      poll.stop()
      root.finish(false, "timed out in phase " + root.phase + "; calls were:\n" + root.readCalls()
        + "\nstatus: " + (root.service ? root.service.statusJson() : "no service"))
    }
  }

  Component.onCompleted: {
    var component = Qt.createComponent("Service.qml")
    if (component.status !== Component.Ready) {
      finish(false, component.errorString())
      return
    }
    service = component.createObject(this, {})
    if (!service) {
      finish(false, "service createObject returned null")
      return
    }
    service.applyToggles(["constructor"])
    if (Object.getPrototypeOf(service.toggles) !== null || service.toggles.constructor !== true) {
      finish(false, "toggle map is not prototype-safe")
      return
    }
    service.applyToggles(null)
    if (Object.keys(service.toggles).length !== 0) {
      finish(false, "a failed toggle probe retained stale state")
      return
    }
    service.applyToggles([])
    var manifestDirOk = service.runnerPath === Quickshell.env("OMACHORD_RUNNER_PATH")
    if (!manifestDirOk) {
      finish(false, "runner path was not taken from the environment: " + service.runnerPath)
      return
    }
    phase = 1
    deadline.start()
    poll.start()
    // Give the service its first reconcile before the condition flips.
    Qt.callLater(function() { touchFlag.running = true })
  }
}
