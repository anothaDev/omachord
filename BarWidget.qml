import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Omachord in the bar: a small indicator that appears while a routine is
// on, with a popup that names each one and can end it. State comes from
// the plugin's own service (Service.qml); every request goes back through
// it, so the runner stays the single executor.
Panel {
  id: root
  moduleName: "anothadev.omachord"
  manageIpc: false

  readonly property string pluginId: "anothadev.omachord"
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(pluginId) : null
  readonly property var activeList: service && service.activeList ? service.activeList : []
  readonly property int activeCount: activeList.length
  readonly property bool hasActive: activeCount > 0
  readonly property bool busy: !!service && service.manualBusy === true
  readonly property bool integrationBusy: !!service && (service.connectionBusy !== undefined
    ? service.connectionBusy === true : service.manualBusy === true)
  readonly property bool integrationOn: !!service && (service.connectionStatus
    ? service.connectionStatus.integrationComplete === true : service.enabled === true)
  readonly property bool alwaysShow: setting("alwaysShow", false) === true
  readonly property bool showName: setting("showName", false) === true
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color panelForeground: bar ? bar.foreground : Color.foreground
  readonly property string leadName: hasActive ? String(activeList[0].name || activeList[0].id) : ""
  readonly property string summary: !service ? "Omachord service is not running"
    : (!hasActive ? (integrationOn ? "Omachord: nothing on" : "Omachord is off")
      : (activeCount === 1 ? leadName + " is on" : activeCount + " routines on"))
  readonly property bool shown: hasActive || alwaysShow
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool cursorOnFooter: false

  ThemePalette { id: palette }

  function endRoutine(id) {
    if (integrationBusy || routineBusy(id) || !service || typeof service.endRoutine !== "function") return
    service.endRoutine(id)
  }

  function routineBusy(id) {
    if (!service) return false
    if (typeof service.routineBusy === "function") return service.routineBusy(id)
    return service.manualBusy === true
  }

  function endSelected() {
    if (!cursorActive) return
    if (cursorOnFooter) { openOmachord(); return }
    if (selectedIndex < 0 || selectedIndex >= activeList.length) return
    endRoutine(activeList[selectedIndex].id)
  }

  function openOmachord() {
    close()
    if (service && typeof service.openPanel === "function" && service.openPanel("routines")) return
    if (bar && bar.shell && typeof bar.shell.summon === "function") bar.shell.summon(pluginId, "{}")
  }

  function toggleIntegration() {
    if (!service || integrationBusy) return
    if (integrationOn && typeof service.requestDisconnect === "function") service.requestDisconnect()
    else if (!integrationOn && typeof service.requestConnect === "function") service.requestConnect()
  }

  function moveCursor(delta) {
    var last = activeList.length // the footer button is the virtual last row
    var position = cursorOnFooter ? last : selectedIndex
    position = Math.max(0, Math.min(last, position + delta))
    cursorOnFooter = position === last
    if (!cursorOnFooter) selectedIndex = position
  }

  function clampCursor() {
    if (selectedIndex >= activeList.length) {
      selectedIndex = Math.max(0, activeList.length - 1)
      if (activeList.length === 0) cursorOnFooter = true
    }
  }

  onActiveListChanged: clampCursor()
  onOpenedChanged: {
    if (opened) {
      selectedIndex = 0
      cursorOnFooter = activeList.length === 0
      cursorActive = false
      palette.reload()
    }
  }

  visible: shown || implicitWidth > 0.5
  implicitWidth: shown ? (vertical ? barSize : barRow.implicitWidth) : 0
  implicitHeight: shown ? (vertical ? barRow.implicitHeight : barSize) : 0
  clip: true
  Behavior on implicitWidth { enabled: !root.vertical; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
  Behavior on implicitHeight { enabled: root.vertical; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: 0

    BarIconButton {
      id: button
      objectName: "omachordBarButton"
      bar: root.bar
      iconComponent: Component {
        BrandIcon {
          foreground: button.foreground
        }
      }
      dimmed: !root.hasActive
      useActiveColor: false
      tooltipText: root.summary
      onPressed: function(mouseButton) {
        if (mouseButton === Qt.MiddleButton) root.openOmachord()
        else root.toggle()
      }
    }

    Item {
      id: nameSlot
      visible: root.showName && root.hasActive && !root.vertical
      width: visible ? Math.min(Style.space(160), nameText.implicitWidth) + Style.space(8) : 0
      height: root.barSize
      clip: true

      Text {
        textFormat: Text.PlainText
        id: nameText
        anchors.verticalCenter: parent.verticalCenter
        text: root.activeCount === 1 ? root.leadName : root.leadName + " +" + (root.activeCount - 1)
        color: bar ? bar.barForeground : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: Math.min(Style.space(160), implicitWidth)

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: function(mouse) {
          if (mouse.button === Qt.MiddleButton) root.openOmachord()
          else root.toggle()
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.endSelected()
      onDeleteRequested: if (root.cursorActive && !root.cursorOnFooter) root.endSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "o" || t === "O") root.openOmachord() }

      RoutinePopup {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        foreground: root.panelForeground
        accent: Color.accent
        urgent: root.bar ? root.bar.urgent : Color.urgent
        success: palette.success
        fontFamily: root.fontFamily
        rows: root.activeList
        busy: root.busy
        pendingIds: root.service && root.service.routinePendingIds !== undefined
          ? root.service.routinePendingIds
          : (root.service && root.service.manualPendingIds !== undefined
            ? root.service.manualPendingIds : null)
        serviceAvailable: !!root.service
        integrationOn: root.integrationOn
        integrationBusy: root.integrationBusy
        keyboardFocusTarget: keyCatcher
        summary: root.summary
        cursorIndex: root.cursorActive ? root.selectedIndex : -1
        cursorOnFooter: root.cursorActive && root.cursorOnFooter
        onEndRequested: function(id) { root.endRoutine(id) }
        onOpenRequested: root.openOmachord()
        onIntegrationToggled: root.toggleIntegration()
        onRowHovered: function(index) {
          if (index < 0) return
          root.cursorActive = true
          root.cursorOnFooter = false
          root.selectedIndex = index
        }
      }
    }
  }
}
