import QtQuick

// A deadline for one runner Process. A runner that never exits would keep
// its caller waiting forever: the service's connection barrier and routine
// queues, or the panel's loading and saving locks. Once `deadlineMs` passes
// the process is stopped (SIGTERM, which the runner traps to abort its
// transaction), and killed if it is still running `graceMs` later. The
// process's own exit handler then runs with a non-zero exit code, so the
// caller recovers through its existing failure path; `expired` tells that
// handler why, until the process next starts.
Item {
  id: root
  visible: false

  property var process: null
  property int deadlineMs: 30000
  property int graceMs: 5000
  // The runner command, for the message shown when it is stopped.
  property string label: ""
  property bool expired: false
  readonly property string reason: "The Omachord runner" + (label ? " (" + label + ")" : "")
    + " did not finish within " + (deadlineMs >= 1000 ? Math.round(deadlineMs / 1000) + " s" : deadlineMs + " ms")
    + " and was stopped"

  signal timedOut()

  // The process's output, or once it was stopped, a runner-shaped refusal
  // that the caller's ordinary failure handling can report.
  function reply(text) {
    return expired ? JSON.stringify({ ok: false, code: "timeout", error: reason }) : String(text || "")
  }

  function sync() {
    if (process && process.running) {
      if (deadline.running || grace.running) return
      expired = false
      deadline.interval = Math.max(1, deadlineMs)
      deadline.start()
    } else {
      deadline.stop()
      grace.stop()
    }
  }

  onProcessChanged: sync()

  Connections {
    target: root.process
    ignoreUnknownSignals: true
    function onRunningChanged() { root.sync() }
  }

  Timer {
    id: deadline
    repeat: false
    onTriggered: {
      if (!root.process || !root.process.running) return
      root.expired = true
      console.warn("omachord: " + root.reason)
      root.timedOut()
      grace.interval = Math.max(1, root.graceMs)
      grace.start()
      root.process.running = false
    }
  }

  Timer {
    id: grace
    repeat: false
    onTriggered: if (root.process && root.process.running) root.process.signal(9)
  }
}
