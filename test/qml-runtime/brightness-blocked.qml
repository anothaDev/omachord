import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property var service: null
  property var panel: null
  readonly property string testDir: Quickshell.env("OMACHORD_QML_TEST_DIR")
  readonly property var unavailable: ({ ok: false, code: "brightness-unavailable", error: "activate: brightness unavailable" })
  property var plan: ({
    revision: "sha256:" + "a".repeat(64), toggles: ["scratch"],
    reply: unavailable, manualReply: unavailable,
    config: { version: 1, routines: [{ id: "scratch", name: "Scratch", enabled: true, triggers: [],
      conditions: [{ type: "omarchy-toggle", flag: "scratch" }],
      actions: [{ type: "brightness", value: 50, restore: true }] }] }
  })
  TestCase { id: input; name: "BrightnessBlocked"; when: false }
  FileView { id: calls; path: root.testDir + "/calls.log"; blockLoading: true; blockAllReads: true; preload: true }
  Process { id: control }
  function check(value, message) { if (!value) throw new Error(message) }
  function waitFor(predicate, message) {
    var until = Date.now() + 4000
    while (!predicate() && Date.now() < until) input.wait(20)
    check(predicate(), message)
  }
  function savePlan() {
    control.command = ["bash", "-c", "printf '%s' \"$1\" >\"$2/plan.json\"", "fixture", JSON.stringify(plan), testDir]
    control.running = true
    waitFor(function() { return !control.running }, "fixture control did not finish")
  }
  function countCalls(prefix) {
    calls.reload()
    return String(calls.text()).split("\n").filter(function(line) { return line.indexOf(prefix) === 0 }).length
  }
  function state() { return JSON.parse(service.statusJson()).routines[0] }
  function waitFailure() {
    waitFor(function() { return state().failure && !service.routineBusy("scratch") }, "activation did not fail")
  }
  function ageFailure() {
    // Clock seam: age only the failure, then exercise the real service tick.
    var failures = JSON.parse(JSON.stringify(service.failures))
    failures.scratch.at = Date.now() - 2 * service.failureRetryMs
    service.failures = failures
    service.tick()
    service.evaluate()
  }
  function testBlockedActivation() {
    savePlan()
    var component = Qt.createComponent("Service.qml")
    check(component.status === Component.Ready, component.errorString())
    service = component.createObject(root, {})
    waitFor(function() { return service.configLoaded && service.activeLoaded && service.latchesSeeded }, "service did not initialize")
    waitFailure()
    waitFor(function() { return countCalls("activate scratch condition ") === 1 }, "initial activation was not recorded")
    check(state().failure.blocked === true && state().failure.retryAt === null,
      "typed capability failure was not recorded as blocked")
    check(state().latched && !state().active, "preflight failure must latch without activation")
    for (var i = 0; i < 3; i++) {
      ageFailure()
      input.wait(350)
      check(state().failure && state().failure.blocked && state().latched, "tick expired or unlatched blocked activation")
    }
    check(countCalls("activate scratch condition ") === 1, "blocked activation retried automatically")
  }
  function testFailedManualRetry() {
    check(service.startRoutine("scratch"), "blocked routine refused explicit retry")
    waitFor(function() { return !service.routineBusy("scratch") }, "manual retry did not settle")
    input.wait(350) // Include the runner history refresh, not just its reply.
    check(service.lastManualResult.code === "brightness-unavailable", "manual failure was not surfaced")
    check(state().failure && state().failure.blocked && state().latched,
      "failed manual retry/log released the blocked latch")
    // Without the latch, a false edge could not release the stored failure.
    plan.toggles = []
    savePlan()
    service.applyToggles([])
    service.evaluate()
    check(!state().failure && !state().latched, "false edge did not clear blocked state")
    plan.toggles = ["scratch"]
    savePlan()
    service.applyToggles(["scratch"])
    service.evaluate()
    waitFailure()
    waitFor(function() { return countCalls("activate scratch condition ") === 2 }, "new true edge did not retry")
  }
  function testSuccessfulManualRetry() {
    plan.manualReply = { ok: true }
    savePlan()
    var clearedAtCompletion = false
    var completed = function(job, result) {
      if (job.id === "scratch" && result.ok) clearedAtCompletion = !state().failure && state().latched
    }
    service.manualFinished.connect(completed)
    check(service.startRoutine("scratch"), "successful manual retry was rejected")
    waitFor(function() { return !service.routineBusy("scratch") }, "successful retry did not settle")
    service.manualFinished.disconnect(completed)
    check(clearedAtCompletion, "manual success signalled before blocked failure was reconciled")
    waitFor(function() { return state().active }, "manual success was not observed active")
    check(!state().failure && state().latched, "manual success did not clear failure and retain latch")
    check(service.endRoutine("scratch"), "manual end was rejected")
    waitFor(function() { return !service.routineBusy("scratch") }, "manual end did not settle")
    input.wait(350)
    check(!state().active && state().latched, "manual end was undone while conditions remained true")
    check(countCalls("activate scratch condition ") === 2, "manual success/end caused another automatic start")
  }
  function setMatched(matched) {
    plan.toggles = matched ? ["scratch"] : []
    savePlan()
    service.applyToggles(plan.toggles)
    service.evaluate()
  }
  function snapshot() { return { ok: true, committed: true, revision: plan.revision, config: plan.config } }
  function testRevisionAndExternalSuccess() {
    setMatched(false)
    setMatched(true)
    waitFailure()
    service.applyConfig(snapshot())
    check(state().failure.blocked && state().latched, "same revision released blocked state")
    plan.revision = "sha256:" + "b".repeat(64)
    savePlan()
    service.applyConfig(snapshot())
    check(!state().failure && !state().latched, "new config revision did not clear blocked state")
    service.evaluate()
    waitFailure()
    waitFor(function() { return countCalls("activate scratch condition ") === 4 }, "new revision did not retry")
    service.applyLiveLog({ routineId: "scratch", trigger: "condition", status: "success" })
    check(state().failure.blocked, "an automatic success log cleared a blocked explicit-retry requirement")
    // CLI/shortcut activations report through history, not manualFinished.
    service.applyLiveLog({ routineId: "scratch", trigger: "manual", status: "success" })
    check(!state().failure && state().latched, "external successful retry did not reconcile blocked state")
    service.evaluate()
    input.wait(350)
    check(countCalls("activate scratch condition ") === 4, "successful one-shot log caused duplicate activation")
  }
  function testRetryableFailures() {
    // Matching prose is not a capability signal; only the exact typed code is.
    var replies = [
      { ok: false, code: "action-failed", error: unavailable.error },
      { ok: false, error: unavailable.error }
    ]
    for (var i = 0; i < replies.length; i++) {
      setMatched(false)
      plan.reply = replies[i]
      setMatched(true)
      waitFailure()
      check(state().failure.blocked === false && state().failure.retryAt !== null, "untyped/other failure was blocked")
      var before = countCalls("activate scratch condition ")
      ageFailure()
      waitFor(function() { return countCalls("activate scratch condition ") === before + 1 }, "ordinary failure did not retry")
      waitFailure()
    }
    setMatched(false)
    plan.reply = { ok: true }
    setMatched(true)
    waitFor(function() { return state().active && !service.routineBusy("scratch") }, "recovery setup activation failed")
    plan.reply = { ok: false, code: "brightness-unavailable", error: "deactivate: brightness unavailable" }
    setMatched(false)
    waitFailure()
    check(state().active && state().failure.op === "deactivate" && !state().failure.blocked
      && state().failure.retryAt !== null, "typed deactivation failure abandoned recovery")
    service.evaluate()
    input.wait(350)
    check(countCalls("deactivate scratch condition ") === 1, "deactivation skipped retry backoff")
    ageFailure()
    waitFor(function() { return countCalls("deactivate scratch condition ") === 2 }, "typed deactivation failure did not retry")
    waitFailure()
    check(state().active && !state().failure.blocked, "failed recovery lost its active record")
    plan.reply = { ok: true }
    savePlan()
    ageFailure()
    waitFor(function() { return !state().active && !service.routineBusy("scratch") }, "recovery never completed")
    check(!state().failure, "successful deactivation retained failure")
  }
  function testPanel() {
    plan.reply = unavailable
    setMatched(true)
    waitFailure()
    var component = Qt.createComponent("Panel.qml")
    check(component.status === Component.Ready, component.errorString())
    panel = component.createObject(root, { service: service })
    var reason = panel.conditionReason(plan.config.routines[0], state())
    check(reason.label === "Unavailable" && reason.urgent, "panel does not label blocked activation Unavailable")
    check(reason.detail.indexOf("retrying") === -1 && reason.detail.indexOf("manually") !== -1
      && reason.detail.indexOf("edit") !== -1, "panel invents a retry time or omits manual retry/edit advice")
    var recovery = { failure: { op: "deactivate", error: "restore failed", blocked: false, retryAt: Date.now() + 300000 } }
    reason = panel.conditionReason(plan.config.routines[0], recovery)
    check(reason.label === "Failed" && reason.detail.indexOf("retrying") !== -1, "panel hides recovery retry timing")
    panel.destroy()
    panel = null
  }
  function testManualRunOutcomes() {
    // `run` can end a routine too; a successful End is not a successful retry.
    plan.manualReply = { ok: true, state: "deactivated" }
    savePlan()
    check(service.toggleRoutine("scratch"), "manual toggle was rejected")
    waitFor(function() { return !service.routineBusy("scratch") }, "manual toggle did not settle")
    input.wait(350)
    check(state().failure && state().failure.blocked && state().latched, "successful End cleared an activation block")
    plan.manualReply = { ok: true, state: "success" }
    savePlan()
    check(service.testRoutine("scratch"), "manual test retry was rejected")
    waitFor(function() { return !service.routineBusy("scratch") }, "manual one-shot did not settle")
    check(service.lastManualResult.ok && service.lastManualResult.state === undefined,
      "fixture did not exercise the runner's one-shot reply")
    check(!state().failure && state().latched && !state().active, "one-shot success did not reconcile blocked state")
    var before = countCalls("activate scratch condition ")
    service.tick()
    service.evaluate()
    input.wait(350)
    check(countCalls("activate scratch condition ") === before, "one-shot success was automatically repeated")
  }
  Timer {
    interval: 20; running: true; repeat: false
    onTriggered: {
      try {
        root.testBlockedActivation(); root.testFailedManualRetry(); root.testSuccessfulManualRetry()
        root.testRevisionAndExternalSuccess()
        root.testRetryableFailures(); root.testPanel()
        root.testManualRunOutcomes()
        console.log("OMACHORD_QML_TEST_PASS")
      }
      catch (error) { console.error("OMACHORD_QML_TEST_FAIL", String(error)) }
    }
  }
}
