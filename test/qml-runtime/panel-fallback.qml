import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// Real Panel processes against a private, gated runner. No resident service
// or live shell is loaded; the harness also stubs supplemental shell commands.
ShellRoot {
  id: root
  property var panel: null
  property var window: null
  property string failure: ""
  property bool watchUnlock: false
  property bool expectedConnected: false
  property bool watchAlphaUnlock: false
  property bool expectedAlpha: false
  readonly property bool alphaBusy: !!panel && panel.routineActionBusy("alpha")
  property int controlExit: -1
  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")

  onAlphaBusyChanged: {
    if (watchAlphaUnlock && !alphaBusy)
      check(!!panel.activeIds.alpha === expectedAlpha,
        "routine unlocked before publishing its fresh active state")
  }

  TestCase { id: input; name: "PanelFallback"; when: false }
  FileView {
    id: callsView
    path: root.testDir + "/transition-calls.log"
    blockLoading: true
    printErrors: false
  }
  Process {
    id: controlProc
    onExited: function(exitCode) { root.controlExit = exitCode }
  }
  Connections {
    target: root.panel
    function onIntegrationBusyChanged() {
      if (root.watchUnlock && !root.panel.integrationBusy)
        root.check(root.panel.integrationOn === root.expectedConnected,
          "connection unlocked before publishing its confirmed state")
    }
    function onStatusChanged() {
      var tag = root.panel.status.probe
      root.check(tag !== "before" && tag !== "before-late",
        "a pre-transition status snapshot overwrote the confirmed state")
    }
  }

  function check(condition, message) {
    if (condition) return
    if (!failure) failure = message
    throw new Error(message)
  }

  function waitFor(predicate, message) {
    var until = Date.now() + 4000
    while (!predicate() && !failure && Date.now() < until) input.wait(20)
    check(!failure && predicate(), failure || message)
  }

  function control(script, args) {
    controlExit = -1
    controlProc.command = ["bash", "-c", script, "fixture", testDir].concat(args || [])
    controlProc.running = true
    waitFor(function() { return root.controlExit !== -1 }, "fixture control did not finish")
    check(controlExit === 0, "fixture control failed")
  }

  function plan(operation, value) {
    control('printf "%s\\n" "$3" >"$1/$2-plan.json"', [operation, JSON.stringify(value)])
  }

  function release(tag) { control('touch -- "$1/release-$2"', [tag]) }

  function calls() { callsView.reload(); return String(callsView.text() || "") }
  function started(operation, tag) { return calls().indexOf(operation + " START " + tag + " ") !== -1 }
  function startCount(operation, tag) { return calls().split(operation + " START " + tag + " ").length - 1 }
  function waitStarted(operation, tag) {
    waitFor(function() { return started(operation, tag) }, operation + " did not start: " + tag)
  }

  function status(connected, tag) {
    return { ok: true, connected: connected, ownedConnection: connected,
      integrationComplete: connected, connectionEnabled: connected, probe: tag }
  }

  function findWindow(item) {
    for (var child of item.data)
      if (child && child.contentItem !== undefined && child.title !== undefined) return child
    return null
  }

  function waitSettled(connected) {
    waitFor(function() { return !panel.integrationBusy }, "connection remained busy")
    check(panel.integrationOn === connected, "connection settled to the wrong state")
  }

  function testSuccessfulConnections() {
    plan("status", { tag: "before", reply: status(false, "before"), block: true })
    panel.requestRefresh()
    waitStarted("status", "before")
    waitFor(function() { return panel.configLoaded }, "configuration refresh did not finish")
    plan("connect", { tag: "connect", block: true })
    expectedConnected = true
    watchUnlock = true
    var toggle = input.findChild(window.contentItem, "panelIntegrationSwitch")
    check(!!toggle, "panel integration switch is missing")
    var size = [toggle.width, toggle.height]
    toggle.requestToggle()
    waitStarted("connect", "connect")
    check(calls().indexOf("connect START connect connect sha256:base") !== -1,
      "direct connect must forward the loaded revision")
    check(toggle.busy && !toggle.checked, "pending connect must retain the confirmed off state")
    toggle.requestToggle()
    panel.requestIntegrationToggle()
    check(startCount("connect", "connect") === 1, "pending connect accepted a duplicate")
    plan("status", { tag: "during", reply: status(false, "during"), block: true })
    panel.refreshSupplemental()
    release("before")
    input.wait(100)
    check(!started("status", "during"), "a status refresh crossed the connection barrier")
    plan("status", { tag: "connected", reply: status(true, "connected"), block: true })
    release("connect")
    waitSettled(true)
    waitStarted("status", "connected")
    check(!toggle.busy && toggle.checked && toggle.width === size[0] && toggle.height === size[1],
      "successful connect must settle the stable-size switch before the next probe")
    release("connected")
    waitFor(function() { return panel.status.probe === "connected" }, "fresh connected status was not accepted")

    // The old probe now returns after the transaction has already succeeded.
    plan("status", { tag: "before-late", reply: status(true, "before-late"), block: true })
    panel.refreshSupplemental()
    waitStarted("status", "before-late")
    plan("disconnect", { tag: "disconnect", block: true })
    expectedConnected = false
    panel.mutateConnection("disconnect")
    waitStarted("disconnect", "disconnect")
    plan("status", { tag: "disconnected", reply: status(false, "disconnected") })
    release("disconnect")
    waitSettled(false)
    check(!started("status", "disconnected"), "the stale probe should still be blocked")
    release("before-late")
    waitFor(function() { return panel.status.probe === "disconnected" }, "late stale probe did not drain the fresh refresh")
  }

  function testFailureReconciliation() {
    plan("connect", { tag: "failed-connect", reply: { ok: false, error: "Fixture connection failure" }, exitCode: 1 })
    plan("status", { tag: "recovered", reply: status(true, "recovered"), block: true })
    expectedConnected = true
    panel.mutateConnection("connect")
    waitStarted("status", "recovered")
    check(panel.integrationBusy && !panel.integrationOn,
      "failed command must remain pending with the old state until reconciliation")
    panel.requestIntegrationToggle()
    check(startCount("connect", "failed-connect") === 1, "failure reconciliation accepted a duplicate")
    release("recovered")
    waitSettled(true)
    check(panel.noticeError, "failed command must retain its error after successful reconciliation")
  }

  function testUnavailableProbes() {
    var cases = [
      { tag: "nonzero", reply: status(false, "nonzero"), exitCode: 1, block: true },
      { tag: "malformed", raw: "not json", block: true },
      { tag: "incomplete", reply: { ok: true }, block: true }
    ]
    for (var next of cases) {
      plan("disconnect", { tag: "failed-" + next.tag, reply: { ok: false, error: "Fixture disconnect failure" }, exitCode: 1 })
      plan("status", next)
      panel.mutateConnection("disconnect")
      waitStarted("status", next.tag)
      check(panel.integrationBusy && panel.integrationOn, "unavailable probe must start with the confirmed state pending")
      release(next.tag)
      waitSettled(true)
    }
  }

  function testFailedStarts() {
    // The command starts successfully, but its follow-up status cannot start.
    plan("disconnect", { tag: "before-missing-probe", reply: { ok: false, error: "Fixture disconnect failure" }, exitCode: 1, block: true })
    panel.mutateConnection("disconnect")
    waitStarted("disconnect", "before-missing-probe")
    control('mv -- "$1/runner" "$1/runner.saved"')
    release("before-missing-probe")
    waitSettled(true)
    check(panel.noticeError, "failed status start must retain the command error")

    // Neither the next command nor its reconciliation process can start.
    panel.mutateConnection("disconnect")
    waitSettled(true)
    check(panel.noticeError, "failed command start must report an error")
    control('mv -- "$1/runner.saved" "$1/runner"')
    plan("disconnect", { tag: "retry" })
    plan("status", { tag: "retry-status", reply: status(false, "retry-status") })
    expectedConnected = false
    panel.mutateConnection("disconnect")
    waitSettled(false)
    waitFor(function() { return panel.status.probe === "retry-status" }, "connection did not recover after failed starts")
  }

  function testRoutineSettling() {
    watchUnlock = false
    plan("run", { tag: "activate-alpha" })
    plan("active", { tag: "active-alpha", reply: [{ routineId: "alpha" }], block: true })
    var live = input.findChild(window.contentItem, "routineLiveSwitch")
    check(!!live && !live.checked, "live switch must start off")
    expectedAlpha = true
    watchAlphaUnlock = true
    live.requestToggle()
    waitStarted("active", "active-alpha")
    check(live.busy && panel.routineActionBusy("alpha") && !live.checked,
      "live switch must remain pending until its post-run active snapshot arrives")
    live.requestToggle()
    panel.runRoutine("alpha")
    input.wait(60)
    check(startCount("run", "activate-alpha") === 1, "settling routine accepted a repeat toggle")
    release("active-alpha")
    waitFor(function() { return !panel.routineActionBusy("alpha") }, "live switch did not settle")
    check(live.checked && !live.busy, "live switch must publish fresh active state before unlocking")
  }

  function testPerRoutineFreshness() {
    plan("active", { tag: "active-before-end", reply: [{ routineId: "alpha" }], block: true })
    panel.refreshSupplemental()
    waitStarted("active", "active-before-end")
    plan("deactivate", { tag: "end-alpha" })
    expectedAlpha = false
    panel.endRoutine("alpha")
    waitFor(function() { return calls().indexOf("deactivate END end-alpha") !== -1 }, "routine did not end")
    // An already-running probe cannot acknowledge the new request, even if it
    // returns only after the command finishes.
    plan("active", { tag: "alpha-ended", reply: [], block: true })
    release("active-before-end")
    waitStarted("active", "alpha-ended")
    check(panel.routineActionBusy("alpha") && !!panel.activeIds.alpha,
      "pre-request active snapshot must not release routine pending state")
    panel.endRoutine("alpha")
    check(startCount("deactivate", "end-alpha") === 1, "settling end request accepted a duplicate")

    // Only the same id is held by reconciliation; the direct runner's existing
    // single-process execution policy otherwise stays unchanged.
    check(!panel.routineActionBlocked("beta"), "alpha reconciliation globally blocked unrelated routine work")
    plan("run", { tag: "activate-beta" })
    panel.runRoutine("beta")
    waitFor(function() { return calls().indexOf("run END activate-beta") !== -1 }, "unrelated routine did not run")
    plan("active", { tag: "beta-active", reply: [{ routineId: "beta" }], block: true })
    release("alpha-ended")
    waitStarted("active", "beta-active")
    check(!panel.routineActionBusy("alpha") && !panel.activeIds.alpha,
      "the first fresh snapshot did not settle alpha")
    check(panel.routineActionBusy("beta") && !panel.activeIds.beta,
      "a snapshot started before beta completed incorrectly settled beta")
    release("beta-active")
    waitFor(function() { return !panel.routineActionBusy("beta") }, "beta did not settle independently")
    check(!!panel.activeIds.beta, "beta unlocked before its active state arrived")
  }

  function testRoutineProbeFailures() {
    var cases = [
      { tag: "active-nonzero", reply: [], exitCode: 1, block: true },
      { tag: "active-malformed", raw: "not json", block: true },
      { tag: "active-incomplete", reply: { ok: true }, block: true }
    ]
    for (var next of cases) {
      plan("run", { tag: "run-" + next.tag, reply: { ok: false, error: "Fixture routine failure" }, exitCode: 1 })
      plan("active", next)
      panel.runRoutine("alpha")
      waitStarted("active", next.tag)
      check(panel.routineActionBusy("alpha"), "failed routine must wait for its active probe")
      release(next.tag)
      waitFor(function() { return !panel.routineActionBusy("alpha") }, "failed active probe stranded routine busy")
      check(!panel.activeIds.alpha && !!panel.activeIds.beta, "failed active probe erased confirmed state")
    }

    plan("run", { tag: "run-before-missing-probe", block: true })
    panel.runRoutine("alpha")
    waitStarted("run", "run-before-missing-probe")
    control('mv -- "$1/runner" "$1/runner.saved"')
    release("run-before-missing-probe")
    waitFor(function() { return !panel.routineActionBusy("alpha") }, "failed active probe start stranded routine busy")
    check(!panel.activeIds.alpha && !!panel.activeIds.beta, "failed active probe start changed confirmed state")
    panel.runRoutine("alpha")
    waitFor(function() { return !panel.routineActionBusy("alpha") }, "failed routine start stranded routine busy")
    check(panel.noticeError, "failed routine start did not report an error")
    control('mv -- "$1/runner.saved" "$1/runner"')
    plan("run", { tag: "routine-retry" })
    plan("active", { tag: "routine-retry-active", reply: [{ routineId: "alpha" }, { routineId: "beta" }] })
    expectedAlpha = true
    panel.runRoutine("alpha")
    waitFor(function() { return !panel.routineActionBusy("alpha") && !!panel.activeIds.alpha },
      "routine did not recover after failed command/probe starts")
  }

  Timer {
    interval: 30
    running: true
    onTriggered: {
      try {
        root.plan("status", { tag: "initial", reply: root.status(false, "initial") })
        var component = Qt.createComponent("Panel.qml")
        root.check(component.status === Component.Ready, component.errorString())
        root.panel = component.createObject(root, {})
        root.check(!!root.panel && !root.panel.serviceLive, "fallback panel must have no service")
        root.window = root.findWindow(root.panel)
        root.window.visible = true
        root.panel.requestRefresh()
        root.waitFor(function() { return root.panel.configLoaded && root.panel.status.probe === "initial" },
          "initial fallback configuration/status did not load")
        root.testSuccessfulConnections()
        root.testFailureReconciliation()
        root.testUnavailableProbes()
        root.testFailedStarts()
        root.testRoutineSettling()
        root.testPerRoutineFreshness()
        root.testRoutineProbeFailures()
        root.check(!root.failure, root.failure)
        console.log("OMACHORD_QML_TEST_PASS", "direct Panel connection fallback")
      } catch (error) {
        console.error("OMACHORD_QML_TEST_FAIL", String(error), "calls:\n" + root.calls())
      }
      Qt.quit()
    }
  }
}
