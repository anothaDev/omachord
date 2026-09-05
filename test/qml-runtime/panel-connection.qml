import QtQuick
import QtTest
import Quickshell

ShellRoot {
  id: root
  property var panel: null
  property var legacyPanel: null

  TestCase { id: input; name: "PanelConnection"; when: false }

  QtObject {
    id: legacyService
    property bool enabled: true
    property bool manualBusy: false
    property var active: ({})
    signal manualFinished(var job, var result)
  }

  QtObject {
    id: service
    property bool enabled: false
    property bool connectionBusy: false
    property var connectionStatus: ({ ok: true, connected: false, ownedConnection: false,
      integrationComplete: false, connectionEnabled: false })
    property var active: ({})
    property string configRevision: ""
    property int connectRequests: 0
    property int disconnectRequests: 0
    property string requestedRevision: ""
    signal manualFinished(var job, var result)

    function requestConnect(revision) {
      connectRequests++
      requestedRevision = revision
      connectionBusy = true
      return true
    }

    function requestDisconnect() {
      disconnectRequests++
      connectionBusy = true
      return true
    }

    function finish(op, ok) {
      if (ok) {
        enabled = op === "connect"
        connectionStatus = { ok: true, connected: enabled, ownedConnection: enabled,
          integrationComplete: enabled, connectionEnabled: enabled }
      }
      connectionBusy = false
      manualFinished({ op: op, id: "" }, ok
        ? { ok: true, connected: enabled, revision: "sha256:connected" }
        : { ok: false, error: "Fixture connection failure" })
    }
  }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  function waitFor(predicate, message) {
    var until = Date.now() + 3000
    while (!predicate() && Date.now() < until) input.wait(20)
    check(predicate(), message)
  }

  function findWindow(item) {
    for (var child of item.data)
      if (child && child.contentItem !== undefined && child.title !== undefined) return child
    return null
  }

  function find(item, predicate) {
    if (predicate(item)) return item
    for (var child of item.children || []) {
      var result = find(child, predicate)
      if (result) return result
    }
    return null
  }

  function testSaveGuard() {
    panel.config = { version: 1, routines: [
      { id: "alpha", name: "Alpha", enabled: true, triggers: [], actions: [{ type: "dnd", value: true, restore: true }] },
      { id: "beta", name: "Beta", enabled: true, triggers: [], actions: [{ type: "dnd", value: true, restore: true }] }
    ] }
    panel.ensureRoutineSelection()
    var window = findWindow(panel)
    check(!!window, "panel window is missing")
    window.visible = true
    input.wait(100)
    var editor = find(window.contentItem, function(item) { return item.draft !== undefined && typeof item.save === "function" })
    check(!!editor, "routine editor is missing")
    editor.updateField("enabled", false)
    service.requestDisconnect()
    check(editor.busy && editor.operationPending, "bar connection must make the editor unavailable")
    window.contentItem.children[0].forceActiveFocus()
    input.keyClick(Qt.Key_S, Qt.ControlModifier)
    check(!panel.mutating, "Ctrl+S must not save while a service connection is pending")
    panel.saveRoutine(editor.draft)
    check(!panel.mutating, "the apply boundary must reject saves while a service connection is pending")
    service.finish("disconnect", false)
    input.keyClick(Qt.Key_S, Qt.ControlModifier)
    waitFor(function() { return !panel.mutating && panel.configRevision === "sha256:applied" },
      "Ctrl+S must resume saving after the service connection settles")

    // Public UI requests reject a duplicate row without blocking other rows
    // from joining the same serialized enable batch.
    panel.requestSetRoutineEnabled("alpha", true)
    panel.requestSetRoutineEnabled("alpha", false)
    panel.requestSetRoutineEnabled("beta", false)
    check(panel.routineById("alpha").enabled && !panel.routineById("beta").enabled,
      "same-row repeat must be ignored while an unrelated enable request joins")
    waitFor(function() { return !panel.mutating }, "enable requests did not settle")
    check(panel.routineById("alpha").enabled && !panel.routineById("beta").enabled,
      "joined enable requests did not retain their requested values")

    service.enabled = false
    check(panel.integrationOn, "fail-closed scheduling must not erase the last confirmed UI connection")
  }

  Timer {
    id: legacyTest
    interval: 20
    onTriggered: {
      try {
        var component = Qt.createComponent("Panel.qml")
        root.legacyPanel = component.createObject(root, { service: legacyService })
        root.legacyPanel.status = { ok: true, connected: true, ownedConnection: true,
          integrationComplete: true, connectionEnabled: true }
        legacyService.manualBusy = true
        legacyService.enabled = false
        legacyService.manualBusy = false
        legacyService.manualFinished({ op: "disconnect", id: "" }, { ok: true, connected: false })
        root.waitFor(function() { return !root.legacyPanel.integrationOn },
          "legacy manualBusy completion must drain the deferred status refresh")
        root.testSaveGuard()
        console.log("OMACHORD_QML_TEST_PASS")
      } catch (error) {
        console.error("OMACHORD_QML_TEST_FAIL", String(error))
      }
      Qt.quit()
    }
  }

  Component.onCompleted: {
    try {
      var component = Qt.createComponent("Panel.qml")
      check(component.status === Component.Ready, component.errorString())
      panel = component.createObject(root, { service: service })
      check(!!panel, "could not create panel")
      panel.configLoaded = true
      panel.loading = false
      panel.configRevision = "sha256:base"

      panel.requestIntegrationToggle()
      check(service.connectRequests === 1, "panel must use the shared service connection queue")
      check(service.requestedRevision === "sha256:base", "connect must retain revision checking")
      check(panel.integrationBusy === true, "panel switch must remain pending while connecting")
      panel.requestIntegrationToggle()
      check(service.connectRequests === 1, "pending connection must ignore repeat activation")

      service.finish("connect", true)
      check(panel.integrationOn && !panel.integrationBusy && !panel.mutating,
        "completed connection must display its committed state before unlocking")
      check(panel.configRevision === "sha256:connected", "connection revision must be retained")

      service.requestDisconnect()
      check(panel.integrationBusy, "a connection started in the bar must also block the panel")
      panel.mutateConnection("disconnect")
      check(service.disconnectRequests === 1, "panel must not duplicate a bar connection request")
      service.finish("disconnect", false)
      check(panel.integrationOn && !panel.integrationBusy && panel.noticeError,
        "failed connection must unlock without flipping the confirmed state")
      legacyTest.start()
    } catch (error) {
      console.error("OMACHORD_QML_TEST_FAIL", String(error))
    }
  }
}
