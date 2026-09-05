import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property var service: null
  property var panel: null
  readonly property string revisionA: "sha256:" + "a".repeat(64)
  readonly property string revisionB: "sha256:" + "b".repeat(64)
  readonly property string revisionC: "sha256:" + "c".repeat(64)
  TestCase { id: input; name: "ManualRevision"; when: false }
  FileView { id: calls; path: Quickshell.env("OMACHORD_QML_TEST_DIR") + "/calls.log"; blockLoading: true; preload: true }
  function check(value, message) { if (!value) throw new Error(message) }
  function waitFor(predicate, message) {
    var until = Date.now() + 4000
    while (!predicate() && Date.now() < until) input.wait(20)
    check(predicate(), message)
  }
  function hasCall(expected) { calls.reload(); return ("\n" + calls.text()).indexOf("\n" + expected + "\n") !== -1 }
  function testService() {
    var component = Qt.createComponent("Service.qml")
    check(component.status === Component.Ready, component.errorString())
    service = component.createObject(root, {})
    waitFor(function() { return service.configLoaded }, "service did not load fixture config")
    check(!service.startRoutine("invalid", null), "malformed explicit revision was replaced by current state")
    check(!service.startRoutine("empty", ""), "empty explicit revision was accepted")
    service.manualSettling = { alpha: 1000000 }
    check(service.testRoutine("alpha", revisionA), "reviewed test request was rejected")
    check(service.manualQueue.length === 1 && service.manualQueue[0].revision === revisionA,
      "queued routine did not capture the click's reviewed revision")
    service.configRevision = revisionB
    check(service.manualQueue[0].revision === revisionA, "config refresh rebound a queued request")
    service.manualSettling = ({})
    service.runNextManual()
    waitFor(function() { return !service.routineBusy("alpha") }, "stale request did not settle")
    waitFor(function() { return hasCall("run alpha test " + revisionA) }, "worker did not forward captured revision")
    check(service.lastManualResult.code === "stale-config", "stale response was not surfaced")
    check(service.startRoutine("beta"), "current service request was rejected")
    waitFor(function() { return !service.routineBusy("beta") }, "current request did not settle")
    waitFor(function() { return hasCall("activate beta manual " + revisionB) }, "service did not capture its revision at request time")
    check(service.endRoutine("alpha"), "explicit End was rejected")
    waitFor(function() { return !service.routineBusy("alpha") }, "end request did not settle")
    waitFor(function() { return hasCall("deactivate alpha manual") }, "safe End was coupled to a config revision")
  }
  QtObject {
    id: panelService
    property bool manualRevisionBinding: true
    property bool enabled: true
    property bool manualBusy: false
    property bool connectionBusy: false
    property var active: ({})
    property string configRevision: root.revisionB
    property var requests: []
    signal manualFinished(var job, var result)
    function testRoutine(id, revision) { requests = requests.concat([{op:"run",id:id,revision:revision}]); return true }
    function endRoutine(id) { requests = requests.concat([{op:"deactivate",id:id}]); return true }
  }
  function testPanel() {
    var component = Qt.createComponent("Panel.qml")
    check(component.status === Component.Ready, component.errorString())
    panel = component.createObject(root, {service:panelService})
    panel.refreshAll()
    waitFor(function() { return panel.configLoaded && panel.editorPersisted }, "panel did not load fixture config")
    panel.runRoutine("alpha", null)
    check(panelService.requests.length === 0, "Panel replaced a malformed supplied revision")
    panel.runRoutine("alpha")
    check(panelService.requests.length === 1 && panelService.requests[0].revision === revisionA,
      "Panel Run did not pass its displayed revision independently of Service refresh")
    var changed = JSON.parse(JSON.stringify(panel.config))
    changed.routines[0].actions = [{type:"exec",program:"unseen-change",args:[]}]
    panel.revisionRefreshPending = true
    panel.revisionRefreshPurpose = "apply"
    panel.handleRevisionResult(JSON.stringify({ok:true,committed:true,config:changed,revision:revisionB}), "", 0)
    check(panel.configRevision === revisionB && panel.editorRevision === revisionA,
      "revision refresh rebound a retained editor to unshown content")
    panel.runRoutine("alpha")
    check(panelService.requests[1].revision === revisionA, "retained editor started a newer definition")
    panel.selectRoutineNow("alpha", true)
    panel.runRoutine("alpha")
    check(panelService.requests[2].revision === revisionB, "explicit fresh selection did not adopt its revision")
    var saved = JSON.parse(JSON.stringify(panel.routineById("alpha")))
    saved.actions = [{type:"delay",milliseconds:0}]
    panel.saveAndRun(saved)
    waitFor(function() { return panelService.requests.length === 4 }, "Save & Run did not dispatch after apply")
    check(panelService.requests[3].revision === revisionC && panel.editorRevision === revisionC,
      "Save & Run did not bind the exact apply result revision")
    panel.activeIds = {alpha:{routineId:"alpha"}}
    panel.endRoutine("alpha")
    check(panelService.requests[4].op === "deactivate" && panelService.requests[4].revision === undefined,
      "explicit End was bound to stale config instead of recovery")
    // A cached old service must not ignore the new argument and start latest.
    panelService.manualRevisionBinding = false
    panel.activeIds = ({})
    panel.runRoutine("alpha")
    check(panel.routineActionBlocked("beta"), "direct fallback allowed another ID to overwrite its running process")
    waitFor(function() { return panel.runningRoutineId === "" }, "legacy-service fallback did not finish")
    check(panelService.requests.length === 5, "old service ignored the revision argument")
    waitFor(function() { return hasCall("run alpha test " + revisionC) }, "direct fallback omitted the reviewed revision")
  }
  Timer {
    interval: 20; running: true; repeat: false
    onTriggered: {
      try { root.testService(); root.testPanel(); console.log("OMACHORD_QML_TEST_PASS") }
      catch (error) { console.error("OMACHORD_QML_TEST_FAIL", String(error)) }
    }
  }
}
