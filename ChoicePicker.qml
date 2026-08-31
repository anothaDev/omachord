import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Window
import qs.Commons
import qs.Ui

Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []
  property string placeholderText: "Select..."
  property bool showLabel: true
  property bool searchable: false
  property bool hasCursor: false
  property color foreground: Color.popups.text
  property color background: Color.popups.background
  property color popupBorder: Color.popups.border
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  readonly property bool popupOpen: popup.opened
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec(
    "popups", "border", popupBorder, Color.popups.border, Style.normalBorderWidth)

  property var filteredOptions: options

  signal changed(string value)
  signal hovered(bool isHovered)

  implicitWidth: Style.spacing.dropdownWidth
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  function optionValue(option) {
    return option && typeof option === "object" ? String(option.value) : String(option)
  }

  function optionLabel(option) {
    return option && typeof option === "object" ? String(option.label) : String(option)
  }

  function optionDescription(option) {
    return option && typeof option === "object" && option.description
      ? String(option.description) : ""
  }

  function currentLabel() {
    for (var i = 0; i < options.length; i++)
      if (optionValue(options[i]) === value) return optionLabel(options[i])
    return value
  }

  function recomputeFiltered() {
    if (!searchable || !searchField.text) {
      filteredOptions = options
    } else {
      var query = searchField.text.toLowerCase()
      var rows = []
      for (var i = 0; i < options.length; i++) {
        var option = options[i]
        if (optionLabel(option).toLowerCase().indexOf(query) !== -1
            || optionDescription(option).toLowerCase().indexOf(query) !== -1)
          rows.push(option)
      }
      filteredOptions = rows
    }
    if (popup.opened) Qt.callLater(function() { popup.reposition() })
  }

  function open() { popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }

  onOptionsChanged: recomputeFiltered()
  onVisibleChanged: if (!visible && popup.opened) popup.close()

  Timer {
    interval: 32
    repeat: true
    running: popup.opened
    onTriggered: popup.reposition()
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.labelGap

    Text {

      textFormat: Text.PlainText
      visible: root.showLabel && root.label !== ""
      text: root.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    BorderSurface {
      id: trigger
      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius
      activeFocusOnTab: true
      Accessible.role: Accessible.ComboBox
      Accessible.name: root.label || root.placeholderText
      Accessible.description: root.currentLabel()

      readonly property bool focused: activeFocus
      readonly property bool hot: triggerHover.hovered || root.hasCursor

      color: Style.controlFill(focused, hot, root.foreground, root.accent)
      borderSpec: Border.controlSpec(focused ? "focus" : (hot ? "hover-cursor" : "normal"),
        root.foreground, root.accent)

      HoverHandler {
        id: triggerHover
        onHoveredChanged: root.hovered(hovered)
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
          root.toggle()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape && popup.opened) {
          popup.close()
          event.accepted = true
        }
      }

      Text {

        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.md
        text: root.currentLabel() || root.placeholderText
        color: root.currentLabel() ? root.foreground : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {

        textFormat: Text.PlainText
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        text: "v"
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          trigger.forceActiveFocus()
          root.toggle()
        }
      }
    }
  }

  QQC.Popup {
    id: popup
    parent: trigger.Window.window ? trigger.Window.window.contentItem : trigger
    property real anchorX: 0
    property real anchorY: 0
    property real fittedHeight: 0
    property bool below: true

    function desiredHeight() {
      var rows = Math.max(1, Math.min(8, root.filteredOptions.length))
      return rows * root.popupRowHeight
        + Math.max(0, rows - 1) * Style.spacing.labelGap
        + (root.searchable ? root.popupRowHeight + Style.spacing.md + 1 : 0)
        + Style.spacing.xxs
    }

    function reposition() {
      if (!parent) return
      var top = trigger.mapToItem(parent, 0, 0)
      var bottom = trigger.mapToItem(parent, 0, trigger.height + Style.spacing.xxs)
      var margin = Style.space(12)
      var availableBelow = Math.max(0, parent.height - bottom.y - margin)
      var availableAbove = Math.max(0, top.y - margin)
      var desired = desiredHeight()
      below = availableBelow >= Math.min(desired, Style.space(180)) || availableBelow >= availableAbove
      fittedHeight = Math.min(desired, below ? availableBelow : availableAbove)
      var requestedWidth = Math.min(trigger.width, Math.max(0, parent.width - margin * 2))
      anchorX = Math.max(margin, Math.min(top.x, parent.width - requestedWidth - margin))
      anchorY = below ? bottom.y : Math.max(margin, top.y - fittedHeight - Style.spacing.xxs)
    }

    x: anchorX
    y: anchorY
    width: parent ? Math.min(trigger.width, Math.max(0, parent.width - Style.space(24))) : trigger.width
    implicitHeight: fittedHeight
    padding: Style.spacing.hairline
    leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
    rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
    topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
    bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside

    background: BorderSurface {
      color: root.background
      borderSpec: root.popupBorderSpec
      radius: Style.cornerRadius
    }

    onOpened: {
      searchField.text = ""
      root.recomputeFiltered()
      reposition()
      if (root.searchable) Qt.callLater(function() { searchField.forceActiveFocus() })
      else {
        optionList.currentIndex = Math.max(0, optionList.indexOfValue(root.value))
        Qt.callLater(function() { optionList.forceActiveFocus() })
      }
    }
    onClosed: searchField.text = ""

    Connections {
      target: trigger
      function onXChanged() { if (popup.opened) popup.reposition() }
      function onYChanged() { if (popup.opened) popup.reposition() }
      function onWidthChanged() { if (popup.opened) popup.reposition() }
      function onHeightChanged() { if (popup.opened) popup.reposition() }
    }

    contentItem: Column {
      Item {
        id: searchHeader
        visible: root.searchable
        width: parent.width
        height: visible ? root.popupRowHeight + Style.spacing.md : 0

        TextField {
          id: searchField
          anchors.fill: parent
          anchors.margins: Style.spacing.md
          placeholderText: root.placeholderText
          onTextChanged: {
            root.recomputeFiltered()
            optionList.currentIndex = optionList.count ? 0 : -1
          }
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              popup.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Down && optionList.count) {
              optionList.currentIndex = 0
              optionList.forceActiveFocus()
              event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && optionList.count) {
              optionList.currentIndex = 0
              optionList.selectCurrent()
              event.accepted = true
            }
          }
        }
      }

      Rectangle {
        visible: root.searchable
        width: parent.width
        height: visible ? 1 : 0
        color: Util.alpha(root.foreground, 0.1)
      }

      ListView {
        id: optionList
        width: parent.width
        height: Math.max(0, popup.availableHeight - searchHeader.height - (root.searchable ? 1 : 0))
        spacing: Style.spacing.labelGap
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.filteredOptions
        currentIndex: -1
        keyNavigationEnabled: false

        function indexOfValue(candidate) {
          for (var i = 0; i < root.filteredOptions.length; i++)
            if (root.optionValue(root.filteredOptions[i]) === candidate) return i
          return -1
        }

        function selectCurrent() {
          if (currentIndex < 0 || currentIndex >= root.filteredOptions.length) return
          var selected = root.optionValue(root.filteredOptions[currentIndex])
          if (selected !== root.value) {
            root.value = selected
            root.changed(selected)
          }
          popup.close()
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            popup.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.text === "j") {
            currentIndex = Math.min(count - 1, currentIndex + 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.text === "k") {
            if (root.searchable && currentIndex <= 0) searchField.forceActiveFocus()
            else currentIndex = Math.max(0, currentIndex - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            selectCurrent()
            event.accepted = true
          }
        }

        delegate: Rectangle {
          required property var modelData
          required property int index
          width: optionList.width
          height: root.popupRowHeight
          color: index === optionList.currentIndex
            ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

          Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.optionLabel(modelData)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
            Text {
              textFormat: Text.PlainText
              visible: root.optionDescription(modelData) !== ""
              width: parent.width
              text: root.optionDescription(modelData)
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: optionList.currentIndex = parent.index
            onPressed: optionList.currentIndex = parent.index
            onClicked: {
              optionList.currentIndex = parent.index
              optionList.selectCurrent()
            }
          }
        }
      }
    }
  }
}
