import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
  id: root

  property var service: null
  property int phase: 0
  property bool finished: false
  property int completions: 0
  property bool watchCompletion: false
  property bool expectedConnected: true
  property bool expectedStatusUnavailable: false
  readonly property bool expectedEngineEnabled: expectedConnected && !expectedStatusUnavailable
  property string expectedOperation: "connect"
  property bool expectedOk: true
  property string expectedProbe: ""
  property bool watchState: false
  property int completedAtStart: 0
  property int recoveryCase: 0
  property real phaseAt: 0
  property int snapshotsBefore: 0
  // Later slices exercise unavailable probes and commands against both stable
  // connection states. These cases all reuse the public signal/busy checks.
  readonly property var recoveryCases: [
    { tag: "reenabled", operation: "connect", outcome: "success", connected: true, probe: "block", ok: true, reconcile: false },
    { tag: "bad-probe", operation: "disconnect", outcome: "fail", connected: true, probe: "block-fail", ok: false, reconcile: true },
    { tag: "incomplete", operation: "disconnect", outcome: "incomplete", connected: false, probe: "block", ok: true, reconcile: true },
    { tag: "before-failed-start", operation: "connect", outcome: "success", connected: true, probe: "block", ok: true, reconcile: false }
  ]
  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property string revision: "sha256:" + "a".repeat(64)

  function finish(passed, detail) {
    if (finished) return
    finished = true
    poll.stop()
    deadline.stop()
    if (passed) console.log("OMACHORD_QML_TEST_PASS")
    else console.error("OMACHORD_QML_TEST_FAIL", detail || "connection test failed")
  }

  function check(condition, detail) {
    if (!condition) finish(false, detail)
    return condition
  }

  function readCalls() {
    callsView.reload()
    return String(callsView.text() || "")
  }

  function has(text, line) {
    return ("\n" + text).indexOf("\n" + line + "\n") !== -1
  }

  function snapshotCount(text) {
    return text.split("CONFIG SNAPSHOT\n").length - 1
  }

  function requestReconcile(text) {
    snapshotsBefore = snapshotCount(text)
    service.reconcile("connection fixture: deferred status")
  }

  // Only mutate this fixture's temporary files, never the real runner/config.
  function control(script, next) {
    if (!check(!controlProc.running, "fixture control overlapped")) return
    phase = -1
    controlProc.nextPhase = next
    controlProc.command = ["bash", "-c", script, "fixture", testDir]
    controlProc.running = true
  }

  function checkSettled() {
    if (!check(service.enabled === expectedEngineEnabled,
        "condition engine readiness did not settle (status unavailable: " + expectedStatusUnavailable + ")")) return
    check(service.disabledReason === (expectedStatusUnavailable ? "runner status unavailable"
      : (expectedConnected ? "" : "not connected")), "condition engine reported the wrong disabled reason")
    var status = service.connectionStatus
    check(status && status.ok === true && status.connected === expectedConnected
      && status.integrationComplete === expectedConnected
      && status.ownedConnection === expectedConnected
      && status.connectionEnabled === expectedConnected,
      "connection busy cleared before shared status flags were authoritative")
    if (expectedConnected) check(status.configValid === true && status.configError === "",
      "successful connect retained stale configuration errors")
  }

  Connections {
    target: root.service
    function onEnabledChanged() {
      if (root.watchState) root.check(root.service.enabled === root.expectedEngineEnabled,
        "stale status changed enabled during/after a connection transition")
    }
    function onConnectionStatusChanged() {
      var status = root.service.connectionStatus
      if (status) root.check(status.probe !== "before" && status.probe !== "before-late",
        "accepted a status snapshot started before/during a connection transition")
    }
    function onConnectionBusyChanged() {
      if (root.watchCompletion && !root.service.connectionBusy) root.checkSettled()
    }
    function onManualFinished(job, result) {
      if (job.id !== "") return
      root.completions++
      root.checkSettled()
      root.check(result.ok === root.expectedOk && job.op === root.expectedOperation && job.source === "manual",
        "manualFinished changed its job/result contract")
      root.check(!root.expectedProbe || root.service.connectionStatus.probe === root.expectedProbe,
        "manualFinished was emitted before failure reconciliation updated state")
    }
  }

  FileView {
    id: callsView
    path: root.testDir + "/connection-calls.log"
    printErrors: false
    blockLoading: true
  }

  Process {
    id: controlProc
    property int nextPhase: 0
    onExited: function(exitCode) {
      if (root.check(exitCode === 0, "fixture control failed")) root.phase = nextPhase
    }
  }

  Timer {
    id: poll
    interval: 25
    repeat: true
    onTriggered: {
      var text = root.readCalls()
      if (!root.check(text.indexOf("FORBIDDEN STATUS") === -1,
          "watcher/reconcile launched status during a queued/running connection:\n" + text)) return
      if (root.phase === 0) {
        if (!root.service.configLoaded || !root.service.connectionStatus
            || root.service.connectionStatus.probe !== "initial") return
        root.control('printf "fresh true block\\n" >"$1/status-plan"; touch "$1/forbid-status"', 1)
      } else if (root.phase === 1) {
        root.watchCompletion = true
        if (!root.check(root.service.requestConnect(), "connect was rejected")) return
        root.phase = 2
      } else if (root.phase === 2) {
        if (!root.has(text, "CONNECTION START connect connect argc=1 revision=")) return
        root.requestReconcile(text)
        root.control("printf '{\"watcher\":1}\\n' >\"$1/state/omarchy/omachord/connection.json\"", 29)
      } else if (root.phase === 29) {
        // The connection stays blocked until the other reconcile work has
        // actually run; no status process may have crossed that barrier.
        if (root.snapshotCount(text) <= root.snapshotsBefore) return
        if (!root.check(!root.has(text, "STATUS START fresh"), "running status request was not deferred")) return
        root.control('touch "$1/release-connection-connect"', 3)
      } else if (root.phase === 3) {
        if (!root.has(text, "STATUS START fresh") || root.completions !== 1) return
        if (!root.check(!root.service.connectionBusy, "successful connection waited for a blocked status probe")) return
        root.control('touch "$1/release-status-fresh"', 4)
      } else if (root.phase === 4) {
        if (!root.service.connectionStatus || root.service.connectionStatus.probe !== "fresh") return
        root.watchState = true
        root.control('printf "before false block\\n" >"$1/status-plan"; '
          + 'printf "disconnect success false\\n" >"$1/connection-plan"; '
          + "printf '{\"watcher\":2}\\n' >\"$1/state/omarchy/omachord/connection.json\"", 5)
      } else if (root.phase === 5) {
        // This probe must be started by the actual connection-file watcher.
        root.phase = 6
      } else if (root.phase === 6) {
        if (!root.has(text, "STATUS START before")) return
        root.expectedOperation = "disconnect"
        if (!root.check(root.service.requestDisconnect(), "disconnect was rejected")) return
        root.phase = 7
      } else if (root.phase === 7) {
        if (!root.has(text, "CONNECTION START disconnect disconnect argc=1 revision=")) return
        root.control('printf "during true block\\n" >"$1/status-plan"; '
          + 'touch "$1/forbid-status" "$1/release-status-before"', 8)
      } else if (root.phase === 8) {
        root.requestReconcile(text)
        root.phase = 9
      } else if (root.phase === 9) {
        if (!root.has(text, "STATUS END before") || root.snapshotCount(text) <= root.snapshotsBefore) return
        if (!root.check(!root.has(text, "STATUS START during"), "discarded old probe launched a queued status during transition")) return
        root.expectedConnected = false
        root.control('printf "disconnected false block\\n" >"$1/status-plan"; '
          + 'touch "$1/release-connection-disconnect"', 10)
      } else if (root.phase === 10) {
        if (root.completions !== 2) return
        root.phase = 11
      } else if (root.phase === 11) {
        if (!root.has(text, "STATUS START disconnected")) return
        root.control('touch "$1/release-status-disconnected"', 12)
      } else if (root.phase === 12) {
        if (root.service.connectionStatus.probe !== "disconnected") return
        root.control('printf "revision success true\\n" >"$1/connection-plan"; '
          + 'printf "verified true block\\n" >"$1/status-plan"; touch "$1/forbid-status"', 13)
      } else if (root.phase === 13) {
        root.expectedOperation = "connect"
        if (!root.check(root.service.startRoutine("before-revision"), "leading routine rejected")) return
        if (!root.check(root.service.requestConnect(root.revision), "revision-aware connect rejected")) return
        if (!root.check(root.service.connectionBusy && !root.service.requestConnect()
            && !root.service.requestDisconnect(), "queued connection accepted duplicate requests")) return
        if (!root.check(root.service.startRoutine("after-revision"), "connection barrier rejected routine request")) return
        root.requestReconcile(text)
        root.control("printf '{\"watcher\":3}\\n' >\"$1/state/omarchy/omachord/connection.json\"", 14)
      } else if (root.phase === 14) {
        if (!root.has(text, "ROUTINE START activate before-revision")
            || root.snapshotCount(text) <= root.snapshotsBefore) return
        if (!root.check(!root.has(text, "STATUS START verified"), "queued status request was not deferred")) return
        if (!root.check(text.indexOf("CONNECTION START revision") === -1
            && !root.has(text, "ROUTINE START activate after-revision"), "queued global barrier was crossed")) return
        root.control('touch "$1/release-routine-before-revision"', 15)
      } else if (root.phase === 15) {
        if (text.indexOf("CONNECTION START revision") === -1) return
        if (!root.check(root.has(text, "CONNECTION START revision connect argc=2 revision=" + root.revision),
            "expected revision was not forwarded as the third runner argument")) return
        if (!root.check(!root.service.requestConnect() && !root.service.requestDisconnect(),
            "running connection accepted duplicate requests")) return
        if (!root.check(!root.has(text, "ROUTINE START activate after-revision"), "running global barrier was crossed")) return
        root.expectedConnected = true
        root.control('touch "$1/release-connection-revision" "$1/release-routine-after-revision"', 16)
      } else if (root.phase === 16) {
        if (root.completions !== 3 || !root.has(text, "ROUTINE END activate after-revision")) return
        root.control('touch "$1/release-status-verified"', 17)
      } else if (root.phase === 17) {
        if (root.service.connectionStatus.probe !== "verified") return
        root.control('printf "failure fail false\\n" >"$1/connection-plan"; '
          + 'printf "recovered false block\\n" >"$1/status-plan"', 18)
      } else if (root.phase === 18) {
        root.expectedOperation = "disconnect"
        root.expectedOk = false
        root.expectedProbe = "recovered"
        if (!root.check(root.service.requestDisconnect(), "failing disconnect was rejected")) return
        if (!root.check(root.service.startRoutine("after-failure"), "routine behind failing connection rejected")) return
        root.control('touch "$1/release-connection-failure"', 19)
      } else if (root.phase === 19) {
        if (!root.has(text, "STATUS START recovered")) return
        if (!root.check(root.service.connectionBusy && root.completions === 3 && root.service.enabled,
            "failed connection did not stay stable/busy until reconciliation")) return
        if (!root.check(!root.service.requestConnect() && !root.service.requestDisconnect(),
            "failure reconciliation accepted duplicate connection requests")) return
        if (!root.check(!root.has(text, "ROUTINE START activate after-failure"),
            "routine crossed failure reconciliation barrier")) return
        root.expectedConnected = false
        root.control('touch "$1/release-status-recovered" "$1/release-routine-after-failure"', 20)
      } else if (root.phase === 20) {
        if (root.completions !== 4 || !root.has(text, "ROUTINE END activate after-failure")) return
        root.phase = 21
      } else if (root.phase === 21) {
        var next = root.recoveryCases[root.recoveryCase]
        root.completedAtStart = root.completions
        root.control('printf "' + next.tag + ' ' + next.outcome + ' ' + next.connected + '\\n" >"$1/connection-plan"; '
          + 'printf "' + next.tag + ' ' + next.connected + ' ' + next.probe + '\\n" >"$1/status-plan"', 22)
      } else if (root.phase === 22) {
        var next = root.recoveryCases[root.recoveryCase]
        root.expectedOperation = next.operation
        root.expectedOk = next.ok
        root.expectedProbe = next.reconcile && next.probe !== "block-fail" ? next.tag : ""
        if (!next.reconcile) {
          root.expectedConnected = next.connected
          root.expectedStatusUnavailable = false
        }
        if (!root.check(next.operation === "connect" ? root.service.requestConnect() : root.service.requestDisconnect(),
            "recovery connection was rejected: " + next.tag)) return
        root.control('touch "$1/release-connection-' + next.tag + '"', 23)
      } else if (root.phase === 23) {
        var next = root.recoveryCases[root.recoveryCase]
        if (!root.has(text, "STATUS START " + next.tag)) return
        if (next.reconcile && !root.check(root.service.connectionBusy && root.completions === root.completedAtStart,
            "failed/incomplete command did not await a fresh probe: " + next.tag)) return
        if (!next.reconcile && !root.check(!root.service.connectionBusy && root.completions === root.completedAtStart + 1,
            "successful command waited for its status probe: " + next.tag)) return
        root.expectedConnected = next.connected
        root.expectedStatusUnavailable = next.probe === "block-fail"
        root.control('touch "$1/release-status-' + next.tag + '"', 24)
      } else if (root.phase === 24) {
        var next = root.recoveryCases[root.recoveryCase]
        if (!root.has(text, "STATUS END " + next.tag) || root.service.connectionBusy) return
        if (!root.check(root.completions === root.completedAtStart + 1, "connection completion signal count changed")) return
        root.checkSettled()
        if (next.probe === "block-fail") {
          if (!root.check(root.service.connectionStatus.probe === "reenabled", "failed probe discarded latest full status")) return
        } else if (root.service.connectionStatus.probe !== next.tag) return
        root.recoveryCase++
        if (root.recoveryCase < root.recoveryCases.length) root.phase = 21
        else root.control('printf "ordinary-failure true block-fail\\n" >"$1/status-plan"', 32)
      } else if (root.phase === 32) {
        root.service.reconcile("connection fixture: ordinary status failure")
        root.phase = 33
      } else if (root.phase === 33) {
        if (!root.has(text, "STATUS START ordinary-failure")) return
        root.expectedStatusUnavailable = true
        root.control('touch "$1/release-status-ordinary-failure"', 34)
      } else if (root.phase === 34) {
        if (!root.has(text, "STATUS END ordinary-failure") || root.service.enabled) return
        root.checkSettled()
        if (!root.check(!root.service.connectionBusy && root.service.connectionStatus.probe === "before-failed-start",
            "ordinary probe failure did not preserve UI state independently of engine readiness")) return
        root.control('printf "ordinary-recovered true block\\n" >"$1/status-plan"', 35)
      } else if (root.phase === 35) {
        root.service.reconcile("connection fixture: ordinary status recovery")
        root.phase = 36
      } else if (root.phase === 36) {
        if (!root.has(text, "STATUS START ordinary-recovered")) return
        if (!root.check(!root.service.enabled, "engine resumed before successful status arrived")) return
        root.expectedStatusUnavailable = false
        root.control('touch "$1/release-status-ordinary-recovered"', 37)
      } else if (root.phase === 37) {
        if (root.service.connectionStatus.probe !== "ordinary-recovered") return
        root.checkSettled()
        root.control('mv "$1/connection-runner" "$1/connection-runner.saved"', 25)
      } else if (root.phase === 25) {
        root.expectedOperation = "disconnect"
        root.expectedOk = false
        root.expectedProbe = "ordinary-recovered"
        root.expectedStatusUnavailable = true
        root.completedAtStart = root.completions
        if (!root.check(root.service.requestDisconnect(), "failed-start request was not accepted")) return
        root.phaseAt = Date.now()
        root.phase = 26
      } else if (root.phase === 26) {
        if (root.service.connectionBusy || Date.now() - root.phaseAt < 100) return
        if (!root.check(root.completions === root.completedAtStart + 1,
            "failed command/probe start did not settle exactly once")) return
        if (!root.check(!root.service.enabled && root.service.connectionStatus.integrationComplete === true,
            "failed command/probe start did not fail closed while preserving UI state")) return
        root.control('mv "$1/connection-runner.saved" "$1/connection-runner"; '
          + 'printf "retry success false\\n" >"$1/connection-plan"; '
          + 'printf "before-late true block\\n" >"$1/status-plan"', 27)
      } else if (root.phase === 27) {
        root.service.reconcile("connection fixture: pre-operation probe returns after completion")
        root.phase = 30
      } else if (root.phase === 30) {
        if (!root.has(text, "STATUS START before-late")) return
        root.expectedOk = true
        root.expectedConnected = false
        root.expectedStatusUnavailable = false
        root.expectedProbe = ""
        if (!root.check(root.service.requestDisconnect(), "request after failed start was rejected")) return
        root.control('printf "retry false immediate\\n" >"$1/status-plan"; '
          + 'touch "$1/release-connection-retry"', 31)
      } else if (root.phase === 31) {
        if (root.completions !== root.completedAtStart + 2) return
        root.control('touch "$1/release-status-before-late"', 28)
      } else if (root.phase === 28) {
        if (root.service.connectionStatus.probe !== "retry") return
        if (!root.check(!root.service.connectionBusy && root.completions === root.completedAtStart + 2,
            "failed-start recovery left busy or duplicate completion signals")) return
        root.finish(true, "")
      }
    }
  }

  Timer {
    id: deadline
    interval: 20000
    onTriggered: root.finish(false, "timed out in phase " + root.phase + "; calls:\n" + root.readCalls())
  }

  Component.onCompleted: {
    var component = Qt.createComponent("Service.qml")
    if (!check(component.status === Component.Ready, component.errorString())) return
    service = component.createObject(this, {})
    if (!check(!!service, "Service.qml createObject returned null")) return
    poll.start()
    deadline.start()
  }
}
