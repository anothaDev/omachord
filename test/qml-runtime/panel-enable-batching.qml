import QtQuick
import Quickshell
import Quickshell.Io

// Exercises Panel.qml with real Quickshell Process objects. In particular,
// this catches regressions where onRunningChanged(false) and onExited clear or
// strand intents that arrived while an older full-config apply was running.
ShellRoot {
  id: root

  property var panel: null
  property int phase: 0
  property string failure: ""

  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property string callsPath: testDir + "/panel-calls.log"

  function fail(detail) {
    if (failure) return
    failure = String(detail || "panel enable batching runtime test failed")
    poll.stop()
    deadline.stop()
    console.error("OMACHORD_QML_TEST_FAIL", failure)
  }

  function pass() {
    poll.stop()
    deadline.stop()
    console.log("OMACHORD_QML_TEST_PASS")
  }

  function routineEnabled(id) {
    if (!panel || !panel.config || !Array.isArray(panel.config.routines)) return null
    for (var i = 0; i < panel.config.routines.length; i++)
      if (panel.config.routines[i].id === id) return panel.config.routines[i].enabled === true
    return null
  }

  function startCount(text) {
    var matches = String(text || "").match(/^START /gm)
    return matches ? matches.length : 0
  }

  function payloadFor(text, number) {
    var lines = String(text || "").split("\n")
    var prefix = "START " + number + " "
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf(prefix) !== 0) continue
      try { return JSON.parse(lines[i].slice(prefix.length)) } catch (e) { return null }
    }
    return null
  }

  function payloadEnabled(payload, id) {
    if (!payload || !Array.isArray(payload.routines)) return null
    for (var i = 0; i < payload.routines.length; i++)
      if (payload.routines[i].id === id) return payload.routines[i].enabled === true
    return null
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

  Timer {
    id: poll
    interval: 20
    repeat: true
    onTriggered: {
      if (!root.panel || root.failure) return
      var calls = root.readCalls()

      if (root.phase === 0 && calls.indexOf("START 1 ") !== -1) {
        if (root.routineEnabled("alpha") !== false) {
          root.fail("first optimistic value was not visible while apply 1 was running")
          return
        }
        // Both a newer value for the submitted row and an unrelated row must
        // survive apply 1's normal onExited/onRunningChanged completion.
        root.panel.setRoutineEnabled("alpha", true)
        root.panel.setRoutineEnabled("beta", false)
        if (root.routineEnabled("alpha") !== true || root.routineEnabled("beta") !== false) {
          root.fail("new in-flight intents were not reflected optimistically")
          return
        }
        root.phase = 1
        return
      }

      if (root.phase === 1 && calls.indexOf("START 2 ") !== -1) {
        var second = root.payloadFor(calls, 2)
        if (root.payloadEnabled(second, "alpha") !== true
            || root.payloadEnabled(second, "beta") !== false) {
          root.fail("apply 2 lost a same-row or unrelated in-flight intent: " + JSON.stringify(second))
          return
        }
        root.phase = 2
        return
      }

      if (root.phase === 2 && !root.panel.mutating) {
        if (root.startCount(calls) !== 2 || root.panel.configRevision !== "sha256:apply-2"
            || root.routineEnabled("alpha") !== true || root.routineEnabled("beta") !== false
            || Object.keys(root.panel.enableIntents).length !== 0) {
          root.fail("the first batch did not settle cleanly after two ordered applies")
          return
        }
        // Apply 3 is rejected as stale by the fixture. The snapshot changes
        // beta and adds gamma; retry 4 must preserve both while overlaying the
        // still-pending alpha intent.
        root.panel.setRoutineEnabled("alpha", false)
        root.phase = 3
        return
      }

      if (root.phase === 3 && calls.indexOf("START 4 ") !== -1) {
        var fourth = root.payloadFor(calls, 4)
        if (calls.indexOf("SNAPSHOT") === -1
            || root.payloadEnabled(fourth, "alpha") !== false
            || root.payloadEnabled(fourth, "beta") !== true
            || root.payloadEnabled(fourth, "gamma") !== true) {
          root.fail("stale retry was not rebased onto the external snapshot: " + JSON.stringify(fourth))
          return
        }
        root.phase = 4
        return
      }

      if (root.phase === 4 && !root.panel.mutating) {
        if (root.panel.configRevision !== "sha256:rebased"
            || root.routineEnabled("alpha") !== false
            || root.routineEnabled("beta") !== true
            || root.routineEnabled("gamma") !== true) {
          root.fail("rebased apply did not become the committed panel base")
          return
        }
        root.panel.setRoutineEnabled("beta", false)
        if (root.routineEnabled("beta") !== false) {
          root.fail("hard-failure scenario was not optimistic before persistence")
          return
        }
        root.phase = 5
        return
      }

      if (root.phase === 5 && calls.indexOf("START 5 ") !== -1 && !root.panel.mutating) {
        if (root.startCount(calls) !== 5
            || root.routineEnabled("alpha") !== false
            || root.routineEnabled("beta") !== true
            || root.routineEnabled("gamma") !== true
            || Object.keys(root.panel.enableIntents).length !== 0
            || !root.panel.noticeError) {
          root.fail("hard apply failure did not roll back to the last committed base")
          return
        }
        root.pass()
      }
    }
  }

  Timer {
    id: deadline
    interval: 15000
    repeat: false
    onTriggered: root.fail("timed out in phase " + root.phase + "; calls were:\n" + root.readCalls())
  }

  Component.onCompleted: {
    var component = Qt.createComponent("Panel.qml")
    if (component.status !== Component.Ready) {
      fail(component.errorString())
      return
    }
    panel = component.createObject(root, {})
    if (!panel) {
      fail("Panel.qml createObject returned null")
      return
    }
    panel.config = {
      version: 1,
      routines: [
        { id: "alpha", name: "Alpha", enabled: true, triggers: [], actions: [{ type: "delay", milliseconds: 0 }] },
        { id: "beta", name: "Beta", enabled: true, triggers: [], actions: [{ type: "delay", milliseconds: 0 }] }
      ]
    }
    panel.configRevision = "sha256:base"
    panel.configLoaded = true
    panel.loading = false
    panel.setRoutineEnabled("alpha", false)
    deadline.start()
    poll.start()
  }
}
