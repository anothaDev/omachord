import QtQuick
import QtTest
import Quickshell
import qs.Commons

// Keep the real BarWidget, popup and PanelKeyCatcher. Only the layer-shell
// window is replaced by the offscreen KeyboardPanel fixture.
ShellRoot {
  id: root
  property int connectRequests: 0
  property int disconnectRequests: 0
  property int endRequests: 0
  property int panelRequests: 0

  QtObject {
    id: service
    property var activeList: []
    property bool manualBusy: connectionBusy
    property bool connectionBusy: false
    property bool enabled: false
    property var connectionStatus: ({ integrationComplete: false })
    function requestConnect() { root.connectRequests++; connectionBusy = true; return true }
    function requestDisconnect() { root.disconnectRequests++; connectionBusy = true; return true }
    function endRoutine(id) { root.endRequests++; return true }
    function openPanel(view) { root.panelRequests++; return true }
  }

  QtObject {
    id: host
    property QtObject shell: QtObject {
      function serviceFor(id) { return service }
    }
    property bool vertical: false
    property int barSize: Style.bar.sizeHorizontal
    property string fontFamily: Style.font.family
    property color background: "#14111c"
    property color foreground: "#eeeeee"
    property color barForeground: foreground
    property color urgent: "#ff5555"
    property bool foregroundAnimationEnabled: false
    property string position: "top"
    property var activePopout: null
    function hideTooltip(item) {}
    function showTooltip(item, text) {}
    function requestPopout(item) { activePopout = item }
    function releasePopout(item) { activePopout = null }
  }

  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 440
    implicitHeight: 360
    color: host.background
    BarWidget {
      id: widget
      width: window.width
      height: window.height
      bar: host
      settings: ({ alwaysShow: true })
    }
    TestCase { id: input; name: "Bar keyboard cursor"; when: false }
  }

  function find(item, predicate) {
    if (predicate(item)) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = find(children[i], predicate)
      if (found) return found
    }
    return null
  }

  function check(condition, detail) { if (!condition) throw new Error(detail) }

  Timer {
    interval: 300
    running: true
    onTriggered: {
      try {
        widget.open()
        var panel = root.find(widget, function(item) { return item.focusTarget !== undefined })
        root.check(!!panel, "offscreen keyboard panel was not found")
        panel.width = panel.contentWidth
        panel.height = 300
        var catcher = panel.focusTarget
        var toggle = root.find(panel, function(item) { return item.objectName === "popupIntegrationSwitch" })
        root.check(!!toggle, "popup switch was not found")
        catcher.forceActiveFocus()
        input.wait(50)

        input.mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        root.check(root.connectRequests === 1 && toggle.busy, "mouse did not start the connection: requests="
          + root.connectRequests + " size=" + toggle.width + "x" + toggle.height
          + " position=" + toggle.mapToItem(window.contentItem, 0, 0) + " interactive=" + toggle.interactive)
        root.check(catcher.activeFocus, "switch click must preserve the popup's keyboard dispatcher")
        service.enabled = true
        service.connectionStatus = { integrationComplete: true }
        service.connectionBusy = false
        service.activeList = [{ id: "alpha", name: "Alpha", activatedAt: "2026-09-01T09:00:00Z" }]
        input.wait(30)
        input.keyClick(Qt.Key_Down)
        input.keyClick(Qt.Key_Up)
        input.keyClick(Qt.Key_Return)
        root.check(root.endRequests === 1,
          "switch focus stole Enter from the highlighted routine after a connection")
        root.check(root.disconnectRequests === 0, "keyboard cursor unexpectedly toggled integration")

        // Even a denied click during busy must not steal subsequent keyboard
        // activation from the popup's virtual cursor.
        service.activeList = []
        service.connectionBusy = true
        input.mouseClick(toggle, toggle.width / 2, toggle.height / 2)
        root.check(catcher.activeFocus, "busy switch click must preserve the popup's keyboard dispatcher")
        service.connectionBusy = false
        input.keyClick(Qt.Key_Down)
        input.keyClick(Qt.Key_Space)
        root.check(root.panelRequests === 1 && root.disconnectRequests === 0,
          "busy switch click stole Space from the highlighted Open Omachord footer")

        service.enabled = false
        root.check(widget.integrationOn && toggle.checked,
          "an unavailable condition-engine probe must not flip the confirmed UI connection state")
        console.log("OMACHORD_BAR_TEST_PASS keyboard cursor and confirmed connection state")
      } catch (error) {
        console.error("OMACHORD_BAR_TEST_FAIL", String(error))
      }
      Qt.quit()
    }
  }
}
