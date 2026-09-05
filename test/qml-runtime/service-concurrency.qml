import Quickshell
import Quickshell.Io
import QtQuick

// Exercises the manual worker pool with deliberately blocked fake-runner
// processes. A phase can advance only when the required jobs overlap or stay
// excluded, so this catches accidental re-serialization and barrier leaks.
ShellRoot {
  id: root

  property var service: null
  property int phase: 0
  property real phaseAt: 0
  property real barrierStartedAt: 0
  property bool finished: false

  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property string callsPath: testDir + "/manual-calls.log"

  function enter(next) {
    phase = next
    phaseAt = Date.now()
  }

  function finish(passed, detail) {
    if (finished) return
    finished = true
    poll.stop()
    deadline.stop()
    if (passed) console.log("OMACHORD_QML_TEST_PASS")
    else console.error("OMACHORD_QML_TEST_FAIL", detail || "manual concurrency test failed")
  }

  function readCalls() {
    callsView.reload()
    return String(callsView.text() || "")
  }

  function has(text, line) {
    return ("\n" + text).indexOf("\n" + line + "\n") !== -1
  }

  function lineCount(text, line) {
    var rows = String(text || "").split("\n")
    var count = 0
    for (var i = 0; i < rows.length; i++)
      if (rows[i] === line) count++
    return count
  }

  function ordered(text, lines) {
    var offset = -1
    for (var i = 0; i < lines.length; i++) {
      var next = text.indexOf(lines[i] + "\n", offset + 1)
      if (next < 0 || next <= offset) return false
      offset = next
    }
    return true
  }

  function release(operation, routineId) {
    if (releaseProc.running) {
      finish(false, "release helper was already running")
      return
    }
    var suffix = routineId ? "-" + routineId : "-connection"
    releaseProc.command = ["touch", testDir + "/release-" + operation + suffix]
    releaseProc.running = true
  }

  function releasePair(operation, firstId, secondId) {
    if (releaseProc.running) {
      finish(false, "release helper was already running")
      return
    }
    releaseProc.command = ["touch",
      testDir + "/release-" + operation + "-" + firstId,
      testDir + "/release-" + operation + "-" + secondId]
    releaseProc.running = true
  }

  function blockProbeAndRelease(operation, routineId) {
    if (releaseProc.running) {
      finish(false, "release helper was already running")
      return
    }
    releaseProc.command = ["touch", testDir + "/block-active",
      testDir + "/release-" + operation + "-" + routineId]
    releaseProc.running = true
  }

  function releaseSaturation() {
    if (releaseProc.running) {
      finish(false, "release helper was already running")
      return
    }
    releaseProc.command = ["touch",
      testDir + "/release-activate-sat-b",
      testDir + "/release-activate-sat-c",
      testDir + "/release-activate-sat-d",
      testDir + "/release-activate-sat-e",
      testDir + "/release-active-probe"]
    releaseProc.running = true
  }

  function startBarrier(operation, beforeId, afterId, nextPhase) {
    if (!service.startRoutine(beforeId)) {
      finish(false, "could not enqueue routine before " + operation)
      return
    }
    var queued = operation === "connect" ? service.requestConnect() : service.requestDisconnect()
    if (!queued || !service.startRoutine(afterId)) {
      finish(false, "could not enqueue " + operation + " barrier")
      return
    }
    barrierStartedAt = 0
    enter(nextPhase)
  }

  FileView {
    id: callsView
    path: root.callsPath
    printErrors: false
    blockLoading: true
  }

  Process {
    id: releaseProc
  }

  Timer {
    id: poll
    interval: 25
    repeat: true
    onTriggered: {
      var text = root.readCalls()
      var elapsed = Date.now() - root.phaseAt

      // Distinct routine IDs must occupy separate workers. Both starts are
      // required before either blocked process is released.
      if (root.phase === 1) {
        if (root.has(text, "END activate alpha") || root.has(text, "END activate beta")) {
          root.finish(false, "distinct-ID fixture ended before release:\n" + text)
          return
        }
        if (root.has(text, "START activate alpha") && root.has(text, "START activate beta")) {
          root.releasePair("activate", "alpha", "beta")
          root.enter(2)
        }
        return
      }
      if (root.phase === 2) {
        if (!root.has(text, "END activate alpha") || !root.has(text, "END activate beta")) return
        if (!root.service.startRoutine("same") || !root.service.endRoutine("same")) {
          root.finish(false, "could not enqueue same-ID operations")
          return
        }
        root.enter(3)
        return
      }

      // Different operations for one ID must stay ordered even when a worker
      // is otherwise available.
      if (root.phase === 3) {
        if (root.has(text, "START deactivate same")) {
          root.finish(false, "same-ID operations overlapped:\n" + text)
          return
        }
        if (elapsed >= 250 && root.has(text, "START activate same")) {
          root.release("activate", "same")
          root.enter(4)
        }
        return
      }
      if (root.phase === 4) {
        if (!root.has(text, "END activate same") || !root.has(text, "START deactivate same")) return
        root.release("deactivate", "same")
        root.enter(5)
        return
      }
      if (root.phase === 5) {
        if (!root.has(text, "END deactivate same")) return
        root.startBarrier("connect", "before-connect", "after-connect", 6)
        return
      }

      // Work submitted before a connection operation must drain first. Work
      // submitted after it must not start until the connection process exits.
      if (root.phase === 6) {
        if (root.has(text, "START connect") || root.has(text, "START activate after-connect")) {
          root.finish(false, "connect crossed its leading barrier:\n" + text)
          return
        }
        if (elapsed >= 250 && root.has(text, "START activate before-connect")) {
          root.release("activate", "before-connect")
          root.enter(7)
        }
        return
      }
      if (root.phase === 7) {
        if (root.has(text, "START activate after-connect")) {
          root.finish(false, "routine crossed a running connect barrier:\n" + text)
          return
        }
        if (!root.has(text, "START connect")) return
        if (root.barrierStartedAt === 0) root.barrierStartedAt = Date.now()
        if (Date.now() - root.barrierStartedAt >= 250) {
          root.release("connect", "")
          root.enter(8)
        }
        return
      }
      if (root.phase === 8) {
        if (!root.has(text, "END connect") || !root.has(text, "START activate after-connect")) return
        root.release("activate", "after-connect")
        root.enter(9)
        return
      }
      if (root.phase === 9) {
        if (!root.has(text, "END activate after-connect")) return
        root.startBarrier("disconnect", "before-disconnect", "after-disconnect", 10)
        return
      }

      // Disconnect has the same global-barrier contract as connect.
      if (root.phase === 10) {
        if (root.has(text, "START disconnect") || root.has(text, "START activate after-disconnect")) {
          root.finish(false, "disconnect crossed its leading barrier:\n" + text)
          return
        }
        if (elapsed >= 250 && root.has(text, "START activate before-disconnect")) {
          root.release("activate", "before-disconnect")
          root.enter(11)
        }
        return
      }
      if (root.phase === 11) {
        if (root.has(text, "START activate after-disconnect")) {
          root.finish(false, "routine crossed a running disconnect barrier:\n" + text)
          return
        }
        if (!root.has(text, "START disconnect")) return
        if (root.barrierStartedAt === 0) root.barrierStartedAt = Date.now()
        if (Date.now() - root.barrierStartedAt >= 250) {
          root.release("disconnect", "")
          root.enter(12)
        }
        return
      }
      if (root.phase === 12) {
        if (!root.has(text, "END disconnect") || !root.has(text, "START activate after-disconnect")) return
        root.release("activate", "after-disconnect")
        root.enter(13)
        return
      }
      if (root.phase === 13) {
        if (!root.has(text, "END activate after-disconnect")) return
        var validOrder = root.ordered(text, [
          "START activate same", "END activate same", "START deactivate same", "END deactivate same"
        ]) && root.ordered(text, [
          "START activate before-connect", "END activate before-connect",
          "START connect", "END connect", "START activate after-connect", "END activate after-connect"
        ]) && root.ordered(text, [
          "START activate before-disconnect", "END activate before-disconnect",
          "START disconnect", "END disconnect",
          "START activate after-disconnect", "END activate after-disconnect"
        ])
        if (!validOrder) {
          root.finish(false, "barrier operation order was invalid:\n" + text)
          return
        }
        if (!root.service.startRoutine("alternating")
            || !root.service.endRoutine("alternating")
            || !root.service.startRoutine("alternating")) {
          root.finish(false, "could not enqueue alternating same-ID operations")
          return
        }
        root.enter(14)
        return
      }

      // Equal operations separated by an opposite operation are distinct
      // intents and must all execute in order for one routine id.
      if (root.phase === 14) {
        if (root.has(text, "START deactivate alternating")
            || root.lineCount(text, "START activate alternating") > 1) {
          root.finish(false, "alternating same-ID operations overlapped:\n" + text)
          return
        }
        if (elapsed >= 250 && root.lineCount(text, "START activate alternating") === 1) {
          root.release("activate", "alternating")
          root.enter(15)
        }
        return
      }
      if (root.phase === 15) {
        if (root.lineCount(text, "END activate alternating") < 1
            || !root.has(text, "START deactivate alternating")) return
        root.release("deactivate", "alternating")
        root.enter(16)
        return
      }
      if (root.phase === 16) {
        if (!root.has(text, "END deactivate alternating")
            || root.lineCount(text, "START activate alternating") < 2) return
        root.release("activate", "alternating")
        root.enter(17)
        return
      }
      if (root.phase === 17) {
        if (root.lineCount(text, "END activate alternating") < 2) return
        if (!root.service.toggleRoutine("toggle") || !root.service.toggleRoutine("toggle")) {
          root.finish(false, "could not enqueue repeated toggles")
          return
        }
        root.enter(18)
        return
      }

      // A repeated run request is two toggles, never an idempotent duplicate.
      if (root.phase === 18) {
        if (root.lineCount(text, "START run toggle") > 1) {
          root.finish(false, "repeated toggles overlapped:\n" + text)
          return
        }
        if (elapsed >= 250 && root.lineCount(text, "START run toggle") === 1) {
          root.release("run", "toggle")
          root.enter(19)
        }
        return
      }
      if (root.phase === 19) {
        if (root.lineCount(text, "END run toggle") < 1
            || root.lineCount(text, "START run toggle") < 2) return
        root.release("run", "toggle")
        root.enter(20)
        return
      }
      if (root.phase === 20) {
        if (root.lineCount(text, "END run toggle") < 2) return
        var preservedOrder = root.ordered(text, [
          "START activate alternating", "END activate alternating",
          "START deactivate alternating", "END deactivate alternating",
          "START activate alternating", "END activate alternating"
        ]) && root.ordered(text, [
          "START run toggle", "END run toggle",
          "START run toggle", "END run toggle"
        ])
        if (!preservedOrder) {
          root.finish(false, "same-ID request order was not preserved:\n" + text)
          return
        }
        if (!root.service.startRoutine("sat-a") || !root.service.startRoutine("sat-b")
            || !root.service.startRoutine("sat-c") || !root.service.startRoutine("sat-d")
            || !root.service.startRoutine("sat-e")) {
          root.finish(false, "could not saturate the manual worker pool")
          return
        }
        root.enter(21)
        return
      }

      // Freeing one of four occupied workers must launch the unrelated fifth
      // job even while the completion-triggered active probe is blocked.
      if (root.phase === 21) {
        if (root.has(text, "START activate sat-e")) {
          root.finish(false, "fifth job started before a worker was free:\n" + text)
          return
        }
        if (root.has(text, "START activate sat-a")
            && root.has(text, "START activate sat-b")
            && root.has(text, "START activate sat-c")
            && root.has(text, "START activate sat-d")) {
          root.blockProbeAndRelease("activate", "sat-a")
          root.enter(22)
        }
        return
      }
      if (root.phase === 22) {
        if (!root.has(text, "END activate sat-a")
            || !root.has(text, "ACTIVE BLOCKED")
            || !root.has(text, "START activate sat-e")) return
        root.releaseSaturation()
        root.enter(23)
        return
      }
      if (root.phase === 23) {
        if (!root.has(text, "END activate sat-b")
            || !root.has(text, "END activate sat-c")
            || !root.has(text, "END activate sat-d")
            || !root.has(text, "END activate sat-e")) return
        if (!root.service.startRoutine("constructor")) {
          root.finish(false, "valid prototype-named routine id was rejected")
          return
        }
        root.enter(24)
        return
      }
      if (root.phase === 24) {
        if (!root.has(text, "START activate constructor")) return
        root.release("activate", "constructor")
        root.enter(25)
        return
      }
      if (root.phase === 25) {
        if (!root.has(text, "END activate constructor")) return
        root.finish(true, "")
      }
    }
  }

  Timer {
    id: deadline
    interval: 20000
    repeat: false
    onTriggered: root.finish(false, "timed out in phase " + root.phase + "; calls were:\n" + root.readCalls())
  }

  Component.onCompleted: {
    var component = Qt.createComponent("Service.qml")
    if (component.status !== Component.Ready) {
      finish(false, component.errorString())
      return
    }
    service = component.createObject(this, {})
    if (!service) {
      finish(false, "Service.qml createObject returned null")
      return
    }
    if (!service.startRoutine("alpha") || !service.startRoutine("beta")) {
      finish(false, "could not enqueue distinct-ID operations")
      return
    }
    enter(1)
    poll.start()
    deadline.start()
  }
}
