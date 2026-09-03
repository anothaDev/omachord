import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Conditions.js" as Conditions

Item {
  id: root

  // Injected by omarchy-shell when the property exists.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var service: null

  property bool closingFromHost: false
  property var status: ({ ok: true, connected: false, connectionEnabled: true, configValid: true })
  property var config: Model.defaultConfig()
  property string configRevision: "missing"
  property var bindings: []
  property var commands: []
  property var logs: []
  property var appOptions: []
  property var commandOptions: []
  property var themeOptions: []
  property var toggleOptions: []
  property var activeIds: ({})
  property var serviceStatus: null
  readonly property bool wifiAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiOptions: buildWifiOptions()
  readonly property var conditionRoutines: {
    var rows = []
    for (var i = 0; i < config.routines.length; i++)
      if (Model.hasConditions(config.routines[i])) rows.push(config.routines[i])
    return rows
  }
  readonly property var activeRows: buildActiveRows(activeIds, config)
  readonly property var eventRows: buildEventRows(config)
  readonly property var recentRuns: logs.slice(0, 12)
  property string activeView: "routines"
  property string selectedRoutineId: ""
  property var editorRoutine: null
  property bool editorPersisted: false
  property bool configLoaded: false
  property bool configUncommitted: false
  property bool loading: false
  property bool mutating: false
  property bool compactEditorOpen: false
  property string noticeText: ""
  property bool noticeError: false
  property string shownNotice: ""
  property string shortcutQuery: ""
  property string shortcutFilter: "all"
  property var pendingConfig: null
  property string pendingSelectId: ""
  property string pendingAfterApply: ""
  property string pendingPayload: ""
  property string mutationOperation: ""
  property string deleteRoutineId: ""
  property string confirmPurpose: ""
  property string pendingUiAction: ""
  property var pendingUiValue: null
  property bool configStarted: false
  property bool configHandled: false
  property bool applyStarted: false
  property bool mutationStarted: false
  property bool actionStarted: false
  property bool revisionRefreshPending: false
  property bool revisionStarted: false
  property string runningRoutineId: ""
  property date displayNow: new Date()

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: (manifest && manifest.id) || "anothadev.omachord"
  readonly property string configuredRunnerPath: Quickshell.env("OMACHORD_RUNNER_PATH")
  readonly property string runnerPath: configuredRunnerPath.indexOf("/") === 0
    ? configuredRunnerPath
    : (manifest && manifest.__sourceDir
      ? String(manifest.__sourceDir) + "/bin/omachord"
      : home + "/.config/omarchy/plugins/anothadev.omachord/bin/omachord")
  readonly property var filteredBindings: Model.filterBindings(bindings, shortcutQuery, shortcutFilter)
  readonly property bool compact: window.width < Style.space(920)
  readonly property bool uiLocked: loading || mutating || revisionRefreshPending || !configLoaded
  readonly property bool connectionNeedsRepair: status.ownedConnection === true && status.integrationComplete !== true
  readonly property bool integrationOn: status.integrationComplete === true
  readonly property bool serviceLive: !!service
  readonly property int activeCount: Object.keys(activeIds).length

  // The theme arrives live from omarchy-shell (applyTheme IPC); mirroring
  // it here lets every surface crossfade the way the bar does instead of
  // snapping. The success green comes from the theme's own palette.
  property color fg: Color.foreground
  property color bg: Color.background
  property color accent: Color.accent
  property color urgent: Color.urgent
  Behavior on fg { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on bg { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on accent { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on urgent { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  readonly property color enabledGreen: palette.success
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color subtle: Qt.darker(fg, 1.5)
  readonly property color hairline: Util.alpha(fg, 0.12)

  ThemePalette { id: palette }

  onCompactChanged: {
    if (compact && editorRoutine) compactEditorOpen = true
  }

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        var view = String(payload.view || "")
        if (view === "automations") view = "activity"
        if (["shortcuts", "routines", "activity"].indexOf(view) !== -1) setActiveView(view)
      } catch (e) {}
    }
    if (compact && editorRoutine && !editorPersisted) compactEditorOpen = true
    refreshApps()
    palette.reload()
    syncFromService()
    if (!configLoaded && !loading) refreshAll()
    else refreshSupplemental()
    Qt.callLater(function() {
      if (confirmDialog.opened) confirmKeyScope.forceActiveFocus()
      else focusScope.forceActiveFocus()
    })
  }

  function close() {
    routineEditor.stopShortcutCapture()
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    routineEditor.stopShortcutCapture()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else window.visible = false
  }

  function parseJson(text, fallback) {
    try { return JSON.parse(String(text || "")) } catch (e) { return fallback }
  }

  function setActiveView(view) {
    if (activeView === view) return
    routineEditor.stopShortcutCapture()
    activeView = view
  }

  function startProcess(process) {
    if (process.running) return false
    process.running = true
    return true
  }

  function requestRefreshProcess(process) {
    if (process.running) {
      process.refreshQueued = true
      return false
    }
    process.refreshQueued = false
    if (process === togglesProc) togglesProc.startPending = true
    process.running = true
    return true
  }

  function finishRefreshProcess(process) {
    if (!process.refreshQueued) return
    process.refreshQueued = false
    Qt.callLater(function() {
      if (process.running) process.refreshQueued = true
      else {
        if (process === togglesProc) togglesProc.startPending = true
        process.running = true
      }
    })
  }

  function refreshAll() {
    if (loading || mutating || configProc.running) return
    configLoaded = false
    configUncommitted = false
    loading = true
    configStarted = false
    configHandled = false
    startProcess(configProc)
    refreshSupplemental()
  }

  function refreshSupplemental() {
    requestRefreshProcess(statusProc)
    requestRefreshProcess(bindingsProc)
    requestRefreshProcess(commandsProc)
    requestRefreshProcess(logsProc)
    requestRefreshProcess(themesProc)
    requestRefreshProcess(togglesProc)
    if (serviceLive) syncFromService()
    else {
      requestRefreshProcess(activeProc)
      requestRefreshProcess(serviceStatusProc)
    }
  }

  // The condition service runs in this same shell and already watches every
  // state file; mirroring it keeps the window live without polling.
  function syncFromService() {
    if (!service) return
    if (service.active && typeof service.active === "object") rebuildActiveIds(objectValues(service.active))
    if (typeof service.statusJson === "function") serviceStatus = parseJson(service.statusJson(), null)
  }

  function objectValues(map) {
    var rows = []
    for (var key in map) rows.push(map[key])
    return rows
  }

  // Names only: WifiNetwork objects churn with NetworkManager scans, so the
  // picker never keeps a reference to one.
  function buildWifiOptions() {
    var rows = []
    if (!wifiAvailable) return rows
    var seen = ({})
    var devices = networkDevices || []
    for (var d = 0; d < devices.length; d++) {
      var device = devices[d]
      if (!device || device.type !== DeviceType.Wifi || !device.networks) continue
      var networks = device.networks.values || []
      for (var n = 0; n < networks.length; n++) {
        var network = networks[n]
        var name = network ? String(network.name || "") : ""
        if (!name || seen[name]) continue
        seen[name] = true
        rows.push({
          value: name,
          label: name,
          description: network.connected ? "Connected" : (network.known ? "Known network" : "In range"),
          rank: network.connected ? 0 : (network.known ? 1 : 2)
        })
      }
    }
    rows.sort(function(left, right) {
      if (left.rank !== right.rank) return left.rank - right.rank
      return left.label.toLowerCase().localeCompare(right.label.toLowerCase())
    })
    return rows
  }

  function rebuildToggleOptions(names) {
    var rows = []
    if (Array.isArray(names)) {
      for (var i = 0; i < names.length; i++) {
        var name = String(names[i])
        rows.push({ value: name, label: name, description: "Currently on" })
      }
    }
    rows.sort(function(left, right) { return left.label.localeCompare(right.label) })
    toggleOptions = rows
  }

  function serviceInputsText() {
    var current = serviceStatus
    if (!current) return "The condition service has not reported yet. It runs inside omarchy-shell once the plugin is enabled."
    var parts = []
    parts.push(current.enabled ? "Evaluating conditions" : "Paused: " + (current.reason || "Omachord is off"))
    if (current.env) {
      parts.push("Wi-Fi " + (current.env.wifiAvailable === false ? "unavailable" : (current.env.ssid || "not connected")))
      parts.push((current.env.onBattery ? "On battery" : "Plugged in")
        + (typeof current.env.batteryPercent === "number" && current.env.batteryPercent >= 0 ? " " + current.env.batteryPercent + "%" : ""))
      var toggles = Array.isArray(current.env.toggles) ? current.env.toggles : []
      if (toggles.length) parts.push("Toggles on: " + toggles.join(", "))
    }
    return parts.join(" · ")
  }

  function serviceRoutineState(id) {
    var current = serviceStatus
    if (!current || !Array.isArray(current.routines)) return null
    for (var i = 0; i < current.routines.length; i++)
      if (current.routines[i] && current.routines[i].id === id) return current.routines[i]
    return null
  }

  // Why a condition routine is not on right now, in the user's words.
  function conditionReason(routine, state) {
    if (!routine.enabled) return { label: "Off", detail: "Turn the routine on to let its conditions start it.", urgent: false }
    if (!integrationOn || (serviceStatus && serviceStatus.enabled === false))
      return { label: "Not evaluated", detail: "Conditions are evaluated only while Omachord is on.", urgent: false }
    if (!state) return { label: "Not evaluated", detail: "The condition service has not reported yet.", urgent: false }
    if (state.failure && state.failure.op) {
      var retry = state.failure.retryAt ? Conditions.clockTime(new Date(Number(state.failure.retryAt)).toISOString()) : ""
      return { label: "Failed", detail: (state.failure.op === "activate" ? "Could not start: " : "Could not end: ")
        + (state.failure.error || "runner error") + (retry ? " · retrying " + retry : ""), urgent: true }
    }
    if (state.matched === true && state.latched) return { label: "Ended by hand", detail: "Starts again once its conditions have been false at least once.", urgent: false }
    if (state.matched === true) return { label: "Matched", detail: "Starting shortly.", urgent: false }
    var waiting = []
    var details = Array.isArray(state.details) ? state.details : []
    for (var i = 0; i < details.length; i++) {
      var item = details[i]
      if (item && item.matched === false) waiting.push(item.summary + (item.state ? " (" + item.state + ")" : ""))
    }
    return { label: "Waiting", detail: waiting.length ? "Waiting for " + waiting.join(", ") : "Waiting for its conditions.", urgent: false }
  }

  function buildActiveRows(active, currentConfig) {
    var rows = []
    for (var id in active) {
      var record = active[id] || {}
      rows.push({
        id: id,
        name: Model.nameFor(currentConfig, id),
        activatedAt: String(record.activatedAt || ""),
        trigger: String(record.trigger || ""),
        expiresAt: record.expiresAt ? String(record.expiresAt) : "",
        onEndMode: String(record.onEndMode || "restore"),
        setterCount: Number(record.setterCount || 0),
        conditions: Model.hasConditions(routineById(id)) ? routineById(id).conditions.length : 0
      })
    }
    rows.sort(function(left, right) { return left.activatedAt.localeCompare(right.activatedAt) })
    return rows
  }

  function buildEventRows(currentConfig) {
    var rows = []
    for (var i = 0; i < Model.HOOKS.length; i++) {
      var hook = Model.HOOKS[i]
      var attached = routinesForHook(hook.value)
      if (attached.length) rows.push({ hook: hook, routines: attached })
    }
    return rows
  }

  function activeMeta(row) {
    var parts = []
    var since = Conditions.clockTime(row.activatedAt)
    var started = Model.triggerLabel(row.trigger)
    if (since) parts.push("Since " + since + (started ? " " + started : ""))
    else if (started) parts.push("Started " + started)
    if (row.expiresAt) {
      var left = Conditions.minutesLeft(row.expiresAt, displayNow)
      parts.push(left !== null && left >= 0 ? (left < 1 ? "ending now" : left + " min left") : "until " + Conditions.clockTime(row.expiresAt))
    } else if (row.conditions > 0) parts.push("while its conditions hold")
    return parts.join(" · ")
  }

  function activeEnding(row) {
    if (row.onEndMode === "none") return "Leaves settings as they are"
    var count = Number(row.setterCount || 0)
    if (count > 0) return "Restores " + count + (count === 1 ? " setting" : " settings")
    return row.onEndMode === "actions" ? "Runs its end actions" : ""
  }

  function requestRefresh() {
    if (loading || mutating) return
    // A draft stays in place: the list and revision refresh underneath it.
    if (routineEditor.dirty) {
      refreshSupplemental()
      revisionRefreshPending = true
      revisionStarted = false
      mutating = true
      requestRefreshProcess(revisionProc)
      return
    }
    refreshAll()
  }

  function failConfigLoad(message) {
    if (configHandled) return
    configHandled = true
    loading = false
    configLoaded = false
    showNotice(message || "Could not load the routine configuration", true)
  }

  function handleConfigResult(text, errorText, exitCode) {
    if (configHandled) return
    var parsed = parseJson(text, null)
    if (exitCode !== 0) {
      failConfigLoad((parsed && parsed.ok === false && parsed.error)
        || errorText || "Configuration loading exited " + exitCode)
      return
    }
    if (parsed && parsed.ok && parsed.committed === true
        && parsed.config && parsed.config.version === 1
        && typeof parsed.revision === "string") {
      configHandled = true
      config = parsed.config
      configRevision = parsed.revision
      ensureRoutineSelection()
      loading = false
      configLoaded = true
      if (noticeError && (noticeText.indexOf("Could not load") === 0
          || noticeText.indexOf("The routine configuration is not committed") === 0))
        clearNotice()
    } else if (parsed && parsed.ok && parsed.committed === false) {
      // A connected install from before the commit record existed lands here.
      // Keep the revision so Enable/Repair can commit exactly this file.
      if (typeof parsed.revision === "string") configRevision = parsed.revision
      configUncommitted = true
      failConfigLoad("The routine configuration is not committed and was not loaded. Choose "
        + (connectionNeedsRepair || status.connected ? "Repair" : "Enable") + " to commit it.")
    } else if (parsed && parsed.error) failConfigLoad(parsed.error)
    else failConfigLoad("The runner returned invalid configuration JSON")
  }

  function refreshApps() {
    var values = DesktopEntries.applications.values || []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || entry.noDisplay || !entry.id) continue
      rows.push({
        value: String(entry.id),
        label: String(entry.name || entry.id),
        description: String(entry.genericName || entry.comment || entry.id)
      })
    }
    rows.sort(function(left, right) {
      return left.label.toLowerCase().localeCompare(right.label.toLowerCase())
    })
    appOptions = rows
  }

  function rebuildCommandOptions() {
    var rows = []
    for (var i = 0; i < commands.length; i++) {
      rows.push({
        value: commands[i].route,
        label: commands[i].route,
        description: commands[i].summary || commands[i].args || ""
      })
    }
    commandOptions = rows
  }

  function routineById(id) {
    for (var i = 0; i < config.routines.length; i++)
      if (config.routines[i].id === id) return config.routines[i]
    return null
  }

  function selectRoutineNow(id, showEditor) {
    var routine = routineById(id)
    selectedRoutineId = routine ? id : ""
    editorPersisted = !!routine
    editorRoutine = routine ? Model.clone(routine) : null
    if (showEditor !== false && routine) compactEditorOpen = true
    setActiveView("routines")
  }

  function selectDraftNow(routine) {
    selectedRoutineId = routine.id
    editorPersisted = false
    editorRoutine = Model.clone(routine)
    compactEditorOpen = true
    setActiveView("routines")
  }

  function requestSelectRoutine(id) {
    if (editorRoutine && editorRoutine.id === id) {
      setActiveView("routines")
      compactEditorOpen = true
      return
    }
    requestDraftReplacement("routine", id)
  }

  function requestSelectDraft(routine) {
    if (!routine) return
    requestDraftReplacement("draft", routine)
  }

  function requestDraftReplacement(action, value) {
    if (mutating || (action !== "refresh" && !configLoaded)) return
    if (routineEditor.dirty) {
      pendingUiAction = action
      pendingUiValue = value
      showConfirmation(
        "discard",
        "Discard the unsaved changes to this routine? This cannot be undone.",
        "Discard")
      return
    }
    performUiAction(action, value)
  }

  function performUiAction(action, value) {
    routineEditor.stopShortcutCapture()
    if (action === "routine") selectRoutineNow(String(value), true)
    else if (action === "draft") selectDraftNow(value)
    else if (action === "enabled") setRoutineEnabled(String(value.id), value.enabled === true)
    else if (action === "refresh") refreshAll()
    else if (action === "back") {
      selectedRoutineId = ""
      editorPersisted = false
      editorRoutine = null
      compactEditorOpen = false
    }
  }

  function requestEditorBack() {
    routineEditor.stopShortcutCapture()
    if (!editorPersisted) requestDraftReplacement("back", null)
    else compactEditorOpen = false
  }

  function showConfirmation(purpose, message, confirmText) {
    routineEditor.stopShortcutCapture()
    confirmPurpose = purpose
    confirmDialog.message = message
    confirmDialog.confirmText = confirmText
    confirmDialog.cancelText = "Cancel"
    confirmDialog.selectedIndex = 0
    confirmDialog.opened = true
    Qt.callLater(function() { confirmKeyScope.forceActiveFocus() })
  }

  function ensureRoutineSelection() {
    if (selectedRoutineId) {
      var selected = routineById(selectedRoutineId)
      if (selected) {
        editorPersisted = true
        editorRoutine = Model.clone(selected)
        return
      }
    }
    if (config.routines.length > 0) selectRoutineNow(config.routines[0].id, false)
    else {
      selectedRoutineId = ""
      editorPersisted = false
      editorRoutine = null
      compactEditorOpen = false
    }
  }

  function applyConfig(next, selectId, afterApply) {
    if (mutating || loading || !configLoaded) return
    pendingConfig = Model.clone(next)
    pendingSelectId = selectId || ""
    pendingAfterApply = afterApply || ""
    pendingPayload = JSON.stringify(next)
    mutating = true
    mutationOperation = "apply"
    applyStarted = false
    clearNotice()
    applyProc.command = [runnerPath, "config", "apply", configRevision]
    startProcess(applyProc)
  }

  function handleApplyResult(text, errorText, exitCode) {
    if (!mutating || mutationOperation !== "apply") return
    var fallback = errorText || (exitCode === 0
      ? "The runner returned invalid JSON"
      : "The runner could not save the configuration")
    var parsed = parseJson(text, null)
    var result = exitCode === 0
      ? (parsed || { ok: false, error: fallback })
      : (parsed && parsed.ok === false ? parsed : { ok: false, error: fallback })
    if (result.ok && typeof result.revision !== "string")
      result = { ok: false, error: "The runner returned an invalid revision" }
    mutating = false
    mutationOperation = ""
    applyStarted = false
    pendingPayload = ""
    if (!result.ok) {
      pendingDuplicateName = ""
      pendingConfig = null
      pendingSelectId = ""
      pendingAfterApply = ""
      // Someone else saved first. Pick up the new revision and list without
      // touching the open draft, so the next Save applies it to the new base.
      if (result.code === "stale-config") {
        showNotice("The configuration changed elsewhere. Refreshing the list and revision...", true)
        mutating = true
        revisionRefreshPending = true
        revisionStarted = false
        requestRefreshProcess(revisionProc)
        routineEditor.externalError = noticeText
        return
      }
      routineEditor.externalError = result.error || "Could not save configuration"
      return
    }
    config = pendingConfig || config
    configRevision = result.revision
    var selectId = pendingSelectId
    pendingConfig = null
    pendingSelectId = ""
    var ended = result.deactivated && result.deactivated.length
      ? result.deactivated.map(function(id) { return Model.nameFor(config, id) }).join(", ") : ""
    var duplicateName = pendingDuplicateName
    pendingDuplicateName = ""
    showNotice(result.warnings && result.warnings.length
      ? result.warnings.join(" ")
      : (duplicateName ? "\"" + duplicateName + "\" created and left off; turn it on when it is ready."
        : (ended ? "Saved. Ended " + ended + "." : "Saved")), false)
    if (selectId) selectRoutineNow(selectId, true)
    else ensureRoutineSelection()
    requestRefreshProcess(bindingsProc)
    requestRefreshProcess(logsProc)
    requestRefreshProcess(statusProc)
    if (!serviceLive) requestRefreshProcess(activeProc)
    if (pendingAfterApply === "run" && selectId) runRoutine(selectId)
    pendingAfterApply = ""
  }

  function saveRoutine(routine) {
    applyConfig(Model.replaceRoutine(config, routine), routine.id, "")
  }

  function saveAndRun(routine) {
    applyConfig(Model.replaceRoutine(config, routine), routine.id, "run")
  }

  function requestSetRoutineEnabled(id, enabled) {
    if (routineEditor.dirty) {
      pendingUiAction = "enabled"
      pendingUiValue = ({ id: id, enabled: enabled === true })
      showConfirmation(
        "discard",
        "Discard the unsaved changes before turning this routine " + (enabled ? "on" : "off") + "?",
        "Discard and continue")
      return
    }
    setRoutineEnabled(id, enabled)
  }

  // The list switch saves immediately once no open draft is at risk.
  function setRoutineEnabled(id, enabled) {
    var routine = routineById(id)
    if (!routine || mutating || !configLoaded) return
    var next = Model.clone(routine)
    next.enabled = enabled === true
    applyConfig(Model.replaceRoutine(config, next), "", "")
  }

  function duplicateRoutine(id) {
    if (!configLoaded || routineEditor.dirty) return
    var result = Model.duplicateRoutine(config, id)
    if (result.routine) {
      applyConfig(result.config, result.routine.id, "")
      pendingDuplicateName = result.routine.name
    }
  }
  property string pendingDuplicateName: ""

  function requestDelete(id) {
    if (!editorPersisted || mutating) return
    deleteRoutineId = id
    showConfirmation(
      "delete",
      "Delete \"" + Model.nameFor(config, id) + "\"? Its shortcut and event triggers are removed too, including unsaved edits.",
      "Delete")
  }

  function deleteSelectedRoutine() {
    var next = Model.removeRoutine(config, deleteRoutineId)
    deleteRoutineId = ""
    applyConfig(next, next.routines.length ? next.routines[0].id : "", "")
  }

  function runRoutine(id) {
    if (actionProc.running || !id || !configLoaded || !editorPersisted) return
    runningRoutineId = id
    showNotice((activeIds[id] ? "Ending " : "Running ") + Model.nameFor(config, id) + "...", false, true)
    actionProc.command = [runnerPath, "run", id, "test"]
    actionStarted = false
    startProcess(actionProc)
  }

  // Ending from the Activity list goes through the service when it is loaded
  // (the same path the bar widget uses); otherwise the runner directly.
  function endRoutine(id) {
    if (!id || !activeIds[id]) return
    if (service && typeof service.endRoutine === "function") {
      showNotice("Ending " + Model.nameFor(config, id) + "...", false, true)
      service.endRoutine(id)
      return
    }
    if (actionProc.running) return
    runningRoutineId = id
    showNotice("Ending " + Model.nameFor(config, id) + "...", false, true)
    actionProc.command = [runnerPath, "deactivate", id, "manual"]
    actionStarted = false
    startProcess(actionProc)
  }

  function mutateConnection(operation) {
    if (mutating || loading || !(configLoaded || configUncommitted)) return
    mutationOperation = operation
    mutating = true
    mutationStarted = false
    showNotice(operation === "connect" ? "Turning Omachord on..." : "Turning Omachord off...", false, true)
    mutationProc.command = operation === "connect"
      ? [runnerPath, operation, configRevision]
      : [runnerPath, operation]
    startProcess(mutationProc)
  }

  function requestIntegrationToggle() {
    if (connectionNeedsRepair) mutateConnection("connect")
    else if (integrationOn) {
      showConfirmation(
        "disconnect",
        "Turn Omachord off? Active routines end and restore. Saved routines stay; shortcuts, events, and conditions pause until you turn it on again.",
        "Turn off")
    } else mutateConnection("connect")
  }

  function createFromBinding(binding) {
    if (!configLoaded || mutating || binding.managed || binding.editable === false) return
    var routine = Model.blankRoutine(config.routines)
    var description = String(binding.description || "").trim() || "New routine"
    routine.name = Model.truncateCodePoints(description, 100)
    routine.id = Model.uniqueId(routine.name, config.routines)
    routine = Model.setShortcut(routine, binding.keys, true)
    requestSelectDraft(routine)
  }

  function routinesForHook(event) {
    var rows = []
    for (var i = 0; i < config.routines.length; i++) {
      var hooks = Model.hookValues(config.routines[i])
      if (hooks.indexOf(event) !== -1) rows.push(config.routines[i])
    }
    return rows
  }

  function lastRunFor(id) {
    for (var i = 0; i < logs.length; i++)
      if (logs[i].routineId === id) return logs[i]
    return null
  }

  function handleMutationResult(text, errorText, exitCode) {
    if (!mutating || (mutationOperation !== "connect" && mutationOperation !== "disconnect")) return
    var operation = mutationOperation
    var fallback = errorText || (exitCode === 0
      ? "The runner returned invalid JSON"
      : "The connection change could not start or complete")
    var parsed = parseJson(text, null)
    var result = exitCode === 0
      ? (parsed || { ok: false, error: fallback })
      : (parsed && parsed.ok === false ? parsed : { ok: false, error: fallback })
    mutating = false
    mutationStarted = false
    mutationOperation = ""
    showNotice(result.ok
      ? (operation === "connect" ? "Omachord is on" : "Omachord is off")
      : (result.error || "Connection change failed"), !result.ok)
    if (result.ok && typeof result.revision === "string") configRevision = result.revision
    // Only a config that never loaded (uncommitted until this Enable/Repair)
    // is reloaded in full; otherwise keep the editor draft the user has open.
    if (result.ok && !configLoaded) {
      refreshAll()
      return
    }
    requestRefreshProcess(statusProc)
    requestRefreshProcess(bindingsProc)
    requestRefreshProcess(logsProc)
    if (!serviceLive) requestRefreshProcess(activeProc)
  }

  function handleActionResult(text, errorText, exitCode) {
    var fallback = errorText || (exitCode === 0
      ? "The routine returned invalid JSON"
      : "The routine runner could not start or complete")
    var parsed = parseJson(text, null)
    var result = exitCode === 0
      ? (parsed || { ok: false, error: fallback })
      : (parsed && parsed.ok === false ? parsed : { ok: false, error: fallback })
    actionStarted = false
    var name = Model.nameFor(config, runningRoutineId)
    runningRoutineId = ""
    showNotice(result.ok ? actionNotice(result, name) : (result.error || "Routine failed"), !result.ok)
    requestRefreshProcess(logsProc)
    if (!serviceLive) requestRefreshProcess(activeProc)
  }

  function actionNotice(result, name) {
    if (result.alreadyActive) return name + " is already on"
    if (result.alreadyInactive) return name + " was not on"
    if (result.state === "activated") return name + " is on"
    if (result.state === "deactivated")
      return name + " ended. Restored " + result.restored
        + (result.skipped ? ", kept " + result.skipped + " you changed yourself" : "") + "."
    return name + " ran"
  }

  function rebuildActiveIds(rows) {
    var next = ({})
    for (var i = 0; i < rows.length; i++)
      if (rows[i] && rows[i].routineId) next[String(rows[i].routineId)] = rows[i]
    activeIds = next
  }

  function handleRevisionResult(text, errorText, exitCode) {
    if (!revisionRefreshPending) return
    revisionRefreshPending = false
    revisionStarted = false
    mutating = false
    var parsed = exitCode === 0 ? parseJson(text, null) : null
    if (parsed && parsed.ok && parsed.committed === true && parsed.config
        && parsed.config.version === 1 && typeof parsed.revision === "string") {
      var changed = parsed.revision !== configRevision
      config = parsed.config
      configRevision = parsed.revision
      if (changed) {
        showNotice("The configuration changed elsewhere. The list and revision were refreshed; save again to apply this draft.", true)
        routineEditor.externalError = noticeText
      }
    } else {
      showNotice("The configuration changed elsewhere, but its latest revision could not be loaded. Use Refresh before saving again."
        + (errorText ? " " + errorText : ""), true)
      routineEditor.externalError = noticeText
    }
  }

  function rebuildThemeOptions(text) {
    var lines = String(text || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (!name) continue
      var value = Model.themeSlug(name)
      if (value) rows.push({ value: value, label: name })
    }
    themeOptions = rows
  }

  // Info notices fade out on their own; errors stay until the next change.
  function showNotice(text, isError, sticky) {
    noticeError = isError === true
    noticeText = String(text || "")
    noticeExpiry.stop()
    if (noticeText && !noticeError && !sticky) noticeExpiry.restart()
  }

  function clearNotice() {
    noticeExpiry.stop()
    noticeText = ""
    noticeError = false
  }

  Timer {
    id: noticeExpiry
    interval: 4000
    repeat: false
    onTriggered: if (!root.noticeError) root.noticeText = ""
  }

  Timer {
    interval: 60000
    repeat: true
    running: window.visible
    onRunningChanged: if (running) root.displayNow = new Date()
    onTriggered: root.displayNow = new Date()
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshApps() }
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onActiveChanged() { root.syncFromService() }
    function onLastEventChanged() { root.syncFromService() }
    function onEnabledChanged() {
      root.syncFromService()
      root.requestRefreshProcess(statusProc)
    }
    function onManualFinished(job, result) {
      var name = Model.nameFor(root.config, job.id)
      if (result && result.ok) root.showNotice(root.actionNotice(result, name), false)
      else root.showNotice((result && result.error) || (name + " could not be ended"), true)
      root.requestRefreshProcess(logsProc)
    }
    function onConfigRevisionChanged() {
      if (!root.configLoaded || root.mutating || root.loading) return
      if (!root.service.configRevision || root.service.configRevision === root.configRevision) return
      if (routineEditor.dirty) root.showNotice("The configuration changed elsewhere. Refresh to load it; saving applies this draft to the new version.", false, true)
      else root.refreshAll()
    }
  }

  Process {
    id: statusProc
    property bool refreshQueued: false
    command: [root.runnerPath, "status"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = root.parseJson(statusStdout.text, null)
        if (parsed && parsed.ok) root.status = parsed
      }
      root.finishRefreshProcess(statusProc)
    }
  }

  Process {
    id: configProc
    command: [root.runnerPath, "config", "snapshot"]
    stdout: StdioCollector {
      id: configStdout
      waitForEnd: true
    }
    stderr: StdioCollector { id: configStderr; waitForEnd: true }
    onStarted: root.configStarted = true
    onExited: function(exitCode) {
      root.handleConfigResult(configStdout.text, configStderr.text.trim(), exitCode)
    }
    onRunningChanged: {
      if (!running && root.loading && !root.configStarted && !root.configHandled)
        Qt.callLater(function() { root.failConfigLoad("Could not start the Omachord runner") })
    }
  }

  Process {
    id: bindingsProc
    property bool refreshQueued: false
    command: [root.runnerPath, "bindings"]
    stdout: StdioCollector { id: bindingsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = root.parseJson(bindingsStdout.text, null)
        if (Array.isArray(parsed)) root.bindings = parsed
      }
      root.finishRefreshProcess(bindingsProc)
    }
  }

  Process {
    id: commandsProc
    property bool refreshQueued: false
    command: [root.runnerPath, "commands"]
    stdout: StdioCollector { id: commandsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = root.parseJson(commandsStdout.text, null)
        if (Array.isArray(parsed)) {
          root.commands = parsed
          root.rebuildCommandOptions()
        }
      }
      root.finishRefreshProcess(commandsProc)
    }
  }

  // Refreshes the routine list and CAS revision while leaving the editor
  // draft in place; used after a stale-revision save and by Refresh.
  Process {
    id: revisionProc
    property bool refreshQueued: false
    command: [root.runnerPath, "config", "snapshot"]
    stdout: StdioCollector { id: revisionStdout; waitForEnd: true }
    stderr: StdioCollector { id: revisionStderr; waitForEnd: true }
    onStarted: root.revisionStarted = true
    onExited: function(exitCode) {
      root.handleRevisionResult(revisionStdout.text, revisionStderr.text.trim(), exitCode)
      root.finishRefreshProcess(revisionProc)
    }
    onRunningChanged: {
      if (!running && root.revisionRefreshPending && !root.revisionStarted)
        Qt.callLater(function() {
          if (root.revisionRefreshPending && !revisionProc.running)
            root.handleRevisionResult("", "Could not start the Omachord runner", -1)
        })
    }
  }

  Process {
    id: activeProc
    property bool refreshQueued: false
    command: [root.runnerPath, "active"]
    stdout: StdioCollector { id: activeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = root.parseJson(activeStdout.text, null)
        if (Array.isArray(parsed)) root.rebuildActiveIds(parsed)
      }
      root.finishRefreshProcess(activeProc)
    }
  }

  Process {
    id: themesProc
    property bool refreshQueued: false
    command: ["omarchy-theme-list"]
    stdout: StdioCollector { id: themesStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.rebuildThemeOptions(themesStdout.text)
      root.finishRefreshProcess(themesProc)
    }
  }

  Process {
    id: togglesProc
    property bool refreshQueued: false
    property bool startPending: false
    command: [root.runnerPath, "toggles"]
    stdout: StdioCollector { id: togglesStdout; waitForEnd: true }
    onStarted: startPending = false
    onExited: function(exitCode) {
      startPending = false
      root.rebuildToggleOptions(exitCode === 0 ? root.parseJson(togglesStdout.text, null) : null)
      root.finishRefreshProcess(togglesProc)
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() {
        if (!togglesProc.running && togglesProc.startPending) {
          togglesProc.startPending = false
          root.rebuildToggleOptions(null)
          root.finishRefreshProcess(togglesProc)
        }
      })
  }

  Process {
    id: serviceStatusProc
    property bool refreshQueued: false
    command: ["omarchy-shell", "omachord", "status"]
    stdout: StdioCollector { id: serviceStatusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.serviceStatus = exitCode === 0 ? root.parseJson(serviceStatusStdout.text, null) : null
      root.finishRefreshProcess(serviceStatusProc)
    }
  }

  Process {
    id: logsProc
    property bool refreshQueued: false
    command: [root.runnerPath, "logs", "100"]
    stdout: StdioCollector { id: logsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = root.parseJson(logsStdout.text, null)
        if (Array.isArray(parsed)) root.logs = parsed
      }
      root.finishRefreshProcess(logsProc)
    }
  }

  Process {
    id: applyProc
    stdinEnabled: true
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onStarted: {
      root.applyStarted = true
      write(root.pendingPayload + "\n")
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      stdinEnabled = true
      root.handleApplyResult(applyStdout.text, applyStderr.text.trim(), exitCode)
    }
    onRunningChanged: {
      if (!running) stdinEnabled = true
      if (!running && root.mutating && root.mutationOperation === "apply" && !root.applyStarted)
        Qt.callLater(function() {
          root.handleApplyResult("", "Could not start the Omachord runner", -1)
        })
    }
  }

  Process {
    id: mutationProc
    stdout: StdioCollector { id: mutationStdout; waitForEnd: true }
    stderr: StdioCollector { id: mutationStderr; waitForEnd: true }
    onStarted: root.mutationStarted = true
    onExited: function(exitCode) {
      root.handleMutationResult(mutationStdout.text, mutationStderr.text.trim(), exitCode)
    }
    onRunningChanged: {
      if (!running && root.mutating
          && (root.mutationOperation === "connect" || root.mutationOperation === "disconnect")
          && !root.mutationStarted)
        Qt.callLater(function() {
          root.handleMutationResult("", "Could not start the Omachord runner", -1)
        })
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onStarted: root.actionStarted = true
    onExited: function(exitCode) {
      root.handleActionResult(actionStdout.text, actionStderr.text.trim(), exitCode)
    }
    onRunningChanged: {
      if (!running && !root.actionStarted && root.runningRoutineId !== "")
        Qt.callLater(function() {
          root.handleActionResult("", "Could not start the Omachord runner", -1)
        })
    }
  }

  FloatingWindow {
    id: window
    visible: false
    title: "Omachord"
    color: root.bg
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(640, 480)

    onVisibleChanged: {
      if (!visible) routineEditor.stopShortcutCapture()
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      function editingText() {
        var item = window.activeFocusItem
        return !!item && item !== focusScope
          && (item instanceof TextInput || item instanceof TextEdit)
      }

      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        if (confirmDialog.opened) {
          // The key that opened a modal can still bubble here before the
          // modal focus handoff. Consume it without confirming the dialog.
          event.accepted = true
          return
        }
        var control = event.modifiers & Qt.ControlModifier
        if (control && event.key === Qt.Key_S) {
          if (root.activeView === "routines" && routineEditor.draft && !root.uiLocked) routineEditor.save()
          event.accepted = true
        } else if (control && event.key === Qt.Key_R) {
          root.requestRefresh()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          // Esc leaves a text field first; a second Esc closes the window.
          if (focusScope.editingText()) focusScope.forceActiveFocus()
          else root.requestClose()
          event.accepted = true
        }
      }

      Row {
        anchors.fill: parent

        // ------------------------------------------------------- sidebar
        Item {
          id: navigation
          width: root.compact ? Style.space(120) : Style.space(224)
          height: parent.height
          Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

          Rectangle {
            anchors.fill: parent
            color: Util.alpha(root.fg, 0.025)
          }

          Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: root.hairline
          }

          Column {
            anchors.fill: parent
            anchors.margins: Style.spacing.panelPadding
            anchors.rightMargin: Style.spacing.panelPadding + 1
            spacing: Style.space(16)

            PanelHero {
              id: hero
              width: parent.width
              title: root.compact ? "" : "Omachord"
              meta: root.compact ? "" : root.connectionNeedsRepair ? "Repair needed"
                : (root.integrationOn ? (root.activeCount ? root.activeCount + " on" : "On")
                  : (root.status.connectionEnabled === false ? "Off" : "Starting"))
              foreground: root.fg
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󰘮"
                  color: root.fg
                  opacity: root.integrationOn ? 1 : 0.5
                  font.family: Style.font.family
                  font.pixelSize: Style.font.display
                  Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  checked: root.integrationOn
                  busy: root.mutating && (root.mutationOperation === "connect" || root.mutationOperation === "disconnect")
                  interactive: (root.configLoaded || root.configUncommitted) && !root.loading && !root.mutating
                  foreground: root.fg
                  accent: root.accent
                  activeFocusOnTab: true
                  Keys.onReturnPressed: root.requestIntegrationToggle()
                  Keys.onEnterPressed: root.requestIntegrationToggle()
                  Keys.onSpacePressed: root.requestIntegrationToggle()
                  onToggled: root.requestIntegrationToggle()
                  Accessible.role: Accessible.CheckBox
                  Accessible.name: root.integrationOn ? "Turn Omachord off" : "Turn Omachord on"
                  Accessible.checkable: true
                  Accessible.checked: checked
                  Accessible.onPressAction: root.requestIntegrationToggle()
                  PanelToolTip {
                    visible: parent.containsMouse
                    text: root.connectionNeedsRepair ? "Repair the Omarchy integration"
                      : (root.integrationOn ? "Turn Omachord off. Active routines end and restore; saved routines stay."
                        : "Turn Omachord on")
                  }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: [
                  { id: "routines", glyph: "󰐐", label: "Routines" },
                  { id: "shortcuts", glyph: "󰌌", label: "Shortcuts" },
                  { id: "activity", glyph: "󰅐", label: "Activity" }
                ]

                Button {
                  id: navigationButton
                  required property var modelData
                  width: parent.width
                  implicitHeight: Math.max(Style.spacing.controlHeight,
                    navigationCopy.implicitHeight + verticalPadding * 2)
                  iconText: ""
                  text: ""
                  tooltipText: root.compact ? modelData.label : ""
                  focusable: true
                  foreground: root.fg
                  accent: root.accent
                  enabled: !root.mutating
                  active: root.activeView === modelData.id
                  onClicked: root.setActiveView(modelData.id)
                  Accessible.name: modelData.label
                  Accessible.role: Accessible.Button

                  // Button's own copy swaps left/center anchors when compact
                  // changes. The host restores window geometry after opening,
                  // and that anchor swap can remain stale until a resize.
                  Row {
                    id: navigationCopy
                    z: 2
                    width: implicitWidth
                    x: root.compact
                      ? Math.round((navigationButton.width - width) / 2)
                      : navigationButton.horizontalPadding
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.controlGap

                    Text {
                      textFormat: Text.PlainText
                      text: navigationButton.modelData.glyph
                      color: root.fg
                      font.family: navigationButton.fontFamily
                      font.pixelSize: navigationButton.iconSize
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: !root.compact
                      text: navigationButton.modelData.label
                      color: root.fg
                      font.family: navigationButton.fontFamily
                      font.pixelSize: navigationButton.fontSize
                      font.bold: navigationButton.active
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            Collapsible {
              width: parent.width
              shown: root.connectionNeedsRepair
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "An owned integration file is missing. Saving stays safe; repair before relying on shortcuts or events."
                color: root.subtle
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                width: parent.width
                text: "Repair"
                bordered: true
                focusable: true
                foreground: root.fg
                accent: root.accent
                enabled: (root.configLoaded || root.configUncommitted) && !root.loading && !root.mutating
                onClicked: root.mutateConnection("connect")
                Accessible.name: "Repair Omachord integration"
                Accessible.role: Accessible.Button
              }
            }

            Item { width: 1; height: Math.max(0, parent.height - y - themeCaption.height - parent.spacing) }

            Column {
              id: themeCaption
              width: parent.width
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                visible: palette.themeName !== ""
                width: parent.width
                text: palette.themeName.toUpperCase()
                color: root.subtle
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.compact ? "ESC" : "ESC CLOSES · CTRL+S SAVES"
                color: Qt.darker(root.fg, 1.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                elide: Text.ElideRight
              }
            }
          }
        }

        // ------------------------------------------------------- content
        Item {
          width: parent.width - navigation.width
          height: parent.height

          Column {
            anchors.fill: parent
            anchors.margins: Style.spacing.panelPadding
            spacing: Style.spacing.panelGap

            Row {
              width: parent.width
              spacing: Style.spacing.rowGap

              Column {
                width: parent.width - refreshButton.width - parent.spacing
                spacing: Style.space(2)
                Text {
                  textFormat: Text.PlainText
                  text: root.activeView === "shortcuts" ? "Shortcuts"
                    : (root.activeView === "activity" ? "Activity" : "Routines")
                  color: root.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.activeView === "shortcuts"
                    ? "Every shortcut Hyprland has right now. Pick one to build a routine that replaces it."
                    : (root.activeView === "activity"
                      ? "What is on now, what is waiting for its conditions, and what ran recently."
                      : "Modes and routines: what starts them, what they do, and what happens when they end.")
                  color: root.subtle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Button {
                id: refreshButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.loading ? "󰦖" : "󰑐"
                iconSpinning: root.loading
                tooltipText: "Refresh (Ctrl+R)"
                bordered: true
                focusable: true
                foreground: root.fg
                accent: root.accent
                enabled: !root.loading && !root.mutating
                opacity: enabled ? 1 : 0.6
                onClicked: root.requestRefresh()
                Accessible.name: "Refresh Omachord data"
                Accessible.role: Accessible.Button
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              }
            }

            Item {
              width: parent.width
              height: parent.height - y - noticeArea.height - parent.spacing

              // ---------------------------------------------- shortcuts
              Item {
                anchors.fill: parent
                readonly property bool shown: root.activeView === "shortcuts"
                opacity: shown ? 1 : 0
                visible: opacity > 0
                enabled: shown
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                Column {
                  anchors.fill: parent
                  spacing: Style.spacing.rowGap

                  Row {
                    width: parent.width
                    spacing: Style.spacing.rowGap
                    TextField {
                      width: parent.width - filterGroup.width - parent.spacing
                      placeholderText: "Search by keys or action..."
                      text: root.shortcutQuery
                      foreground: root.fg
                      accent: root.accent
                      onTextChanged: root.shortcutQuery = text
                      Accessible.name: "Search shortcuts"
                    }
                    ButtonGroup {
                      id: filterGroup
                      value: root.shortcutFilter
                      options: [
                        { value: "all", label: "All" },
                        { value: "managed", label: "Omachord" },
                        { value: "existing", label: "Hyprland" }
                      ]
                      onChanged: function(value) { root.shortcutFilter = value }
                    }
                  }

                  EmptyState {
                    visible: root.filteredBindings.length === 0
                    width: parent.width
                    glyph: "󰍉"
                    title: root.bindings.length === 0 ? "No shortcuts loaded yet" : "No shortcut matches"
                    body: root.bindings.length === 0
                      ? "The Hyprland binding catalogue appears here once the runner has read it."
                      : "Nothing matches \"" + root.shortcutQuery + "\" in this filter."
                    foreground: root.fg
                  }

                  ListView {
                    id: shortcutList
                    visible: root.filteredBindings.length > 0
                    width: parent.width
                    height: parent.height - y
                    clip: true
                    spacing: Style.space(4)
                    model: root.filteredBindings
                    boundsBehavior: Flickable.StopAtBounds
                    currentIndex: -1
                    keyNavigationEnabled: false
                    activeFocusOnTab: true
                    Accessible.role: Accessible.List
                    Accessible.name: "Shortcuts"
                    onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Down || event.text === "j") {
                        currentIndex = Math.min(count - 1, currentIndex + 1)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Up || event.text === "k") {
                        currentIndex = Math.max(0, currentIndex - 1)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        if (currentItem && currentItem.actionable) root.createFromBinding(currentItem.modelData)
                        event.accepted = true
                      }
                    }

                    delegate: CursorSurface {
                      id: bindingRow
                      required property var modelData
                      required property int index
                      readonly property bool actionable: !modelData.managed && modelData.editable !== false && root.configLoaded && !root.mutating
                      readonly property bool hot: ListView.isCurrentItem && ListView.view.activeFocus
                      width: shortcutList.width
                      implicitHeight: Math.max(Style.space(46), bindingText.implicitHeight + Style.space(16))
                      radius: Style.cornerRadius
                      foreground: root.fg
                      accent: root.accent
                      current: modelData.managed
                      hasCursor: hot || rowHover.hovered
                      Accessible.role: actionable ? Accessible.Button : Accessible.StaticText
                      Accessible.name: modelData.description + ", " + modelData.keys
                      Accessible.description: actionable ? "Create a routine that overrides this shortcut" : "Read-only shortcut"

                      HoverHandler { id: rowHover }

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.spacing.rowPaddingX
                        anchors.rightMargin: Style.spacing.rowPaddingX
                        spacing: Style.spacing.rowGap

                        Column {
                          id: bindingText
                          width: parent.width - keyRow.width - overrideButton.width - parent.spacing * 2
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(2)
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: bindingRow.modelData.description
                            color: root.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            elide: Text.ElideRight
                          }
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: bindingRow.modelData.managed ? "OMACHORD ROUTINE"
                              : (bindingRow.modelData.editable === false ? "MOUSE BINDING · READ ONLY" : "HYPRLAND")
                            color: bindingRow.modelData.managed ? root.accent : root.subtle
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                            elide: Text.ElideRight
                          }
                        }

                        Row {
                          id: keyRow
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(4)
                          Repeater {
                            model: bindingRow.modelData.keys.split(" + ")
                            KeyCap {
                              required property string modelData
                              text: modelData
                              foreground: root.fg
                              accent: root.accent
                            }
                          }
                        }

                        PanelActionButton {
                          id: overrideButton
                          anchors.verticalCenter: parent.verticalCenter
                          iconText: "󰐕"
                          tooltipText: "Build a routine that overrides this shortcut"
                          foreground: root.fg
                          size: Style.spacing.controlHeight
                          visible: bindingRow.actionable
                          opacity: bindingRow.hasCursor ? 1 : 0.35
                          onClicked: root.createFromBinding(bindingRow.modelData)
                          Accessible.role: Accessible.Button
                          Accessible.name: "Override " + bindingRow.modelData.description
                          Behavior on opacity { NumberAnimation { duration: 120 } }
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        z: -1
                        cursorShape: bindingRow.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                          shortcutList.currentIndex = bindingRow.index
                          if (bindingRow.actionable) root.createFromBinding(bindingRow.modelData)
                        }
                      }
                    }
                  }
                }
              }

              // ----------------------------------------------- routines
              Item {
                anchors.fill: parent
                readonly property bool shown: root.activeView === "routines"
                opacity: shown ? 1 : 0
                visible: opacity > 0
                enabled: shown
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                Row {
                  anchors.fill: parent
                  spacing: Style.spacing.panelGap

                  Item {
                    id: routineSidebar
                    readonly property bool shown: !root.compact || !root.compactEditorOpen
                    width: root.compact ? (shown ? parent.width : 0) : Style.space(258)
                    height: parent.height
                    clip: true
                    visible: width > 0
                    Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                    Column {
                      width: root.compact ? parent.parent.width : parent.width
                      height: parent.height
                      spacing: Style.spacing.rowGap

                      ChoicePicker {
                        id: newRoutinePicker
                        width: parent.width
                        showLabel: false
                        emphasized: true
                        leadingIcon: "󰐕"
                        value: ""
                        placeholderText: "New routine"
                        foreground: root.fg
                        accent: root.accent
                        enabled: root.configLoaded && !root.mutating
                        options: Model.templateOptions()
                        onChanged: function(value) {
                          var routine = Model.templateRoutine(value, root.config.routines)
                          newRoutinePicker.value = ""
                          if (routine) root.requestSelectDraft(routine)
                        }
                        Accessible.name: "New routine"
                      }

                      PanelSectionHeader {
                        width: parent.width
                        text: root.config.routines.length
                          ? (root.config.routines.length === 1 ? "1 ROUTINE" : root.config.routines.length + " ROUTINES")
                          : "ROUTINES"
                        foreground: root.fg
                      }

                      EmptyState {
                        visible: root.config.routines.length === 0
                        width: parent.width
                        glyph: "󰐐"
                        title: "No routines yet"
                        body: "Start from a template or a blank routine."
                        foreground: root.fg
                      }

                      ListView {
                        id: routineList
                        visible: root.config.routines.length > 0
                        width: parent.width
                        height: parent.height - y
                        clip: true
                        spacing: Style.space(4)
                        model: root.config.routines
                        boundsBehavior: Flickable.StopAtBounds
                        currentIndex: -1
                        keyNavigationEnabled: false
                        activeFocusOnTab: root.configLoaded && !root.mutating
                        Accessible.role: Accessible.List
                        Accessible.name: "Routines"
                        onActiveFocusChanged: {
                          if (!activeFocus || count === 0) return
                          if (currentIndex < 0) {
                            for (var i = 0; i < count; i++)
                              if (root.config.routines[i].id === root.selectedRoutineId) { currentIndex = i; return }
                            currentIndex = 0
                          }
                        }
                        Keys.onPressed: function(event) {
                          if (event.key === Qt.Key_Down || event.text === "j") {
                            currentIndex = Math.min(count - 1, currentIndex + 1)
                            event.accepted = true
                          } else if (event.key === Qt.Key_Up || event.text === "k") {
                            currentIndex = Math.max(0, currentIndex - 1)
                            event.accepted = true
                          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            if (currentIndex >= 0) root.requestSelectRoutine(root.config.routines[currentIndex].id)
                            event.accepted = true
                          }
                        }

                        delegate: CursorSurface {
                          id: routineRow
                          required property var modelData
                          required property int index
                          // The delegate's modelData wraps nested lists as QVariantList, which
                          // Model.js cannot tell from an empty array; read the plain routine.
                          readonly property var routine: root.routineById(modelData.id) || modelData
                          readonly property bool isSelected: modelData.id === root.selectedRoutineId
                          readonly property bool isOn: !!root.activeIds[modelData.id]
                          readonly property bool isDirty: isSelected && routineEditor.dirty
                          readonly property bool hot: ListView.isCurrentItem && ListView.view.activeFocus
                          readonly property var lastRun: root.lastRunFor(modelData.id)
                          width: routineList.width
                          implicitHeight: routineRowContent.implicitHeight + Style.space(16)
                          radius: Style.cornerRadius
                          foreground: root.fg
                          accent: root.accent
                          current: isSelected
                          hasCursor: hot || routineHover.hovered
                          Accessible.role: Accessible.Button
                          Accessible.name: modelData.name
                          Accessible.description: Model.summarizeTriggers(routine)
                            + (isOn ? ", on" : "") + (modelData.enabled ? "" : ", disabled")

                          HoverHandler { id: routineHover }

                          Row {
                            id: routineRowContent
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.spacing.rowPaddingX
                            anchors.rightMargin: Style.spacing.rowPaddingX
                            spacing: Style.spacing.rowGap

                            Column {
                              width: parent.width - enabledSwitch.width - parent.spacing
                              spacing: Style.space(2)
                              anchors.verticalCenter: parent.verticalCenter

                              Row {
                                width: parent.width
                                spacing: Style.space(6)

                                Rectangle {
                                  id: onDot
                                  visible: routineRow.isOn
                                  anchors.verticalCenter: parent.verticalCenter
                                  width: Style.space(6)
                                  height: width
                                  radius: width / 2
                                  color: root.enabledGreen

                                  SequentialAnimation on opacity {
                                    running: onDot.visible && window.visible
                                    loops: Animation.Infinite
                                    alwaysRunToEnd: true
                                    NumberAnimation { from: 1.0; to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
                                    NumberAnimation { from: 0.35; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
                                  }
                                }

                                Text {
                                  textFormat: Text.PlainText
                                  width: parent.width - (onDot.visible ? onDot.width + parent.spacing : 0)
                                  text: routineRow.modelData.name
                                  color: routineRow.modelData.enabled ? root.fg : root.subtle
                                  font.family: Style.font.family
                                  font.pixelSize: Style.font.body
                                  font.bold: routineRow.isSelected
                                  elide: Text.ElideRight
                                }
                              }

                              Text {
                                textFormat: Text.PlainText
                                width: parent.width
                                text: Model.summarizeTriggers(routineRow.routine)
                                color: root.subtle
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                              }

                              Text {
                                textFormat: Text.PlainText
                                width: parent.width
                                visible: text !== ""
                                text: routineRow.isDirty ? "UNSAVED"
                                  : (routineRow.isOn ? "ON" + (root.activeIds[routineRow.modelData.id].expiresAt
                                      ? " · UNTIL " + Conditions.clockTime(root.activeIds[routineRow.modelData.id].expiresAt) : "")
                                    : (Model.isStateful(routineRow.routine) ? "MODE" : "")
                                      + (routineRow.lastRun && !routineRow.isOn
                                        ? (Model.isStateful(routineRow.routine) ? " · " : "")
                                          + (routineRow.lastRun.status === "failed" ? "FAILED " : "RAN ")
                                          + Conditions.relativeTime(routineRow.lastRun.timestamp, root.displayNow).toUpperCase()
                                        : ""))
                                color: routineRow.isDirty ? root.accent
                                  : (routineRow.isOn ? root.enabledGreen
                                    : (routineRow.lastRun && routineRow.lastRun.status === "failed" ? root.urgent : root.subtle))
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: true
                                font.letterSpacing: 1.2
                                elide: Text.ElideRight
                              }
                            }

                            ToggleSwitch {
                              id: enabledSwitch
                              anchors.verticalCenter: parent.verticalCenter
                              checked: routineRow.modelData.enabled
                              interactive: root.configLoaded && !root.mutating
                              foreground: root.fg
                              accent: root.accent
                              cursorRing: false
                              onToggled: root.requestSetRoutineEnabled(routineRow.modelData.id, !checked)
                              Accessible.role: Accessible.CheckBox
                              Accessible.name: (checked ? "Turn off " : "Turn on ") + routineRow.modelData.name
                              Accessible.checkable: true
                              Accessible.checked: checked
                              Accessible.onPressAction: root.requestSetRoutineEnabled(routineRow.modelData.id, !checked)
                              PanelToolTip {
                                visible: parent.containsMouse
                                text: parent.checked ? "Enabled: shortcuts, events, and conditions may start it"
                                  : "Disabled: nothing starts it until you turn it on"
                              }
                            }
                          }

                          MouseArea {
                            anchors.fill: parent
                            z: -1
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              routineList.currentIndex = routineRow.index
                              root.requestSelectRoutine(routineRow.modelData.id)
                            }
                          }
                        }
                      }
                    }
                  }

                  Item {
                    id: editorSlot
                    readonly property bool shown: !root.compact || root.compactEditorOpen
                    width: root.compact ? (shown ? parent.width : 0) : parent.width - parent.spacing - routineSidebar.width
                    height: parent.height
                    clip: true
                    visible: width > 0
                    Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                    RoutineEditor {
                      id: routineEditor
                      width: root.compact ? parent.parent.width : parent.width
                      height: parent.height
                      routine: root.editorRoutine
                      bindings: root.bindings
                      appOptions: root.appOptions
                      commandOptions: root.commandOptions
                      themeOptions: root.themeOptions
                      wifiOptions: root.wifiOptions
                      toggleOptions: root.toggleOptions
                      isActive: !!(root.editorRoutine && root.activeIds[root.editorRoutine.id])
                      activeRecord: root.editorRoutine ? (root.activeIds[root.editorRoutine.id] || null) : null
                      serviceState: root.editorRoutine ? root.serviceRoutineState(root.editorRoutine.id) : null
                      targetWindow: window
                      busy: root.uiLocked
                      running: actionProc.running
                      persisted: root.editorPersisted
                      showBack: root.compact
                      foreground: root.fg
                      accent: root.accent
                      urgent: root.urgent
                      success: root.enabledGreen
                      onSaveRequested: function(routine) { root.saveRoutine(routine) }
                      onSaveAndRunRequested: function(routine) { root.saveAndRun(routine) }
                      onDeleteRequested: function(id) { root.requestDelete(id) }
                      onDuplicateRequested: function(id) { root.duplicateRoutine(id) }
                      onRunRequested: function(id) { root.runRoutine(id) }
                      onBackRequested: root.requestEditorBack()
                    }
                  }
                }
              }

              // ----------------------------------------------- activity
              QQC.ScrollView {
                id: activityScroll
                anchors.fill: parent
                readonly property bool shown: root.activeView === "activity"
                opacity: shown ? 1 : 0
                visible: opacity > 0
                enabled: shown
                clip: true
                contentWidth: availableWidth
                QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                Column {
                  width: activityScroll.availableWidth
                  spacing: Style.spacing.panelGap

                  // ---- on now
                  Column {
                    width: parent.width
                    spacing: Style.space(4)

                    PanelSectionHeader {
                      width: parent.width
                      text: "ON NOW"
                      foreground: root.fg
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: root.activeRows.length === 0
                      width: parent.width
                      text: root.integrationOn
                        ? "Nothing is on right now. Modes show here while they hold, with a way to end them."
                        : "Omachord is off, so nothing can be on."
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }

                    Repeater {
                      model: root.activeRows

                      CursorSurface {
                        id: activeRow
                        required property var modelData
                        width: parent.width
                        implicitHeight: activeRowContent.implicitHeight + Style.space(16)
                        radius: Style.cornerRadius
                        foreground: root.fg
                        accent: root.accent
                        hasCursor: activeHover.hovered
                        Accessible.role: Accessible.ListItem
                        Accessible.name: modelData.name + ", on"

                        HoverHandler { id: activeHover }

                        Row {
                          id: activeRowContent
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.rowPaddingX
                          anchors.rightMargin: Style.space(8)
                          spacing: Style.spacing.rowGap

                          Rectangle {
                            id: activeDot
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(6)
                            height: width
                            radius: width / 2
                            color: root.enabledGreen
                            SequentialAnimation on opacity {
                              running: activeDot.visible && window.visible && root.activeView === "activity"
                              loops: Animation.Infinite
                              alwaysRunToEnd: true
                              NumberAnimation { from: 1.0; to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
                              NumberAnimation { from: 0.35; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
                            }
                          }

                          Column {
                            width: parent.width - activeDot.width - endButton.width - openButton.width - parent.spacing * 3
                            spacing: Style.space(2)
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: activeRow.modelData.name
                              color: root.fg
                              font.family: Style.font.family
                              font.pixelSize: Style.font.body
                              font.bold: true
                              elide: Text.ElideRight
                            }
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: [root.activeMeta(activeRow.modelData), root.activeEnding(activeRow.modelData)]
                                .filter(function(part) { return part !== "" }).join(" · ")
                              color: root.dim
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                            }
                          }

                          Button {
                            id: openButton
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Edit"
                            focusable: true
                            foreground: root.fg
                            accent: root.accent
                            onClicked: root.requestSelectRoutine(activeRow.modelData.id)
                            Accessible.role: Accessible.Button
                            Accessible.name: "Edit " + activeRow.modelData.name
                          }

                          Button {
                            id: endButton
                            anchors.verticalCenter: parent.verticalCenter
                            text: "End"
                            bordered: true
                            focusable: true
                            foreground: root.fg
                            accent: root.accent
                            enabled: !root.mutating && !(root.service && root.service.manualBusy) && !actionProc.running
                            opacity: enabled ? 1 : 0.6
                            onClicked: root.endRoutine(activeRow.modelData.id)
                            Accessible.role: Accessible.Button
                            Accessible.name: "End " + activeRow.modelData.name
                            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                          }
                        }
                      }
                    }
                  }

                  // ---- waiting on conditions
                  Column {
                    width: parent.width
                    spacing: Style.space(4)

                    PanelSectionHeader {
                      width: parent.width
                      text: "CONDITIONS"
                      foreground: root.fg
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: root.conditionRoutines.length === 0
                      width: parent.width
                      text: "No routine has conditions yet. Add a time, Wi-Fi, power, or Omarchy toggle condition and Omachord starts and ends it for you."
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }

                    Repeater {
                      model: root.conditionRoutines

                      CursorSurface {
                        id: conditionRow
                        required property var modelData
                        readonly property var routine: root.routineById(modelData.id) || modelData
                        readonly property var state: root.serviceRoutineState(modelData.id)
                        readonly property bool isOn: !!root.activeIds[modelData.id]
                        readonly property var reason: isOn ? null : root.conditionReason(routine, state)
                        width: parent.width
                        implicitHeight: conditionRowContent.implicitHeight + Style.space(16)
                        radius: Style.cornerRadius
                        foreground: root.fg
                        accent: root.accent
                        hasCursor: conditionHover.hovered
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.name + ", " + (isOn ? "on" : reason.label)

                        HoverHandler { id: conditionHover }

                        Row {
                          id: conditionRowContent
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.rowPaddingX
                          anchors.rightMargin: Style.spacing.rowPaddingX
                          spacing: Style.spacing.rowGap

                          Column {
                            width: parent.width - conditionState.width - parent.spacing
                            spacing: Style.space(2)
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: conditionRow.modelData.name
                              color: conditionRow.modelData.enabled ? root.fg : root.subtle
                              font.family: Style.font.family
                              font.pixelSize: Style.font.body
                              font.bold: true
                              elide: Text.ElideRight
                            }
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: "If " + Model.summarizeConditions(conditionRow.routine)
                                + (Model.summarizeActions(conditionRow.routine) ? " · then " + Model.summarizeActions(conditionRow.routine) : "")
                              color: root.dim
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              wrapMode: Text.WordWrap
                            }
                            Text {
                              textFormat: Text.PlainText
                              visible: !conditionRow.isOn && !!conditionRow.reason && conditionRow.reason.detail !== ""
                              width: parent.width
                              text: conditionRow.reason ? conditionRow.reason.detail : ""
                              color: conditionRow.reason && conditionRow.reason.urgent ? root.urgent : root.subtle
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              wrapMode: Text.WordWrap
                            }
                          }

                          Text {
                            textFormat: Text.PlainText
                            id: conditionState
                            anchors.verticalCenter: parent.verticalCenter
                            text: (conditionRow.isOn ? "ON" : conditionRow.reason.label).toUpperCase()
                            color: conditionRow.isOn ? root.enabledGreen
                              : (conditionRow.reason && conditionRow.reason.urgent ? root.urgent : root.subtle)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                          }
                        }

                        MouseArea {
                          anchors.fill: parent
                          z: -1
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.requestSelectRoutine(conditionRow.modelData.id)
                        }
                      }
                    }
                  }

                  // ---- events
                  Column {
                    width: parent.width
                    spacing: Style.space(4)

                    PanelSectionHeader {
                      width: parent.width
                      text: "EVENTS"
                      foreground: root.fg
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: root.eventRows.length === 0
                      width: parent.width
                      text: "No routine runs on an Omarchy event yet. Events are picked in a routine's Starts when section."
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }

                    Repeater {
                      model: root.eventRows

                      Item {
                        id: eventRow
                        required property var modelData
                        width: parent.width
                        implicitHeight: eventRowContent.implicitHeight + Style.space(10)

                        Row {
                          id: eventRowContent
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.rowPaddingX
                          spacing: Style.spacing.rowGap

                          Text {
                            textFormat: Text.PlainText
                            width: Style.space(28)
                            text: eventRow.modelData.hook.glyph
                            color: root.dim
                            font.family: Style.font.family
                            font.pixelSize: Style.font.icon
                            anchors.verticalCenter: parent.verticalCenter
                          }

                          Column {
                            width: parent.width - Style.space(28) - parent.spacing
                            spacing: Style.space(2)
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: eventRow.modelData.hook.label
                              color: root.fg
                              font.family: Style.font.family
                              font.pixelSize: Style.font.body
                              elide: Text.ElideRight
                            }
                            Flow {
                              width: parent.width
                              spacing: Style.space(4)
                              Repeater {
                                model: eventRow.modelData.routines
                                PlainTextButton {
                                  required property var modelData
                                  plainText: modelData.name
                                  focusable: true
                                  foreground: root.fg
                                  accent: root.accent
                                  onClicked: root.requestSelectRoutine(modelData.id)
                                  Accessible.name: modelData.name
                                  Accessible.role: Accessible.Button
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }

                  // ---- service
                  Column {
                    width: parent.width
                    spacing: Style.space(4)

                    PanelSectionHeader {
                      width: parent.width
                      text: "CONDITION SERVICE"
                      foreground: root.fg
                    }

                    Row {
                      width: parent.width
                      spacing: Style.space(8)

                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(6)
                        height: width
                        radius: width / 2
                        color: root.serviceStatus && root.serviceStatus.enabled ? root.enabledGreen : root.subtle
                        Behavior on color { ColorAnimation { duration: 160 } }
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width - Style.space(6) - parent.spacing
                        text: root.serviceInputsText()
                        color: root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                      }
                    }
                  }

                  // ---- recent runs
                  Column {
                    width: parent.width
                    spacing: Style.space(4)

                    PanelSectionHeader {
                      width: parent.width
                      text: "RECENT RUNS"
                      foreground: root.fg
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: root.recentRuns.length === 0
                      width: parent.width
                      text: "Nothing has run yet."
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }

                    Repeater {
                      model: root.recentRuns

                      Item {
                        id: runRow
                        required property var modelData
                        readonly property bool failed: modelData.status === "failed"
                        width: parent.width
                        implicitHeight: runRowContent.implicitHeight + Style.space(8)

                        Row {
                          id: runRowContent
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.rowPaddingX
                          spacing: Style.spacing.rowGap

                          Text {
                            textFormat: Text.PlainText
                            width: Style.space(72)
                            text: Conditions.relativeTime(runRow.modelData.timestamp, root.displayNow)
                            color: root.subtle
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                          }
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width - Style.space(72) - runStatus.width - parent.spacing * 2
                            text: Model.nameFor(root.config, runRow.modelData.routineId)
                              + (runRow.failed && runRow.modelData.error ? " — " + runRow.modelData.error : "")
                            color: runRow.failed ? root.urgent : root.fg
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }
                          Text {
                            textFormat: Text.PlainText
                            id: runStatus
                            text: String(runRow.modelData.status || "").toUpperCase()
                              + (runRow.modelData.trigger ? " · " + String(runRow.modelData.trigger).toUpperCase().replace("HOOK:", "") : "")
                            color: runRow.failed ? root.urgent : root.subtle
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                          }
                        }
                      }
                    }
                  }

                  Item { width: 1; height: Style.space(12) }
                }
              }
            }

            // ----------------------------------------------- notice
            Item {
              id: noticeArea
              width: parent.width
              readonly property bool shown: root.noticeText !== ""
              clip: true
              height: shown ? noticeBlock.implicitHeight : 0
              opacity: shown ? 1 : 0
              Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

              BorderSurface {
                id: noticeBlock
                anchors.bottom: parent.bottom
                width: parent.width
                implicitHeight: noticeRow.implicitHeight + (root.noticeError ? Style.space(16) : Style.space(6))
                radius: Style.cornerRadius
                color: root.noticeError ? Util.alpha(root.urgent, 0.10) : "transparent"
                borderSpec: root.noticeError ? Border.flat(Util.alpha(root.urgent, 0.35), 1) : Border.none()

                Row {
                  id: noticeRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: root.noticeError ? Style.spacing.rowPaddingX : Style.space(2)
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: root.noticeError ? "󰀦" : "󰄬"
                    color: root.noticeError ? root.urgent : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width - Style.space(20)
                    text: root.noticeText
                    color: root.noticeError ? root.urgent : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.StaticText
                    Accessible.name: root.noticeText
                  }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 100
        background: root.bg
        foreground: root.fg
        onOpenedChanged: if (opened) Qt.callLater(function() { confirmKeyScope.forceActiveFocus() })
        onCanceled: {
          opened = false
          root.confirmPurpose = ""
          root.deleteRoutineId = ""
          root.pendingUiAction = ""
          root.pendingUiValue = null
          Qt.callLater(function() { focusScope.forceActiveFocus() })
        }
        onConfirmed: {
          var purpose = root.confirmPurpose
          var action = root.pendingUiAction
          var value = root.pendingUiValue
          opened = false
          root.confirmPurpose = ""
          root.pendingUiAction = ""
          root.pendingUiValue = null
          if (purpose === "disconnect") root.mutateConnection("disconnect")
          else if (purpose === "delete") root.deleteSelectedRoutine()
          else if (purpose === "discard") {
            routineEditor.dirty = false
            root.performUiAction(action, value)
          }
        }
      }

      FocusScope {
        id: confirmKeyScope
        anchors.fill: parent
        visible: confirmDialog.opened
        focus: visible
        z: 101
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          event.accepted = confirmDialog.handleKey(event)
        }
      }
    }
  }
}
