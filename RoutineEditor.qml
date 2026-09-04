import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Conditions.js" as Conditions

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
  property bool running: false
  property bool persisted: true
  property bool showBack: false
  property bool isActive: false
  property var activeRecord: null
  property var serviceState: null
  property string externalError: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property color success: Color.accent

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color subtle: Qt.darker(foreground, 1.5)

  property var draft: null
  property string localError: ""
  property var argumentErrors: ({})
  property var argumentTexts: ({})
  property bool dirty: false
  property bool showErrors: false
  readonly property var cardErrors: showErrors && draft ? Model.validationByIndex(draft) : ({ conditions: {}, actions: {}, end: {}, routine: "" })
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
  readonly property bool recording: shortcutRecorder.recording
  readonly property bool canRun: !busy && persisted && !!draft
  readonly property string runLabel: !draft ? "Run"
    : (stateful ? (isActive ? "Turn off" : "Turn on") : "Run now")

  readonly property var actionTypeOptions: Model.ACTION_TYPES
  readonly property var hookOptions: Model.HOOKS
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
    { value: "restore", label: "Put settings back", description: "Setters marked to restore are reverted" },
    { value: "actions", label: "Put settings back, then run end actions", description: "Revert setters, then run a separate action list" },
    { value: "none", label: "Leave everything as it is", description: "Nothing is reverted when the routine ends" }
  ]
  readonly property var keepUntilOptions: !!draft && Model.hasConditions(draft) ? [
    { value: "conditions", label: "Its conditions stop matching", description: "Or until you turn it off" },
    { value: "minutes", label: "A fixed number of minutes", description: "Ends automatically after the given time" }
  ] : [
    { value: "conditions", label: "You turn it off", description: "From the list, the bar, or its shortcut" },
    { value: "minutes", label: "A fixed number of minutes", description: "Ends automatically after the given time" }
  ]

  signal saveRequested(var routine)
  signal saveAndRunRequested(var routine)
  signal deleteRequested(string id)
  signal duplicateRequested(string id)
  signal runRequested(string id)
  signal backRequested()

  onRoutineChanged: resetDraft()
  onBindingsChanged: clearResolvedBindingError()
  onPersistedChanged: if (draft && !persisted) dirty = true

  function resetDraft() {
    draft = routine ? Model.normalizeRoutine(routine) : null
    nameField.text = draft ? draft.name : ""
    localError = ""
    externalError = ""
    showErrors = false
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

  function headerMeta() {
    if (!draft) return ""
    if (isActive) {
      var parts = ["On"]
      var since = activeRecord ? Conditions.clockTime(activeRecord.activatedAt) : ""
      var how = activeRecord ? Model.triggerLabel(activeRecord.trigger) : ""
      if (since) parts.push("since " + since + (how ? " " + how : ""))
      if (activeRecord && activeRecord.expiresAt) parts.push("until " + Conditions.clockTime(activeRecord.expiresAt))
      return parts.join(" ")
    }
    var meta = [draft.id]
    if (stateful) meta.push("mode")
    if (!persisted) meta.push("not saved yet")
    return meta.join(" · ")
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
    // The card is rebuilt in its new place; give the keyboard its button back.
    refocusCard(list === "end" ? endCards : actionCards, target, delta)
  }

  function refocusCard(repeater, index, delta) {
    Qt.callLater(function() {
      var card = repeater.itemAt(index)
      if (card && typeof card.focusMoveButton === "function") card.focusMoveButton(delta)
    })
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

  // Returns the routine to hand to the runner, or null after reporting why.
  function validatedRoutine() {
    if (!draft) return null
    var errorKeys = Object.keys(argumentErrors || {})
    if (errorKeys.length) {
      localError = argumentErrors[errorKeys[0]]
      showErrors = true
      return null
    }
    var next = Model.clone(draft)
    next.name = nameField.text.trim()
    if (!next.name) {
      localError = "Routine name cannot be empty"
      return null
    }
    if (Model.codePointLength(next.name) > 100) {
      localError = "Routine name cannot exceed 100 characters"
      return null
    }
    if (next.actions.length === 0) {
      localError = "Add at least one action before saving"
      return null
    }
    var detailError = Model.validateRoutineDetails(next)
    if (detailError) {
      localError = detailError
      showErrors = true
      scrollToFirstError()
      return null
    }
    localError = ""
    showErrors = false
    return next
  }

  function save() {
    var next = validatedRoutine()
    if (next) root.saveRequested(Model.compactRoutine(next))
  }

  function saveAndRun() {
    var next = validatedRoutine()
    if (next) root.saveAndRunRequested(Model.compactRoutine(next))
  }

  function runOrSave() {
    if (!draft) return
    if (dirty || !persisted) {
      // Applying a disabled active routine already ends it; running afterward
      // would toggle it straight back on through the manual test path.
      if (persisted && isActive && draft.enabled === false) save()
      else saveAndRun()
    }
    else runRequested(draft.id)
  }

  function scrollToFirstError() {
    Qt.callLater(function() {
      var errors = root.cardErrors
      var target = null
      var keys = Object.keys(errors.conditions)
      if (keys.length) target = conditionCards.itemAt(Number(keys[0]))
      if (!target) {
        keys = Object.keys(errors.actions)
        if (keys.length) target = actionCards.itemAt(Number(keys[0]))
      }
      if (!target) {
        keys = Object.keys(errors.end)
        if (keys.length) target = endCards.itemAt(Number(keys[0]))
      }
      if (target) ensureVisible(target)
    })
  }

  // Keeps the focused control inside the scrolled form, the way the shell's
  // own keyboard-driven panels do.
  function ensureVisible(item) {
    if (!item || !scroll) return
    var flick = scroll.contentItem
    if (!flick || flick.contentY === undefined) return
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = Style.space(12)
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin) flick.contentY = Math.max(0, bottom + margin - flick.height)
  }

  function isInsideForm(item) {
    var current = item
    while (current) {
      if (current === form) return true
      current = current.parent
    }
    return false
  }

  Connections {
    target: root.targetWindow
    ignoreUnknownSignals: true
    function onActiveFocusItemChanged() {
      var item = root.targetWindow ? root.targetWindow.activeFocusItem : null
      if (item && root.isInsideForm(item)) root.ensureVisible(item)
    }
  }

  Rectangle {
    anchors.fill: parent
    color: "transparent"

    EmptyState {
      anchors.centerIn: parent
      width: Math.min(parent.width, Style.space(360))
      visible: !root.draft
      glyph: "󰐐"
      title: "Select a routine"
      body: "Choose one from the list, or start a new one from a template."
      foreground: root.foreground
    }

    Column {
      anchors.fill: parent
      visible: !!root.draft
      spacing: Style.spacing.rowGap

      // ------------------------------------------------------- header
      Row {
        id: header
        width: parent.width
        spacing: Style.spacing.rowGap

        Button {
          id: backButton
          visible: root.showBack
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰅁"
          text: "Back"
          bordered: true
          focusable: true
          foreground: root.foreground
          accent: root.accent
          onClicked: root.backRequested()
          Accessible.name: "Back to routine list"
          Accessible.role: Accessible.Button
        }

        Column {
          width: parent.width - liveSwitch.width - (backButton.visible ? backButton.width + parent.spacing : 0) - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Row {
            width: parent.width
            spacing: Style.space(6)

            Rectangle {
              id: liveDot
              visible: root.isActive
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(6)
              height: width
              radius: width / 2
              color: root.success
              SequentialAnimation on opacity {
                running: liveDot.visible && root.visible
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { from: 1.0; to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.35; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: root.draft ? (nameField.text.trim() || "Untitled routine") : ""
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: Math.min(implicitWidth, parent.width - (liveDot.visible ? liveDot.width + parent.spacing : 0) - (dirtyPill.visible ? dirtyPill.width + parent.spacing : 0))
            }

            KeyCap {
              id: dirtyPill
              visible: root.dirty
              anchors.verticalCenter: parent.verticalCenter
              text: "unsaved"
              foreground: root.accent
              accent: root.accent
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.headerMeta().toUpperCase()
            color: root.isActive ? root.success : root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }
        }

        // The live switch: on or off right now. The saved "enabled" flag
        // lives in the form below so the two cannot be confused.
        ToggleSwitch {
          id: liveSwitch
          visible: root.stateful && root.persisted
          anchors.verticalCenter: parent.verticalCenter
          checked: root.isActive
          busy: root.running
          interactive: root.canRun && !root.dirty && !root.running
          foreground: root.foreground
          accent: root.accent
          activeFocusOnTab: visible
          Keys.onReturnPressed: if (interactive) root.runRequested(root.draft.id)
          Keys.onEnterPressed: if (interactive) root.runRequested(root.draft.id)
          Keys.onSpacePressed: if (interactive) root.runRequested(root.draft.id)
          onToggled: if (interactive) root.runRequested(root.draft.id)
          Accessible.role: Accessible.CheckBox
          Accessible.name: root.isActive ? "Turn the routine off now" : "Turn the routine on now"
          Accessible.checkable: true
          Accessible.checked: checked
          Accessible.onPressAction: if (interactive) root.runRequested(root.draft.id)
          PanelToolTip {
            visible: parent.containsMouse
            text: root.dirty ? "Save the routine first" : (root.isActive ? "Turn off now and put settings back" : "Turn on now")
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      // ---------------------------------------------------------- form
      QQC.ScrollView {
        id: scroll
        width: parent.width
        height: parent.height - y - footer.height - parent.spacing * 2 - footerRule.height
        clip: true
        contentWidth: availableWidth
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff
        QQC.ScrollBar.vertical: PanelScrollBar {
          foreground: root.foreground
          accent: root.accent
        }

        Column {
          id: form
          x: Style.space(2)
          width: Math.max(0, scroll.availableWidth - Style.space(12))
          spacing: Style.space(18)
          enabled: !root.busy
          opacity: root.busy ? 0.7 : 1
          Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

          Item { width: 1; height: Style.space(1) }

          Column {
            width: parent.width
            spacing: Style.spacing.rowGap

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap
              Text {
                textFormat: Text.PlainText
                text: "Routine name"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              TextField {
                id: nameField
                width: parent.width
                text: root.draft ? root.draft.name : ""
                foreground: root.foreground
                accent: root.accent
                onTextEdited: root.stageRoutineName(text)
                Accessible.name: "Routine name"
              }
            }

            Toggle {
              width: parent.width
              label: "Enabled"
              description: "Shortcuts, events, and conditions may start this routine. Turning it off while it is on ends it on save."
              checked: root.draft ? root.draft.enabled : false
              foreground: root.foreground
              accent: root.accent
              activeFocusOnTab: true
              Keys.onReturnPressed: clicked()
              Keys.onEnterPressed: clicked()
              Keys.onSpacePressed: clicked()
              onClicked: root.updateField("enabled", !checked)
              Accessible.role: Accessible.CheckBox
              Accessible.name: "Enabled"
              Accessible.checkable: true
              Accessible.checked: checked
              Accessible.onPressAction: clicked()
            }
          }

          // ---------------------------------------------- starts when
          Column {
            width: parent.width
            spacing: Style.spacing.rowGap

            PanelSectionHeader {
              width: parent.width
              text: "STARTS WHEN"
              foreground: root.foreground
            }

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

            Collapsible {
              width: parent.width
              shown: root.pendingChord !== ""
              spacing: Style.spacing.rowGap

              BorderSurface {
                width: parent.width
                implicitHeight: conflictColumn.implicitHeight + Style.space(24)
                radius: Style.cornerRadius
                color: Util.alpha(root.urgent, 0.10)
                borderSpec: Border.flat(Util.alpha(root.urgent, 0.35), 1)

                Column {
                  id: conflictColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  spacing: Style.spacing.rowGap

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.pendingChord + " currently runs " + root.conflictDescription + "."
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }
                  Row {
                    spacing: Style.spacing.rowGap
                    Button {
                      text: "Choose another"
                      bordered: true
                      focusable: true
                      foreground: root.foreground
                      accent: root.accent
                      onClicked: {
                        root.pendingChord = ""
                        root.conflictDescription = ""
                      }
                      Accessible.role: Accessible.Button
                      Accessible.name: "Choose another shortcut"
                    }
                    Button {
                      text: "Override existing"
                      bordered: true
                      focusable: true
                      foreground: root.urgent
                      accent: root.accent
                      onClicked: root.setShortcut(root.pendingChord, true)
                      Accessible.role: Accessible.Button
                      Accessible.name: "Override the existing shortcut"
                    }
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
              foreground: root.foreground
              accent: root.accent
              onChanged: function(values) { root.assignDraft(Model.setHooks(root.draft, values)) }
              Accessible.role: Accessible.List
              Accessible.name: "Omarchy event triggers"
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.stateful
                ? "Its shortcut and Run now toggle this routine on and off; events and conditions only turn it on. You can also start it by hand from the list or the bar."
                : "You can also run it by hand from the list."
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ------------------------------------------------------- if
          Column {
            width: parent.width
            spacing: Style.spacing.rowGap

            Row {
              width: parent.width
              spacing: Style.spacing.rowGap
              PanelSectionHeader {
                width: parent.width - conditionHint.width - parent.spacing
                text: "IF"
                foreground: root.foreground
              }
              Text {
                textFormat: Text.PlainText
                id: conditionHint
                text: root.draft && root.draft.conditions.length > 1 ? "ALL MUST HOLD" : ""
                color: root.subtle
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !!root.draft && root.draft.conditions.length === 0
              width: parent.width
              text: "No conditions: the routine only starts from its shortcut, an event, or by hand. Add one and Omachord turns the routine on while it holds and off when it stops, only while Omachord is on."
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              id: conditionCards
              model: root.draft ? root.draft.conditions : []

              BorderSurface {
                id: conditionCard
                required property var modelData
                required property int index
                readonly property string conditionType: modelData ? String(modelData.type || "") : ""
                readonly property string errorText: root.cardErrors.conditions[index] || ""
                readonly property var liveDetail: root.serviceState && Array.isArray(root.serviceState.details)
                  && root.serviceState.details[index] ? root.serviceState.details[index] : null
                width: parent.width
                implicitHeight: conditionContent.implicitHeight + Style.space(24)
                radius: Style.cornerRadius
                color: errorText ? Util.alpha(root.urgent, 0.10) : Style.normalFillFor(root.foreground, root.accent)
                borderSpec: errorText ? Border.flat(Util.alpha(root.urgent, 0.35), 1) : Border.flat(Util.alpha(root.foreground, 0.10), 1)
                Behavior on color { ColorAnimation { duration: 120 } }

                Column {
                  id: conditionContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  spacing: Style.spacing.rowGap

                  Row {
                    width: parent.width
                    spacing: Style.spacing.rowGap

                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(18)
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(conditionCard.index + 1)
                      color: root.dim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    ChoicePicker {
                      width: parent.width - Style.space(18) - removeCondition.width - parent.spacing * 2
                      showLabel: false
                      value: conditionCard.conditionType
                      options: root.conditionTypeOptions
                      foreground: root.foreground
                      accent: root.accent
                      onChanged: function(value) { root.replaceCondition(conditionCard.index, value) }
                      Accessible.name: "Condition " + (conditionCard.index + 1) + " type"
                    }
                    PanelActionButton {
                      id: removeCondition
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: "󰅙"
                      tooltipText: "Remove condition"
                      focusable: true
                      foreground: root.foreground
                      hoverColor: root.urgent
                      size: Style.spacing.controlHeight
                      onClicked: root.removeCondition(conditionCard.index)
                      Accessible.role: Accessible.Button
                      Accessible.name: "Remove condition " + (conditionCard.index + 1)
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: conditionCard.errorText !== ""
                    width: parent.width
                    text: conditionCard.errorText
                    color: root.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Column {
                    visible: conditionCard.conditionType === "time"
                    width: parent.width
                    spacing: Style.spacing.rowGap
                    Row {
                      width: parent.width
                      spacing: Style.spacing.rowGap
                      Column {
                        width: (parent.width - parent.spacing) / 2
                        spacing: Style.spacing.labelGap
                        Text {
                          textFormat: Text.PlainText
                          text: "From (24-hour HH:MM)"
                          color: root.dim
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                        TextField {
                          width: parent.width
                          text: (conditionCard.modelData && conditionCard.modelData.start) || ""
                          placeholderText: "18:30"
                          foreground: root.foreground
                          accent: root.accent
                          onTextEdited: root.stageConditionText(conditionCard.index, "start", text)
                          Accessible.name: "Start time, 24-hour HH:MM"
                        }
                      }
                      Column {
                        width: (parent.width - parent.spacing) / 2
                        spacing: Style.spacing.labelGap
                        Text {
                          textFormat: Text.PlainText
                          text: "Until"
                          color: root.dim
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                        TextField {
                          width: parent.width
                          text: (conditionCard.modelData && conditionCard.modelData.end) || ""
                          placeholderText: "08:00"
                          foreground: root.foreground
                          accent: root.accent
                          onTextEdited: root.stageConditionText(conditionCard.index, "end", text)
                          Accessible.name: "End time, 24-hour HH:MM"
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
                          foreground: root.foreground
                          accent: root.accent
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
                      text: "No weekday selected means every day. An end before the start crosses midnight and counts as the day it started."
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }

                  Column {
                    visible: conditionCard.conditionType === "wifi"
                    width: parent.width
                    spacing: Style.spacing.rowGap
                    Flow {
                      width: parent.width
                      spacing: Style.space(6)
                      Repeater {
                        model: conditionCard.modelData && Array.isArray(conditionCard.modelData.ssids) ? conditionCard.modelData.ssids : []
                        Button {
                          required property var modelData
                          required property int index
                          iconText: "󰅖"
                          text: String(modelData)
                          bordered: true
                          focusable: true
                          foreground: root.foreground
                          accent: root.accent
                          onClicked: root.removeSsid(conditionCard.index, index)
                          Accessible.role: Accessible.Button
                          Accessible.name: "Remove network " + String(modelData)
                        }
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: !conditionCard.modelData || !Array.isArray(conditionCard.modelData.ssids) || conditionCard.modelData.ssids.length === 0
                        text: "No networks yet"
                        color: root.subtle
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                    ChoicePicker {
                      id: wifiPicker
                      searchable: true
                      width: parent.width
                      label: "Add a known or visible network"
                      value: ""
                      options: root.wifiOptions
                      placeholderText: "Search networks..."
                      foreground: root.foreground
                      accent: root.accent
                      onChanged: function(value) {
                        root.addSsid(conditionCard.index, value)
                        wifiPicker.value = ""
                      }
                      Accessible.name: "Add a Wi-Fi network"
                    }
                    Row {
                      width: parent.width
                      spacing: Style.spacing.rowGap
                      TextField {
                        id: manualSsid
                        width: parent.width - addSsidButton.width - parent.spacing
                        placeholderText: "Or type a network name"
                        foreground: root.foreground
                        accent: root.accent
                        Accessible.name: "Network name"
                        Keys.onReturnPressed: addSsidButton.clicked()
                      }
                      Button {
                        id: addSsidButton
                        text: "Add"
                        bordered: true
                        focusable: true
                        foreground: root.foreground
                        accent: root.accent
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: {
                          root.addSsid(conditionCard.index, manualSsid.text)
                          manualSsid.text = ""
                        }
                        Accessible.role: Accessible.Button
                        Accessible.name: "Add the typed network"
                      }
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: "Matches the network name only, exactly as shown."
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }

                  Row {
                    visible: conditionCard.conditionType === "power"
                    width: parent.width
                    spacing: Style.spacing.panelGap
                    ChoicePicker {
                      width: Math.min(Style.space(260), parent.width * 0.5)
                      label: "Power source"
                      value: (conditionCard.modelData && conditionCard.modelData.source) || "battery"
                      options: root.powerSourceOptions
                      foreground: root.foreground
                      accent: root.accent
                      onChanged: function(value) { root.updateCondition(conditionCard.index, "source", value) }
                      Accessible.name: "Power source"
                    }
                    NumberField {
                      visible: !!conditionCard.modelData && conditionCard.modelData.source === "battery"
                      anchors.bottom: parent.bottom
                      label: "Battery below % (0 = any level)"
                      value: conditionCard.modelData && typeof conditionCard.modelData.batteryBelow === "number" ? conditionCard.modelData.batteryBelow : 0
                      from: 0
                      to: 100
                      stepSize: 5
                      foreground: root.foreground
                      accent: root.accent
                      onModified: function(value) { root.updateCondition(conditionCard.index, "batteryBelow", value) }
                      Component.onCompleted: field.Accessible.name = label
                    }
                  }

                  Column {
                    visible: conditionCard.conditionType === "omarchy-toggle"
                    width: parent.width
                    spacing: Style.spacing.rowGap
                    ChoicePicker {
                      searchable: true
                      width: parent.width
                      label: "Omarchy toggle flag"
                      value: (conditionCard.modelData && conditionCard.modelData.flag) || ""
                      options: root.toggleOptions
                      placeholderText: "Flags currently on..."
                      foreground: root.foreground
                      accent: root.accent
                      onChanged: function(value) { root.updateCondition(conditionCard.index, "flag", value) }
                      Accessible.name: "Omarchy toggle flag"
                    }
                    TextField {
                      width: parent.width
                      text: (conditionCard.modelData && conditionCard.modelData.flag) || ""
                      placeholderText: "Or type a flag name, as used by omarchy toggle <flag>"
                      foreground: root.foreground
                      accent: root.accent
                      onTextEdited: root.stageConditionText(conditionCard.index, "flag", text)
                      Accessible.name: "Toggle flag name"
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: !!conditionCard.liveDetail && root.persisted && !root.dirty
                    width: parent.width
                    text: conditionCard.liveDetail
                      ? ((conditionCard.liveDetail.matched ? "Holds now" : "Not holding now")
                        + (conditionCard.liveDetail.state ? " · " + conditionCard.liveDetail.state : ""))
                      : ""
                    color: conditionCard.liveDetail && conditionCard.liveDetail.matched ? root.success : root.subtle
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            ChoicePicker {
              id: addConditionPicker
              width: Math.min(Style.space(300), parent.width)
              showLabel: false
              leadingIcon: "󰐕"
              value: ""
              placeholderText: "Add condition"
              options: root.conditionTypeOptions
              foreground: root.foreground
              accent: root.accent
              onChanged: function(value) {
                root.addConditionType = value
                root.addCondition()
                addConditionPicker.value = ""
              }
              Accessible.name: "Add condition"
            }
          }

          // ----------------------------------------------------- then
          Column {
            width: parent.width
            spacing: Style.spacing.rowGap

            Row {
              width: parent.width
              spacing: Style.spacing.rowGap
              PanelSectionHeader {
                width: parent.width - actionHint.width - parent.spacing
                text: "THEN"
                foreground: root.foreground
              }
              Text {
                textFormat: Text.PlainText
                id: actionHint
                text: root.draft && root.draft.actions.length > 1 ? "IN ORDER" : ""
                color: root.subtle
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !!root.draft && root.draft.actions.length === 0
              width: parent.width
              text: "Add at least one action. Actions run in order and stop at the first failure."
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              id: actionCards
              model: root.draft ? root.draft.actions : []

              ActionCard {
                width: parent.width
                count: root.draft ? root.draft.actions.length : 0
                typeOptions: root.actionTypeOptions
                appOptions: root.appOptions
                commandOptions: root.commandOptions
                themeOptions: root.themeOptions
                argumentsText: root.argumentText(index, modelData.args, "main")
                errorText: root.cardErrors.actions[index] || ""
                foreground: root.foreground
                accent: root.accent
                urgent: root.urgent
                onTypeChanged: function(type) { root.replaceAction(index, type, "main") }
                onFieldChanged: function(key, value) { root.updateAction(index, key, value, "main") }
                onTextStaged: function(key, value) { root.stageActionText(index, key, value, "main") }
                onArgsStaged: function(text) { root.stageArgs(text, index, "main") }
                onMoveRequested: function(delta) { root.moveAction(index, delta, "main") }
                onRemoveRequested: root.removeAction(index, "main")
              }
            }

            ChoicePicker {
              id: addActionPicker
              width: Math.min(Style.space(300), parent.width)
              showLabel: false
              leadingIcon: "󰐕"
              value: ""
              placeholderText: "Add action"
              options: root.actionTypeOptions
              foreground: root.foreground
              accent: root.accent
              onChanged: function(value) {
                root.addActionType = value
                root.addAction("main")
                addActionPicker.value = ""
              }
              Accessible.name: "Add action"
            }
          }

          // ------------------------------------------------ when it ends
          Column {
            width: parent.width
            spacing: Style.spacing.rowGap

            PanelSectionHeader {
              width: parent.width
              text: "WHEN IT ENDS"
              foreground: root.foreground
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.showsLifecycle
              width: parent.width
              text: "This routine runs once and has nothing to put back. Mark a setter to restore, add a condition, or set a timer and it becomes a mode that can be on and off."
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Collapsible {
              width: parent.width
              shown: root.showsLifecycle
              spacing: Style.spacing.rowGap

              ChoicePicker {
                width: parent.width
                label: "Ending behavior"
                value: root.draft ? root.draft.onEnd.mode : "restore"
                options: root.endModeOptions
                foreground: root.foreground
                accent: root.accent
                onChanged: function(value) { root.setEndMode(value) }
                Accessible.name: "Ending behavior"
              }

              Collapsible {
                width: parent.width
                shown: !!root.draft && root.draft.onEnd.mode === "actions"
                spacing: Style.spacing.rowGap

                Repeater {
                  id: endCards
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
                    errorText: root.cardErrors.end[index] || ""
                    foreground: root.foreground
                    accent: root.accent
                    urgent: root.urgent
                    onTypeChanged: function(type) { root.replaceAction(index, type, "end") }
                    onFieldChanged: function(key, value) { root.updateAction(index, key, value, "end") }
                    onTextStaged: function(key, value) { root.stageActionText(index, key, value, "end") }
                    onArgsStaged: function(text) { root.stageArgs(text, index, "end") }
                    onMoveRequested: function(delta) { root.moveAction(index, delta, "end") }
                    onRemoveRequested: root.removeAction(index, "end")
                  }
                }

                ChoicePicker {
                  id: addEndActionPicker
                  width: Math.min(Style.space(300), parent.width)
                  showLabel: false
                  leadingIcon: "󰐕"
                  value: ""
                  placeholderText: "Add end action"
                  options: root.actionTypeOptions
                  foreground: root.foreground
                  accent: root.accent
                  onChanged: function(value) {
                    root.addEndActionType = value
                    root.addAction("end")
                    addEndActionPicker.value = ""
                  }
                  Accessible.name: "Add end action"
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.rowGap
                ChoicePicker {
                  width: Math.min(Style.space(360), parent.width)
                  label: "Ends when"
                  value: root.draft && typeof root.draft.keepUntil === "object" ? "minutes" : "conditions"
                  options: root.keepUntilOptions
                  foreground: root.foreground
                  accent: root.accent
                  onChanged: function(value) { root.setKeepUntil(value) }
                  Accessible.name: "Ends when"
                }
                NumberField {
                  visible: !!root.draft && typeof root.draft.keepUntil === "object"
                  anchors.bottom: parent.bottom
                  label: "Minutes"
                  value: root.draft && typeof root.draft.keepUntil === "object" ? root.draft.keepUntil.minutes : 60
                  from: 1
                  to: 1440
                  stepSize: 5
                  foreground: root.foreground
                  accent: root.accent
                  onModified: function(value) { root.setKeepMinutes(value) }
                  Component.onCompleted: field.Accessible.name = "Minutes to keep the routine on"
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.cardErrors.routine !== ""
                width: parent.width
                text: root.cardErrors.routine
                color: root.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          Item { width: 1; height: Style.space(4) }
        }
      }

      PanelSeparator {
        id: footerRule
        width: parent.width
        foreground: root.foreground
      }

      // -------------------------------------------------------- footer
      Item {
        id: footer
        width: parent.width
        implicitHeight: footerRow.implicitHeight + (footerError.visible ? footerError.implicitHeight + Style.space(6) : 0)

        Column {
          anchors.fill: parent
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            id: footerError
            visible: root.displayedError() !== ""
            width: parent.width
            text: root.displayedError()
            color: root.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            id: footerRow
            width: parent.width
            spacing: Style.spacing.rowGap

            Button {
              id: saveButton
              text: root.busy ? "Saving…" : (root.persisted ? "Save" : "Save routine")
              iconText: root.busy ? "󰦖" : "󰆓"
              iconSpinning: root.busy
              bordered: true
              focusable: true
              active: root.dirty
              foreground: root.foreground
              accent: root.accent
              enabled: !root.busy && (root.dirty || !root.persisted)
              opacity: enabled ? 1 : 0.6
              onClicked: root.save()
              Accessible.role: Accessible.Button
              Accessible.name: "Save routine (Ctrl+S)"
              Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }

            Button {
              id: runButton
              text: root.dirty || !root.persisted ? "Save & " + root.runLabel.toLowerCase() : root.runLabel
              iconText: root.running ? "󰦖" : (root.stateful ? (root.isActive ? "󰓛" : "󰐊") : "󰐊")
              iconSpinning: root.running
              bordered: true
              focusable: true
              foreground: root.foreground
              accent: root.accent
              enabled: !root.busy && !root.running && !!root.draft
              opacity: enabled ? 1 : 0.6
              onClicked: root.runOrSave()
              Accessible.role: Accessible.Button
              Accessible.name: text
              Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }

            Item {
              width: Math.max(0, parent.width - saveButton.width - runButton.width - duplicateButton.width - deleteButton.width - parent.spacing * 4)
              height: 1
            }

            Button {
              id: duplicateButton
              text: "Duplicate"
              iconText: "󰆏"
              focusable: true
              foreground: root.foreground
              accent: root.accent
              enabled: !root.busy && root.persisted && !root.dirty && !!root.draft
              opacity: enabled ? 1 : 0.6
              onClicked: root.duplicateRequested(root.draft.id)
              Accessible.role: Accessible.Button
              Accessible.name: "Duplicate routine"
              Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
            Button {
              id: deleteButton
              text: "Delete"
              iconText: "󰩺"
              focusable: true
              foreground: root.urgent
              accent: root.accent
              enabled: !root.busy && root.persisted && !!root.draft
              opacity: enabled ? 1 : 0.6
              onClicked: root.deleteRequested(root.draft.id)
              Accessible.role: Accessible.Button
              Accessible.name: "Delete routine"
              Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
          }
        }
      }
    }
  }
}
