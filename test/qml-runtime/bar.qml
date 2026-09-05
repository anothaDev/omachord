import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: root
  property int step: 0
  property int panelRequests: 0

  QtObject {
    id: service
    property var activeList: []
    property bool manualBusy: false
    property bool enabled: true
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
    property string position: vertical ? "left" : "top"
    property var activePopout: null
    function hideTooltip(item) {}
    function showTooltip(item, text) {}
    function requestPopout(item) { activePopout = item }
    function releasePopout(item) { activePopout = null }
  }

  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 420
    implicitHeight: 280
    color: host.background

    BarWidget {
      id: widget
      bar: host
      settings: ({ alwaysShow: true })
    }
    RoutinePopup {
      id: popup
      foreground: "#333333"
      x: 16
      y: 80
      width: 388
    }
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

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  function checkIcon(container, foreground) {
    var icon = find(container, function(item) { return item instanceof BrandIcon })
    check(!!icon, "branded Image missing")
    check(icon.status === Image.Ready, "SVG failed to load: " + icon.source)
    check(Qt.colorEqual(icon.foreground, foreground), "icon does not follow its theme foreground")
    check(String(icon.artworkSource).endsWith(icon.lightForeground ? "omachord-white.svg" : "omachord-black.svg"), "wrong artwork")
    var svg = decodeURIComponent(String(icon.source).split(",").slice(1).join(","))
    check(svg.indexOf('stroke="' + icon.strokeColor + '"') !== -1, "SVG stroke is not theme-colored")
    check(svg.indexOf('viewBox="0 0 24 24" fill="none"') !== -1, "icon is not the transparent mark")
    check(svg.indexOf('width="64"') === -1, "icon contains a background tile")
    check(icon.width > 0 && icon.width === icon.height, "icon must be square and visible")
    check(icon.sourceSize.width === Math.ceil(icon.width * window.screen.devicePixelRatio), "wrong HiDPI decode size")
    return icon
  }

  Timer {
    interval: 300
    running: true
    repeat: true
    onTriggered: {
      try {
        var button = root.find(widget, function(item) { return item.objectName === "omachordBarButton" })
        root.check(!!button && button.text === "", "bar still needs a font glyph")
        if (root.step < 4) root.check(button.visible, "bar button is hidden at step " + root.step)
        if (root.step === 0) {
          // Foreground overrides must win over the opposite base theme.
          Color.background = "#ffffff"
          Color.shellValues = { "popups.background": "#f4f2f7" }
        } else if (root.step === 1) {
          var icon = root.checkIcon(widget, host.barForeground)
          root.checkIcon(popup, popup.foreground)
          root.check(icon.width === button.opticalSize, "icon escaped the bar optical canvas")
          root.check(icon.width === Style.bar.iconCanvas, "mark should use the normal bar icon size")
          root.check(button.dimmed && widget.shown, "idle alwaysShow behavior changed")
          host.background = "#f4f2f7"
          host.barForeground = "#1a1720"
          popup.foreground = "#c4b5fd"
          Color.background = "#000000"
          Color.shellValues = { "popups.background": "#14111c" }
        } else if (root.step === 2) {
          root.checkIcon(widget, host.barForeground)
          root.checkIcon(popup, popup.foreground)
          button.triggerPress(Qt.LeftButton)
          root.check(widget.opened, "left click did not open the popup")
          button.triggerPress(Qt.RightButton)
          root.check(!widget.opened, "right click did not close the popup")
          button.triggerPress(Qt.MiddleButton)
          root.check(root.panelRequests === 1, "middle click did not open Omachord")
          host.vertical = true
          host.background = "transparent"
          host.barForeground = "#d3bf9e"
          service.activeList = [{ id: "focus", name: "Focus" }]
          widget.settings = { alwaysShow: false }
        } else if (root.step === 3) {
          root.checkIcon(widget, host.barForeground)
          root.check(widget.shown && !button.dimmed, "active routine indicator changed")
          root.check(widget.width === host.barSize && widget.height > 0, "vertical layout is broken")
          service.activeList = []
        } else {
          root.check(!widget.shown && widget.implicitHeight === 0, "idle widget no longer collapses")
          console.log("OMACHORD_BAR_TEST_PASS")
          Qt.quit()
        }
        root.step++
      } catch (error) {
        console.error("OMACHORD_BAR_TEST_FAIL", error.message)
        Qt.quit()
      }
    }
  }
}
