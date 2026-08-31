import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: root

  property var routine: null
  property var bindings: []
  property var appOptions: []
  property var commandOptions: []
  property var themeOptions: []
  property var wifiOptions: []
  property var toggleOptions: []
  property var targetWindow: null
  property bool busy: false
  property bool persisted: true
  property bool showBack: false
  property bool isActive: false
  property string externalError: ""

  property var draft: null
  property string localError: ""
  property var argumentErrors: ({})
  property var argumentTexts: ({})
  property bool dirty: false
  readonly property string argumentError: {
    var keys = Object.keys(argumentErrors || {})
    return keys.length ? String(argumentErrors[keys[0]]) : ""
  }
  property string pendingChord: ""
  property string conflictDescription: ""
  property string addActionType: "notification"
  property string addEndActionType: "notification"
  property string addConditionType: "time"
  readonly property bool stateful: !!draft && Model.isStateful(draft)
  readonly property bool showsLifecycle: !!draft && (stateful || Model.hasConditions(draft))

  readonly property var actionTypeOptions: [
    { value: "nightlight", label: "Night light" },
    { value: "dnd", label: "Do not disturb" },
    { value: "stay-awake", label: "Stay awake" },
    { value: "theme", label: "Theme" },
    { value: "brightness", label: "Display brightness" },
    { value: "microphone-toggle", label: "Microphone toggle" },
    { value: "launch-app", label: "Launch application" },
    { value: "omarchy-command", label: "Omarchy command" },
    { value: "notification", label: "Notification" },
    { value: "osd", label: "On-screen display" },
    { value: "sound", label: "Play sound" },
    { value: "delay", label: "Delay" },
    { value: "exec", label: "Program + arguments" },
    { value: "shell", label: "Shell command (advanced)" }
  ]
  readonly property var hookOptions: [
    { value: "battery-low", label: "Battery low", description: "Battery percentage is argument 1" },
    { value: "font-set", label: "Font changed", description: "Font name is argument 1" },
    { value: "post-boot", label: "After desktop starts", description: "Runs after the graphical session starts" },
    { value: "post-update", label: "After update", description: "Runs after packages and migrations" },
    { value: "pre-refresh-pacman", label: "Before Pacman refresh", description: "Runs before repositories are refreshed" },
    { value: "theme-set", label: "Theme changed", description: "Theme slug is argument 1" }
  ]
  readonly property var conditionTypeOptions: [
    { value: "time", label: "Time period", description: "Between two times of day, optionally on chosen weekdays" },
    { value: "wifi", label: "Wi-Fi network", description: "Connected to one of the listed networks" },
    { value: "power", label: "Power source", description: "Plugged in, on battery, or below a battery level" },
    { value: "omarchy-toggle", label: "Omarchy toggle", description: "An Omarchy toggle flag is on" }
  ]
  readonly property var weekdayOptions: [
    { value: "mon", label: "Mon" }, { value: "tue", label: "Tue" }, { value: "wed", label: "Wed" },
    { value: "thu", label: "Thu" }, { value: "fri", label: "Fri" }, { value: "sat", label: "Sat" },
    { value: "sun", label: "Sun" }
  ]
  readonly property var powerSourceOptions: [
    { value: "battery", label: "On battery" },
    { value: "ac", label: "Plugged in" }
  ]
  readonly property var endModeOptions: [
    { value: "restore", label: "Return to the state before the routine ran", description: "Setters marked to restore are reverted" },
    { value: "actions", label: "Restore, then run end actions", description: "Revert setters and then run a separate action list" },
    { value: "none", label: "Leave everything as it is", description: "Nothing is reverted when the routine ends" }
  ]
  readonly property var keepUntilOptions: [
    { value: "conditions", label: "Conditions stop matching", description: "Or until you toggle the routine off" },
    { value: "minutes", label: "A fixed number of minutes", description: "Ends automatically after the given time" }
  ]

  signal saveRequested(var routine)
  signal deleteRequested(string id)
  signal duplicateRequested(string id)
  signal runRequested(string id)
  signal backRequested()

  onRoutineChanged: resetDraft()
  onBindingsChanged: clearResolvedBindingError()
  onPersistedChanged: if (draft && !persisted) dirty = true
  enabled: !busy

  function resetDraft() {
    draft = routine ? Model.normalizeRoutine(routine) : null
    nameField.text = draft ? draft.name : ""
    localError = ""
    externalError = ""
    pendingChord = ""
    conflictDescription = ""
    argumentErrors = ({})
    argumentTexts = ({})
    dirty = !!draft && !persisted
    hookSelect.values = draft ? Model.hookValues(draft) : []
  }

  function assignDraft(next, markDirty) {
    draft = Model.normalizeRoutine(next)
    if (markDirty === undefined || markDirty) dirty = true
  }

  function stopShortcutCapture() { shortcutRecorder.stopRecording() }

  function clearResolvedBindingError() {
    if (!draft || externalError.indexOf("already assigned to") === -1) return
    var shortcut = Model.shortcutTrigger(draft)
    if (!shortcut || !Model.conflictFor(bindings, shortcut.keys)) externalError = ""
  }

  function displayedError() {
    return String(localError || argumentError || externalError || "")
      .replace(/\bOma: /g, "Omachord: ")
      .replace(/\bOma Chord\b/g, "Omachord")
  }

  function proposeShortcut(keys, description) {
    pendingChord = keys
    conflictDescription = description
  }

  function updateField(key, value) {
    if (!draft) return
    var next = Model.clone(draft)
    next[key] = value
    assignDraft(next)
  }

  // The main action list uses plain numeric keys; the end-of-routine list is
  // prefixed so staged argument text never collides between the two lists.
  function argumentKey(list, index) {
    return (list === "end" ? "end:" : "") + String(index)
  }

  function actionList(list) {
    if (!draft) return []
    return list === "end" ? draft.onEnd.actions : draft.actions
  }

  function updateAction(index, key, value, list) {
    var actions = actionList(list)
    if (!draft || index < 0 || index >= actions.length) return
    var next = Model.clone(draft)
    var target = list === "end" ? next.onEnd.actions : next.actions
    target[index][key] = value
    if (list === "end" && Model.isSetterAction(target[index])) target[index].restore = false
    assignDraft(next)
  }

  function stageActionText(index, key, value, list) {
    var actions = actionList(list)
    if (!draft || index < 0 || index >= actions.length) return
    actions[index][key] = value
    dirty = true
  }

  function stageRoutineName(value) {
    if (!draft) return
    draft.name = value
    dirty = true
  }

  function replaceAction(index, type, list) {
    if (!draft) return
    var isEnd = list === "end"
    if (!isEnd) {
      if (index < 0 || index >= draft.actions.length) return
      if (draft.actions[index].type === type) return
    } else {
      if (index < 0 || index >= draft.onEnd.actions.length) return
      if (draft.onEnd.actions[index].type === type) return
    }
    var next = Model.clone(draft)
    var replacement = Model.defaultAction(type)
    if (isEnd && Model.isSetterAction(replacement)) replacement.restore = false
    if (isEnd) next.onEnd.actions[index] = replacement
    else next.actions[index] = replacement
    argumentErrors = argumentStateWithoutIndex(argumentErrors, index, list)
    argumentTexts = argumentStateWithoutIndex(argumentTexts, index, list)
    assignDraft(next)
  }

  function addAction(list) {
    if (!draft) return
    var next = Model.clone(draft)
    if (list === "end") {
      var action = Model.defaultAction(addEndActionType)
      if (Model.isSetterAction(action)) action.restore = false
      next.onEnd.actions.push(action)
    } else next.actions.push(Model.defaultAction(addActionType))
    assignDraft(next)
  }

  function removeAction(index, list) {
    var actions = actionList(list)
    if (!draft || index < 0 || index >= actions.length) return
    var next = Model.clone(draft)
    if (list === "end") next.onEnd.actions.splice(index, 1)
    else next.actions.splice(index, 1)
    argumentErrors = argumentStateAfterRemoval(argumentErrors, index, list)
    argumentTexts = argumentStateAfterRemoval(argumentTexts, index, list)
    assignDraft(next)
  }

  function moveAction(index, delta, list) {
    var actions = actionList(list)
    if (!draft || index < 0 || index >= actions.length) return
    var target = index + delta
    if (target < 0 || target >= actions.length || target === index) return
    argumentErrors = argumentStateAfterMove(argumentErrors, index, target, list)
    argumentTexts = argumentStateAfterMove(argumentTexts, index, target, list)
    if (list === "end") {
      var next = Model.clone(draft)
      var moved = next.onEnd.actions[index]
      next.onEnd.actions[index] = next.onEnd.actions[target]
      next.onEnd.actions[target] = moved
      assignDraft(next)
    } else assignDraft(Model.moveAction(draft, index, delta))
  }

  function listIndexOfKey(key, list) {
    var prefix = list === "end" ? "end:" : ""
    if (key.indexOf(prefix) !== 0) return -1
    var rest = key.slice(prefix.length)
    return /^[0-9]+$/.test(rest) ? Number(rest) : -1
  }

  function argumentStateWithoutIndex(values, index, list) {
    var next = Model.clone(values || {})
    delete next[argumentKey(list, index)]
    return next
  }

  function argumentStateAfterRemoval(values, index, list) {
    var next = ({})
    var keys = Object.keys(values || {})
    for (var i = 0; i < keys.length; i++) {
      var current = listIndexOfKey(keys[i], list)
      if (current < 0) next[keys[i]] = values[keys[i]]
      else if (current < index) next[keys[i]] = values[keys[i]]
      else if (current > index) next[argumentKey(list, current - 1)] = values[keys[i]]
    }
    return next
  }

  function argumentStateAfterMove(values, index, target, list) {
    var next = Model.clone(values || {})
    var fromKey = argumentKey(list, index)
    var targetKey = argumentKey(list, target)
    var hasFrom = Object.prototype.hasOwnProperty.call(next, fromKey)
    var hasTarget = Object.prototype.hasOwnProperty.call(next, targetKey)
    var fromValue = next[fromKey]
    var targetValue = next[targetKey]
    delete next[fromKey]
    delete next[targetKey]
    if (hasFrom) next[targetKey] = fromValue
    if (hasTarget) next[fromKey] = targetValue
    return next
  }

  function setShortcut(keys, override) {
    assignDraft(Model.setShortcut(draft, keys, override))
    pendingChord = ""
    conflictDescription = ""
  }

  function capturedShortcut(keys) {
    var conflict = Model.conflictFor(bindings, keys)
    if (conflict) {
      pendingChord = keys
      conflictDescription = conflict.description
      return
    }
    setShortcut(keys, false)
  }

  function addCondition() {
    if (!draft) return
    assignDraft(Model.addCondition(draft, addConditionType))
  }

  function replaceCondition(index, type) {
    if (!draft || index < 0 || index >= draft.conditions.length) return
    if (draft.conditions[index].type === type) return
    assignDraft(Model.replaceCondition(draft, index, type))
  }

  function removeCondition(index) {
    if (!draft || index < 0 || index >= draft.conditions.length) return
    assignDraft(Model.removeCondition(draft, index))
  }

  function updateCondition(index, key, value) {
    if (!draft || index < 0 || index >= draft.conditions.length) return
    var next = Model.clone(draft)
    next.conditions[index][key] = value
    if (key === "source" && value === "ac") next.conditions[index].batteryBelow = 0
    assignDraft(next)
  }

  function stageConditionText(index, key, value) {
    if (!draft || index < 0 || index >= draft.conditions.length) return
    draft.conditions[index][key] = value
    dirty = true
  }

  function toggleWeekday(index, day) {
    if (!draft || index < 0 || index >= draft.conditions.length) return
    var next = Model.clone(draft)
    var days = Array.isArray(next.conditions[index].weekdays) ? next.conditions[index].weekdays : []
    var position = days.indexOf(day)
    if (position === -1) days.push(day)
    else days.splice(position, 1)
    next.conditions[index].weekdays = Model.WEEKDAY_KEYS.filter(function(key) { return days.indexOf(key) !== -1 })
    assignDraft(next)
  }

  function addSsid(index, ssid) {
    var name = String(ssid || "").trim()
    if (!draft || !name || index < 0 || index >= draft.conditions.length) return
    var next = Model.clone(draft)
    var names = Array.isArray(next.conditions[index].ssids) ? next.conditions[index].ssids : []
    if (names.indexOf(name) !== -1) return
    names.push(name)
    next.conditions[index].ssids = names
    assignDraft(next)
  }

  function removeSsid(index, position) {
    if (!draft || index < 0 || index >= draft.conditions.length) return
    var next = Model.clone(draft)
    var names = Array.isArray(next.conditions[index].ssids) ? next.conditions[index].ssids : []
    if (position < 0 || position >= names.length) return
    names.splice(position, 1)
    next.conditions[index].ssids = names
    assignDraft(next)
  }

  function setEndMode(mode) {
    if (!draft) return
    var next = Model.clone(draft)
    next.onEnd.mode = mode
    assignDraft(next)
  }

  function setKeepUntil(kind) {
    if (!draft) return
    var next = Model.clone(draft)
    if (kind === "minutes") {
      if (typeof next.keepUntil !== "object") next.keepUntil = { minutes: 60 }
    } else next.keepUntil = "conditions"
    assignDraft(next)
  }

  function setKeepMinutes(minutes) {
    if (!draft) return
    var next = Model.clone(draft)
    next.keepUntil = { minutes: minutes }
    assignDraft(next)
  }

  function argumentText(actionIndex, args, list) {
    var key = argumentKey(list, actionIndex)
    return Object.prototype.hasOwnProperty.call(argumentTexts || {}, key)
      ? String(argumentTexts[key]) : JSON.stringify(args || [])
  }

  function stageArgs(text, actionIndex, list) {
    var key = argumentKey(list, actionIndex)
    var values = Model.clone(argumentTexts || {})
    values[key] = text
    argumentTexts = values
    dirty = true

    var parsed
    try { parsed = JSON.parse(String(text || "[]")) }
    catch (e) {
      setArgumentError(key, "Arguments must be a JSON array of strings")
      return
    }
    if (!Array.isArray(parsed)) {
      setArgumentError(key, "Arguments must be a JSON array of strings")
      return
    }
    for (var i = 0; i < parsed.length; i++) {
      if (typeof parsed[i] !== "string") {
        setArgumentError(key, "Every argument must be a string")
        return
      }
    }
    setArgumentError(key, "")
    var actions = actionList(list)
    if (draft && actionIndex >= 0 && actionIndex < actions.length)
      actions[actionIndex].args = parsed
  }

  function setArgumentError(key, message) {
    var next = Model.clone(argumentErrors || {})
    if (message) next[key] = message
    else delete next[key]
    argumentErrors = next
  }

  function save() {
    if (!draft) return
    var errorKeys = Object.keys(argumentErrors || {})
    if (errorKeys.length) {
      localError = argumentErrors[errorKeys[0]]
      return
    }
    var next = Model.clone(draft)
    next.name = nameField.text.trim()
    if (!next.name) {
      localError = "Routine name cannot be empty"
      return
    }
    if (Model.codePointLength(next.name) > 100) {
      localError = "Routine name cannot exceed 100 characters"
      return
    }
    if (next.actions.length === 0) {
      localError = "Add at least one action before saving"
      return
    }
    var detailError = Model.validateRoutineDetails(next)
    if (detailError) {
      localError = detailError
      return
    }
    localError = ""
    root.saveRequested(Model.compactRoutine(next))
  }

  Rectangle {
    anchors.fill: parent
    color: "transparent"

    Column {
      anchors.centerIn: parent
      visible: !root.draft
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Select a routine"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Choose one from the list or create a new routine."
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    QQC.ScrollView {
      id: scroll
      anchors.fill: parent
      visible: !!root.draft
      clip: true
      QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

      Column {
        x: Style.space(4)
        width: Math.max(0, scroll.availableWidth - Style.space(16))
        spacing: Style.space(22)

        Item { width: 1; height: Style.space(1) }

        Row {
          width: parent.width
          spacing: Style.space(12)

          Button {
            id: backButton
            visible: root.showBack
            text: "Back"
            bordered: true
            focusable: true
            onClicked: root.backRequested()
            Accessible.name: "Back to routine list"
          }

          Column {
            width: parent.width - enabledSwitch.width - (backButton.visible ? backButton.width + parent.spacing : 0) - parent.spacing
            spacing: Style.space(3)

            Text {
              textFormat: Text.PlainText
              text: root.draft ? root.draft.name + (root.dirty ? " *" : "") : ""
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              textFormat: Text.PlainText
              text: root.draft ? root.draft.id + (root.isActive ? "  /  ACTIVE" : "") : ""
              color: root.isActive ? Color.accent : Qt.darker(Color.foreground, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: enabledSwitch
            checked: root.draft ? root.draft.enabled : false
            enabled: !root.busy
            activeFocusOnTab: true
            Keys.onReturnPressed: toggled()
            Keys.onEnterPressed: toggled()
            Keys.onSpacePressed: toggled()
            onToggled: root.updateField("enabled", !checked)
            Accessible.name: checked ? "Disable routine" : "Enable routine"
            Accessible.role: Accessible.CheckBox
            Accessible.checkable: true
            Accessible.checked: checked
            Accessible.onPressAction: toggled()
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            textFormat: Text.PlainText
            text: "Routine name"
            color: Qt.darker(Color.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          TextField {
            id: nameField
            width: parent.width
            text: root.draft ? root.draft.name : ""
            enabled: !root.busy
            onTextEdited: root.stageRoutineName(text)
            Accessible.name: "Routine name"
          }
        }

        PanelSeparator { width: parent.width }

        Column {
          width: parent.width
          spacing: Style.space(12)

          PanelSectionHeader { text: "TRIGGERS" }

          ShortcutRecorder {
            id: shortcutRecorder
            width: parent.width
            targetWindow: root.targetWindow
            value: {
              var trigger = root.draft ? Model.shortcutTrigger(root.draft) : null
              return trigger ? trigger.keys : ""
            }
            onCaptured: function(keys) { root.capturedShortcut(keys) }
            onCleared: root.setShortcut("", false)
          }

          BorderSurface {
            visible: root.pendingChord !== ""
            width: parent.width
            implicitHeight: conflictColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.08)
            borderSpec: Border.flat(Util.alpha(Color.urgent, 0.55), 1)

            Column {
              id: conflictColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.pendingChord + " currently runs " + root.conflictDescription + "."
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Row {
                spacing: Style.space(8)
                Button {
                  text: "Choose another"
                  bordered: true
                  focusable: true
                  onClicked: {
                    root.pendingChord = ""
                    root.conflictDescription = ""
                  }
                }
                Button {
                  text: "Override existing"
                  bordered: true
                  focusable: true
                  foreground: Color.urgent
                  onClicked: root.setShortcut(root.pendingChord, true)
                }
              }
            }
          }

          MultiSelect {
            id: hookSelect
            width: parent.width
            label: "Omarchy events"
            values: []
            options: root.hookOptions
            noSelectionText: "No automatic events"
            placeholderText: "Filter events..."
            onChanged: function(values) { root.assignDraft(Model.setHooks(root.draft, values)) }
            Accessible.role: Accessible.List
            Accessible.name: "Omarchy event triggers"
          }

          Text {
            textFormat: Text.PlainText
            visible: root.stateful
            width: parent.width
            text: "This routine changes state that can be restored, so its shortcut and manual runs toggle it on and off. Events only turn it on."
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator { width: parent.width }

        Column {
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CONDITIONS"
              width: parent.width - conditionCount.width - parent.spacing
            }
            Text {
              textFormat: Text.PlainText
              id: conditionCount
              text: root.draft ? root.draft.conditions.length + " total" : ""
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "All conditions must hold. While they do, the routine is active; when one stops holding, it ends and restores. Conditions are evaluated only after Connect."
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.draft ? root.draft.conditions : []

            BorderSurface {
              id: conditionCard
              required property var modelData
              required property int index
              readonly property string conditionType: modelData ? String(modelData.type || "") : ""
              width: parent.width
              implicitHeight: conditionContent.implicitHeight + Style.space(24)
              radius: Style.cornerRadius
              color: Util.alpha(Color.accent, 0.035)
              borderSpec: Border.flat(Util.alpha(Color.accent, 0.22), 1)

              Column {
                id: conditionContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(12)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(24)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "IF"
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  ChoicePicker {
                    width: parent.width - Style.space(24) - removeCondition.width - parent.spacing * 2
                    showLabel: false
                    value: conditionCard.conditionType
                    options: root.conditionTypeOptions
                    onChanged: function(value) { root.replaceCondition(conditionCard.index, value) }
                  }
                  PanelActionButton {
                    id: removeCondition
                    iconText: "x"
                    tooltipText: "Remove condition"
                    focusable: true
                    hoverColor: Color.urgent
                    onClicked: root.removeCondition(conditionCard.index)
                  }
                }

                Column {
                  visible: conditionCard.conditionType === "time"
                  width: parent.width
                  spacing: Style.space(10)
                  Row {
                    width: parent.width
                    spacing: Style.space(10)
                    Column {
                      width: (parent.width - parent.spacing) / 2
                      spacing: Style.spacing.labelGap
                      Text {
                        textFormat: Text.PlainText
                        text: "From (24-hour HH:MM)"
                        color: Qt.darker(Color.foreground, 1.4)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                      TextField {
                        width: parent.width
                        text: (conditionCard.modelData && conditionCard.modelData.start) || ""
                        placeholderText: "18:30"
                        onTextEdited: root.stageConditionText(conditionCard.index, "start", text)
                      }
                    }
                    Column {
                      width: (parent.width - parent.spacing) / 2
                      spacing: Style.spacing.labelGap
                      Text {
                        textFormat: Text.PlainText
                        text: "Until"
                        color: Qt.darker(Color.foreground, 1.4)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                      TextField {
                        width: parent.width
                        text: (conditionCard.modelData && conditionCard.modelData.end) || ""
                        placeholderText: "08:00"
                        onTextEdited: root.stageConditionText(conditionCard.index, "end", text)
                      }
                    }
                  }
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    Repeater {
                      model: root.weekdayOptions
                      Button {
                        required property var modelData
                        text: modelData.label
                        bordered: true
                        focusable: true
                        selected: !!conditionCard.modelData && Array.isArray(conditionCard.modelData.weekdays)
                          && conditionCard.modelData.weekdays.indexOf(modelData.value) !== -1
                        onClicked: root.toggleWeekday(conditionCard.index, modelData.value)
                        Accessible.name: modelData.label
                        Accessible.role: Accessible.CheckBox
                        Accessible.checkable: true
                        Accessible.checked: selected
                      }
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "No weekday selected means every day. An end time before the start crosses midnight and counts as the day it started."
                    color: Qt.darker(Color.foreground, 1.55)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                Column {
                  visible: conditionCard.conditionType === "wifi"
                  width: parent.width
                  spacing: Style.space(10)
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    Repeater {
                      model: conditionCard.modelData && Array.isArray(conditionCard.modelData.ssids) ? conditionCard.modelData.ssids : []
                      Button {
                        required property var modelData
                        required property int index
                        text: String(modelData) + "  x"
                        bordered: true
                        focusable: true
                        onClicked: root.removeSsid(conditionCard.index, index)
                        Accessible.name: "Remove network " + String(modelData)
                      }
                    }
                    Text {
                      textFormat: Text.PlainText
                      visible: !conditionCard.modelData || !Array.isArray(conditionCard.modelData.ssids) || conditionCard.modelData.ssids.length === 0
                      text: "No networks yet"
                      color: Qt.darker(Color.foreground, 1.55)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                  ChoicePicker {
                    searchable: true
                    width: parent.width
                    label: "Add a known or visible network"
                    value: ""
                    options: root.wifiOptions
                    placeholderText: "Search networks..."
                    onChanged: function(value) { root.addSsid(conditionCard.index, value) }
                  }
                  Row {
                    width: parent.width
                    spacing: Style.space(8)
                    TextField {
                      id: manualSsid
                      width: parent.width - addSsidButton.width - parent.spacing
                      placeholderText: "Or type a network name"
                      Accessible.name: "Network name"
                    }
                    Button {
                      id: addSsidButton
                      text: "Add"
                      bordered: true
                      focusable: true
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: {
                        root.addSsid(conditionCard.index, manualSsid.text)
                        manualSsid.text = ""
                      }
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: "Matches the network name only, exactly as shown."
                    color: Qt.darker(Color.foreground, 1.55)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                Row {
                  visible: conditionCard.conditionType === "power"
                  width: parent.width
                  spacing: Style.space(16)
                  ChoicePicker {
                    width: Math.min(Style.space(260), parent.width * 0.5)
                    label: "Power source"
                    value: (conditionCard.modelData && conditionCard.modelData.source) || "battery"
                    options: root.powerSourceOptions
                    onChanged: function(value) { root.updateCondition(conditionCard.index, "source", value) }
                  }
                  NumberField {
                    visible: !!conditionCard.modelData && conditionCard.modelData.source === "battery"
                    anchors.bottom: parent.bottom
                    label: "Battery below % (0 = any level)"
                    value: conditionCard.modelData && typeof conditionCard.modelData.batteryBelow === "number" ? conditionCard.modelData.batteryBelow : 0
                    from: 0
                    to: 100
                    stepSize: 5
                    onModified: function(value) { root.updateCondition(conditionCard.index, "batteryBelow", value) }
                  }
                }

                Column {
                  visible: conditionCard.conditionType === "omarchy-toggle"
                  width: parent.width
                  spacing: Style.space(10)
                  ChoicePicker {
                    searchable: true
                    width: parent.width
                    label: "Omarchy toggle flag"
                    value: (conditionCard.modelData && conditionCard.modelData.flag) || ""
                    options: root.toggleOptions
                    placeholderText: "Flags currently on..."
                    onChanged: function(value) { root.updateCondition(conditionCard.index, "flag", value) }
                  }
                  TextField {
                    width: parent.width
                    text: (conditionCard.modelData && conditionCard.modelData.flag) || ""
                    placeholderText: "Or type a flag name, as used by omarchy toggle <flag>"
                    onTextEdited: root.stageConditionText(conditionCard.index, "flag", text)
                  }
                }
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(10)
            ChoicePicker {
              width: Math.min(Style.space(300), parent.width)
              showLabel: false
              value: root.addConditionType
              options: root.conditionTypeOptions
              onChanged: function(value) { root.addConditionType = value }
            }
            Button {
              text: "Add condition"
              bordered: true
              focusable: true
              onClicked: root.addCondition()
            }
          }
        }

        PanelSeparator { width: parent.width }

        Column {
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACTIONS"
              width: parent.width - actionCount.width - parent.spacing
            }
            Text {
              textFormat: Text.PlainText
              id: actionCount
              text: root.draft ? root.draft.actions.length + " total" : ""
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.draft ? root.draft.actions : []

            ActionCard {
              width: parent.width
              count: root.draft ? root.draft.actions.length : 0
              typeOptions: root.actionTypeOptions
              appOptions: root.appOptions
              commandOptions: root.commandOptions
              themeOptions: root.themeOptions
              argumentsText: root.argumentText(index, modelData.args, "main")
              onTypeChanged: function(type) { root.replaceAction(index, type, "main") }
              onFieldChanged: function(key, value) { root.updateAction(index, key, value, "main") }
              onTextStaged: function(key, value) { root.stageActionText(index, key, value, "main") }
              onArgsStaged: function(text) { root.stageArgs(text, index, "main") }
              onMoveRequested: function(delta) { root.moveAction(index, delta, "main") }
              onRemoveRequested: root.removeAction(index, "main")
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(10)
            ChoicePicker {
              width: Math.min(Style.space(300), parent.width)
              showLabel: false
              value: root.addActionType
              options: root.actionTypeOptions
              onChanged: function(value) { root.addActionType = value }
            }
            Button {
              id: addActionButton
              text: "Add action"
              bordered: true
              focusable: true
              onClicked: root.addAction("main")
            }
          }
        }

        PanelSeparator {
          visible: root.showsLifecycle
          width: parent.width
        }

        Column {
          visible: root.showsLifecycle
          width: parent.width
          spacing: Style.space(12)

          PanelSectionHeader { text: "WHEN ROUTINE ENDS" }

          ChoicePicker {
            width: parent.width
            label: "Ending behavior"
            value: root.draft ? root.draft.onEnd.mode : "restore"
            options: root.endModeOptions
            onChanged: function(value) { root.setEndMode(value) }
          }

          Column {
            visible: !!root.draft && root.draft.onEnd.mode === "actions"
            width: parent.width
            spacing: Style.space(12)

            Repeater {
              model: root.draft ? root.draft.onEnd.actions : []

              ActionCard {
                width: parent.width
                endList: true
                count: root.draft ? root.draft.onEnd.actions.length : 0
                typeOptions: root.actionTypeOptions
                appOptions: root.appOptions
                commandOptions: root.commandOptions
                themeOptions: root.themeOptions
                argumentsText: root.argumentText(index, modelData.args, "end")
                onTypeChanged: function(type) { root.replaceAction(index, type, "end") }
                onFieldChanged: function(key, value) { root.updateAction(index, key, value, "end") }
                onTextStaged: function(key, value) { root.stageActionText(index, key, value, "end") }
                onArgsStaged: function(text) { root.stageArgs(text, index, "end") }
                onMoveRequested: function(delta) { root.moveAction(index, delta, "end") }
                onRemoveRequested: root.removeAction(index, "end")
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(10)
              ChoicePicker {
                width: Math.min(Style.space(300), parent.width)
                showLabel: false
                value: root.addEndActionType
                options: root.actionTypeOptions
                onChanged: function(value) { root.addEndActionType = value }
              }
              Button {
                text: "Add end action"
                bordered: true
                focusable: true
                onClicked: root.addAction("end")
              }
            }
          }

          PanelSectionHeader { text: "KEEP UNTIL" }

          Row {
            width: parent.width
            spacing: Style.space(12)
            ChoicePicker {
              width: Math.min(Style.space(360), parent.width)
              label: "Keep routine until"
              value: root.draft && typeof root.draft.keepUntil === "object" ? "minutes" : "conditions"
              options: root.keepUntilOptions
              onChanged: function(value) { root.setKeepUntil(value) }
            }
            NumberField {
              visible: !!root.draft && typeof root.draft.keepUntil === "object"
              anchors.bottom: parent.bottom
              label: "Minutes"
              value: root.draft && typeof root.draft.keepUntil === "object" ? root.draft.keepUntil.minutes : 60
              from: 1
              to: 1440
              stepSize: 5
              onModified: function(value) { root.setKeepMinutes(value) }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.localError !== "" || root.argumentError !== "" || root.externalError !== ""
          width: parent.width
          text: root.displayedError()
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: root.busy ? "Saving..." : "Save routine"
            bordered: true
            focusable: true
            active: true
            enabled: !root.busy
            onClicked: root.save()
          }
          Button {
            text: root.stateful ? (root.isActive ? "Deactivate" : "Activate") : "Test saved"
            bordered: true
            focusable: true
            enabled: !root.busy && root.persisted && !root.dirty && !!root.draft
            onClicked: root.runRequested(root.draft.id)
          }
          Button {
            id: duplicateButton
            text: "Duplicate"
            bordered: true
            focusable: true
            enabled: !root.busy && root.persisted && !root.dirty && !!root.draft
            onClicked: root.duplicateRequested(root.draft.id)
          }
          Button {
            id: deleteButton
            text: "Delete"
            bordered: true
            focusable: true
            foreground: Color.urgent
            enabled: !root.busy && root.persisted && !!root.draft
            onClicked: root.deleteRequested(root.draft.id)
          }
        }

        Item { width: 1; height: Style.space(6) }
      }
    }
  }
}
