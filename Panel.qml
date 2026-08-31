import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

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
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string togglesDir: stateHome + "/omarchy/toggles"
  readonly property bool wifiAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiOptions: buildWifiOptions()
  readonly property var conditionRoutines: {
    var rows = []
    for (var i = 0; i < config.routines.length; i++)
      if (Model.hasConditions(config.routines[i])) rows.push(config.routines[i])
    return rows
  }
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

  readonly property string home: Quickshell.env("HOME")
  readonly property string runnerPath: Quickshell.env("OMACHORD_RUNNER_PATH")
    || (home + "/.config/omarchy/plugins/anothadev.omachord/bin/omachord")
  readonly property var filteredBindings: Model.filterBindings(bindings, shortcutQuery, shortcutFilter)
  readonly property bool compact: window.width < 920
  readonly property bool uiLocked: loading || mutating || revisionRefreshPending || !configLoaded
  readonly property bool connectionNeedsRepair: status.ownedConnection === true && status.integrationComplete !== true
  readonly property color enabledGreen: "#68c98b"

  onCompactChanged: {
    if (compact && editorRoutine) compactEditorOpen = true
  }

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        if (["shortcuts", "routines", "automations"].indexOf(payload.view) !== -1)
          setActiveView(payload.view)
      } catch (e) {}
    }
    if (compact && editorRoutine && !editorPersisted) compactEditorOpen = true
    refreshApps()
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
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "anothadev.omachord")
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
    process.running = true
    return true
  }

  function finishRefreshProcess(process) {
    if (!process.refreshQueued) return
    process.refreshQueued = false
    Qt.callLater(function() {
      if (process.running) process.refreshQueued = true
      else process.running = true
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
    requestRefreshProcess(activeProc)
    requestRefreshProcess(themesProc)
    requestRefreshProcess(togglesProc)
    requestRefreshProcess(serviceStatusProc)
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

  function rebuildToggleOptions(text) {
    var lines = String(text || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name) rows.push({ value: name, label: name, description: "Currently on" })
    }
    rows.sort(function(left, right) { return left.label.localeCompare(right.label) })
    toggleOptions = rows
  }

  function serviceInputsText() {
    var status = serviceStatus
    if (!status) return "The condition service has not reported yet. It runs inside omarchy-shell once the plugin is enabled."
    var parts = []
    parts.push(status.enabled ? "Evaluating conditions" : "Paused: " + (status.reason || "not connected"))
    if (status.env) {
      parts.push("Wi-Fi: " + (status.env.wifiAvailable === false ? "unavailable" : (status.env.ssid || "not connected")))
      parts.push("Power: " + (status.env.onBattery ? "battery" : "plugged in")
        + (typeof status.env.batteryPercent === "number" && status.env.batteryPercent >= 0 ? " " + status.env.batteryPercent + "%" : ""))
      var toggles = Array.isArray(status.env.toggles) ? status.env.toggles : []
      parts.push("Toggles on: " + (toggles.length ? toggles.join(", ") : "none"))
    }
    if (status.lastEvent) parts.push("Last event: " + status.lastEvent)
    return parts.join("\n")
  }

  function serviceRoutineState(id) {
    var status = serviceStatus
    if (!status || !Array.isArray(status.routines)) return null
    for (var i = 0; i < status.routines.length; i++)
      if (status.routines[i] && status.routines[i].id === id) return status.routines[i]
    return null
  }

  function requestRefresh() {
    if (loading || mutating) return
    requestDraftReplacement("refresh", null)
  }

  function failConfigLoad(message) {
    if (configHandled) return
    configHandled = true
    loading = false
    configLoaded = false
    noticeError = true
    noticeText = message || "Could not load the routine configuration"
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
      noticeError = false
      if (noticeText.indexOf("Could not load") === 0
          || noticeText.indexOf("The routine configuration is not committed") === 0)
        noticeText = ""
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
    noticeText = ""
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
      pendingConfig = null
      pendingSelectId = ""
      pendingAfterApply = ""
      noticeError = true
      noticeText = result.error || "Could not save configuration"
      // Someone else saved first. Pick up the new revision and list without
      // touching the open draft, so the next Save applies it to the new base.
      if (result.code === "stale-config") {
        noticeText = "The configuration changed elsewhere. Refreshing the list and revision..."
        mutating = true
        revisionRefreshPending = true
        revisionStarted = false
        requestRefreshProcess(revisionProc)
      }
      routineEditor.externalError = noticeText
      return
    }
    config = pendingConfig || config
    configRevision = result.revision
    var selectId = pendingSelectId
    pendingConfig = null
    pendingSelectId = ""
    noticeError = false
    noticeText = result.warnings && result.warnings.length
      ? result.warnings.join(" ")
      : (result.deactivated && result.deactivated.length
        ? "Routine configuration saved; ended " + result.deactivated.join(", ")
        : "Routine configuration saved")
    if (selectId) selectRoutineNow(selectId, true)
    else ensureRoutineSelection()
    requestRefreshProcess(bindingsProc)
    requestRefreshProcess(logsProc)
    requestRefreshProcess(statusProc)
    requestRefreshProcess(activeProc)
    if (pendingAfterApply === "run" && selectId) runRoutine(selectId)
    pendingAfterApply = ""
  }

  function saveRoutine(routine) {
    applyConfig(Model.replaceRoutine(config, routine), routine.id, "")
  }

  function duplicateRoutine(id) {
    if (!configLoaded || routineEditor.dirty) return
    var result = Model.duplicateRoutine(config, id)
    if (result.routine) applyConfig(result.config, result.routine.id, "")
  }

  function requestDelete(id) {
    if (!editorPersisted || mutating) return
    deleteRoutineId = id
    showConfirmation(
      "delete",
      "Delete this routine? Its managed shortcut and event triggers will be removed, including unsaved edits.",
      "Delete")
  }

  function deleteSelectedRoutine() {
    var next = Model.removeRoutine(config, deleteRoutineId)
    deleteRoutineId = ""
    applyConfig(next, next.routines.length ? next.routines[0].id : "", "")
  }

  function runRoutine(id) {
    if (actionProc.running || !id || !configLoaded || !editorPersisted) return
    noticeText = "Running " + id + "..."
    noticeError = false
    actionProc.command = [runnerPath, "run", id, "test"]
    actionStarted = false
    startProcess(actionProc)
  }

  function mutateConnection(operation) {
    if (mutating || loading || !(configLoaded || configUncommitted)) return
    mutationOperation = operation
    mutating = true
    mutationStarted = false
    noticeText = operation === "connect" ? "Enabling Omachord..." : "Disabling Omachord..."
    mutationProc.command = operation === "connect"
      ? [runnerPath, operation, configRevision]
      : [runnerPath, operation]
    startProcess(mutationProc)
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
    noticeError = !result.ok
    noticeText = result.ok
      ? (operation === "connect" ? "Omachord is on" : "Omachord is disabled")
      : (result.error || "Connection change failed")
    if (result.ok && typeof result.revision === "string") configRevision = result.revision
    // Only a config that never loaded (uncommitted until this Enable/Repair)
    // is reloaded in full; otherwise keep the editor draft the user has open.
    if (result.ok && !configLoaded) {
      refreshAll()
      return
    }
    requestRefreshProcess(statusProc)
    requestRefreshProcess(bindingsProc)
    requestRefreshProcess(activeProc)
    requestRefreshProcess(logsProc)
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
    noticeError = !result.ok
    noticeText = result.ok ? actionNotice(result) : (result.error || "Routine failed")
    requestRefreshProcess(logsProc)
    requestRefreshProcess(activeProc)
  }

  function actionNotice(result) {
    if (result.alreadyActive) return "Routine is already active"
    if (result.alreadyInactive) return "Routine was not active"
    if (result.state === "activated") return "Routine activated in " + result.durationMs + " ms"
    if (result.state === "deactivated")
      return "Routine ended in " + result.durationMs + " ms; restored " + result.restored
        + (result.skipped ? ", kept " + result.skipped + " you changed" : "")
    return "Routine completed in " + result.durationMs + " ms"
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
      config = parsed.config
      configRevision = parsed.revision
      noticeError = true
      noticeText = "The configuration changed elsewhere. The list and revision were refreshed; save again to apply this draft."
    } else {
      noticeError = true
      noticeText = "The configuration changed elsewhere, but its latest revision could not be loaded. Use Refresh before saving again."
        + (errorText ? " " + errorText : "")
    }
    routineEditor.externalError = noticeText
  }

  function rebuildThemeOptions(text) {
    var lines = String(text || "").split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (!name) continue
      rows.push({ value: Model.themeSlug(name), label: name })
    }
    themeOptions = rows
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshApps() }
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
  // draft in place; used after a stale-revision save.
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
    command: ["find", root.togglesDir, "-mindepth", "1", "-maxdepth", "1", "-type", "f", "-printf", "%f\n"]
    stdout: StdioCollector { id: togglesStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.rebuildToggleOptions(exitCode === 0 ? togglesStdout.text : "")
      root.finishRefreshProcess(togglesProc)
    }
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
      if (!running && !root.actionStarted && root.noticeText.indexOf("Running ") === 0)
        Qt.callLater(function() {
          root.handleActionResult("", "Could not start the Omachord runner", -1)
        })
    }
  }

  FloatingWindow {
    id: window
    visible: false
    title: "Omachord"
    color: Color.background
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(640, 480)

    onVisibleChanged: {
      if (!visible) routineEditor.stopShortcutCapture()
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide((root.manifest && root.manifest.id) || "anothadev.omachord")
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        if (confirmDialog.opened) {
          // The key that opened a modal can still bubble here before the
          // modal focus handoff. Consume it without confirming the dialog.
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.requestClose()
          event.accepted = true
        }
      }

      Row {
        anchors.fill: parent

        BorderSurface {
          id: navigation
          width: root.compact ? Math.min(150, parent.width * 0.28) : 218
          height: parent.height
          color: Util.alpha(Color.foreground, 0.025)
          borderSpec: Border.flat(Util.alpha(Color.foreground, 0.15), 1)

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(18)
            spacing: Style.space(18)

            Column {
              width: parent.width
              spacing: Style.space(2)

              Text {

                textFormat: Text.PlainText
                text: "OMA"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: Style.space(2)
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: "CHORD"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: root.compact ? Style.font.title : Style.font.heading
                font.bold: true
              }
              Rectangle {
                width: Style.space(42)
                height: 2
                color: Color.accent
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: [
                  { id: "shortcuts", number: "01", label: "Shortcuts" },
                  { id: "routines", number: "02", label: "Routines" },
                  { id: "automations", number: "03", label: "Automations" }
                ]

                Button {
                  required property var modelData
                  width: parent.width
                  text: modelData.number + "  " + modelData.label
                  leftAlign: true
                  focusable: true
                  enabled: !root.mutating
                  selected: root.activeView === modelData.id
                  onClicked: root.setActiveView(modelData.id)
                  Accessible.name: modelData.label
                  Accessible.role: Accessible.Button
                }
              }
            }

            Item { width: 1; height: Math.max(0, parent.height - Style.space(350)) }

            BorderSurface {
              width: parent.width
              implicitHeight: connectionColumn.implicitHeight + Style.space(20)
              color: root.status.integrationComplete
                ? Util.alpha(root.enabledGreen, 0.08)
                : Util.alpha(Color.foreground, 0.035)
              borderSpec: Border.flat(root.status.integrationComplete
                ? Util.alpha(root.enabledGreen, 0.55)
                : Util.alpha(Color.foreground, 0.16), 1)
              radius: Style.cornerRadius

              Column {
                id: connectionColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(7)

                Row {
                  width: parent.width
                  spacing: Style.space(7)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: root.status.integrationComplete ? root.enabledGreen
                      : (root.connectionNeedsRepair ? Color.urgent : Color.muted)
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.connectionNeedsRepair ? "REPAIR NEEDED"
                      : (root.status.integrationComplete ? "OMACHORD ON"
                        : (root.status.connectionEnabled === false ? "OMACHORD OFF" : "STARTING"))
                    color: root.status.integrationComplete ? root.enabledGreen
                      : (root.connectionNeedsRepair ? Color.urgent : Qt.darker(Color.foreground, 1.35))
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.connectionNeedsRepair
                    ? "An owned integration artifact is missing."
                    : (root.status.integrationComplete
                      ? "Shortcuts, hooks, and conditions are live."
                      : (root.status.connectionEnabled === false
                        ? "Automation is paused. Your routines are kept."
                        : "Finishing first-run setup..."))
                  color: Qt.darker(Color.foreground, 1.55)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Button {
                  width: parent.width
                  text: root.connectionNeedsRepair ? "Repair"
                    : (root.status.integrationComplete ? "Disable" : "Enable")
                  bordered: true
                  focusable: true
                  enabled: (root.configLoaded || root.configUncommitted) && !root.loading && !root.mutating
                  onClicked: {
                    if (root.connectionNeedsRepair) root.mutateConnection("connect")
                    else if (root.status.integrationComplete) {
                      root.showConfirmation(
                        "disconnect",
                        "Disable Omachord automation? Your routines will be kept, while shortcuts, hooks, and conditions pause.",
                        "Disable")
                    } else root.mutateConnection("connect")
                  }
                  Accessible.name: root.connectionNeedsRepair ? "Repair Omachord integration"
                    : (root.status.integrationComplete ? "Disable Omachord" : "Enable Omachord")
                  Accessible.role: Accessible.Button
                }
              }
            }

            Text {

              textFormat: Text.PlainText
              width: parent.width
              text: "ESC  CLOSE"
              color: Qt.darker(Color.foreground, 1.75)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }
        }

        Item {
          width: parent.width - navigation.width
          height: parent.height

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(22)
            spacing: Style.space(14)

            Row {
              width: parent.width
              spacing: Style.space(12)

              Column {
                width: parent.width - refreshButton.width - parent.spacing
                spacing: Style.space(3)
                Text {
                  textFormat: Text.PlainText
                  text: root.activeView === "shortcuts" ? "Effective bindings"
                    : (root.activeView === "automations" ? "Event automations" : "Routine workshop")
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.activeView === "shortcuts"
                    ? "Everything Hyprland can currently dispatch. Existing Lua stays read-only."
                    : (root.activeView === "automations"
                      ? "The same routines, organized by the Omarchy events that can trigger them."
                      : "Build one keypress from small, ordered actions.")
                  color: Qt.darker(Color.foreground, 1.55)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Button {
                id: refreshButton
                text: root.loading ? "Loading..." : "Refresh"
                bordered: true
                focusable: true
                enabled: !root.loading && !root.mutating
                onClicked: root.requestRefresh()
                Accessible.name: "Refresh Omachord data"
                Accessible.role: Accessible.Button
              }
            }

            BorderSurface {
              visible: root.connectionNeedsRepair
              width: parent.width
              implicitHeight: disconnectedText.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Util.alpha(Color.accent, 0.045)
              borderSpec: Border.flat(Util.alpha(Color.accent, 0.28), 1)
              Text {
                textFormat: Text.PlainText
                id: disconnectedText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                text: root.connectionNeedsRepair
                  ? "Integration is incomplete. Saving remains safe; choose Repair before relying on shortcuts or events."
                  : ""
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Item {
              width: parent.width
              height: parent.height - y - noticeBar.height - parent.spacing

              Item {
                anchors.fill: parent
                visible: root.activeView === "shortcuts"

                Column {
                  anchors.fill: parent
                  spacing: Style.space(12)

                  Row {
                    width: parent.width
                    spacing: Style.space(12)
                    TextField {
                      width: parent.width - filterGroup.width - parent.spacing
                      placeholderText: "Search by keys or action..."
                      text: root.shortcutQuery
                      onTextChanged: root.shortcutQuery = text
                      Accessible.name: "Search shortcuts"
                    }
                    ButtonGroup {
                      id: filterGroup
                      value: root.shortcutFilter
                      options: [
                        { value: "all", label: "All" },
                        { value: "managed", label: "Managed" },
                        { value: "existing", label: "Existing" }
                      ]
                      onChanged: function(value) { root.shortcutFilter = value }
                    }
                  }

                  ListView {
                    id: shortcutList
                    width: parent.width
                    height: parent.height - y
                    clip: true
                    spacing: Style.space(4)
                    model: root.filteredBindings
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: CursorSurface {
                      required property var modelData
                      required property int index
                      readonly property bool actionable: !modelData.managed && modelData.editable !== false && root.configLoaded && !root.mutating
                      width: shortcutList.width
                      implicitHeight: Math.max(Style.space(46), bindingText.implicitHeight + Style.space(16))
                      foreground: Color.foreground
                      current: modelData.managed
                      hasCursor: activeFocus
                      activeFocusOnTab: actionable
                      Keys.onReturnPressed: if (actionable) root.createFromBinding(modelData)
                      Keys.onEnterPressed: if (actionable) root.createFromBinding(modelData)
                      Keys.onSpacePressed: if (actionable) root.createFromBinding(modelData)
                      Accessible.role: actionable ? Accessible.Button : Accessible.StaticText
                      Accessible.name: modelData.description + ", " + modelData.keys
                      Accessible.description: actionable ? "Create an overriding routine" : "Read-only effective binding"

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(12)
                        anchors.rightMargin: Style.space(12)
                        spacing: Style.space(12)

                        Column {
                          id: bindingText
                          width: parent.width - keyRow.width - parent.spacing
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(2)
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: modelData.description
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            elide: Text.ElideRight
                          }
                          Text {
                            textFormat: Text.PlainText
                            text: modelData.managed ? "OMA MANAGED"
                              : (modelData.editable === false ? "READ ONLY / POINTER INPUT" : "EXISTING CONFIGURATION")
                            color: modelData.managed ? Color.accent : Qt.darker(Color.foreground, 1.7)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.letterSpacing: 0.7
                          }
                        }

                        Row {
                          id: keyRow
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(4)
                          Repeater {
                            model: modelData.keys.split(" + ")
                            BorderSurface {
                              required property string modelData
                              implicitWidth: cap.implicitWidth + Style.space(12)
                              height: Style.space(24)
                              color: Util.alpha(Color.foreground, 0.055)
                              borderSpec: Border.flat(Util.alpha(Color.foreground, 0.22), 1)
                              radius: Math.min(Style.cornerRadius, Style.space(4))
                              Text {
                                textFormat: Text.PlainText
                                id: cap
                                anchors.centerIn: parent
                                text: modelData.toUpperCase()
                                color: Color.foreground
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: true
                              }
                            }
                          }
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: parent.actionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: if (parent.actionable) root.createFromBinding(modelData)
                      }
                    }
                  }
                }
              }

              Item {
                anchors.fill: parent
                visible: root.activeView === "routines"

                Row {
                  anchors.fill: parent
                  spacing: Style.space(14)

                  BorderSurface {
                    id: routineSidebar
                    visible: !root.compact || !root.compactEditorOpen
                    width: root.compact ? parent.width : Style.space(254)
                    height: parent.height
                    radius: Style.cornerRadius
                    color: Util.alpha(Color.foreground, 0.025)
                    borderSpec: Border.flat(Util.alpha(Color.foreground, 0.13), 1)

                    Column {
                      anchors.fill: parent
                      anchors.margins: Style.space(10)
                      spacing: Style.space(8)

                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        Button {
                          width: (parent.width - parent.spacing) / 2
                          text: "Mic template"
                          bordered: true
                          focusable: true
                          enabled: root.configLoaded && !root.mutating
                          onClicked: root.requestSelectDraft(Model.microphoneTemplate(root.config.routines))
                          Accessible.name: "Create microphone routine"
                          Accessible.role: Accessible.Button
                        }
                        Button {
                          width: (parent.width - parent.spacing) / 2
                          text: "Blank"
                          bordered: true
                          focusable: true
                          enabled: root.configLoaded && !root.mutating
                          onClicked: root.requestSelectDraft(Model.blankRoutine(root.config.routines))
                          Accessible.name: "Create blank routine"
                          Accessible.role: Accessible.Button
                        }
                      }

                      ChoicePicker {
                        width: parent.width
                        showLabel: false
                        value: ""
                        placeholderText: "Start from a mode template..."
                        enabled: root.configLoaded && !root.mutating
                        options: [
                          { value: "in-the-dark", label: "In the dark", description: "Night light and dimmer screen every evening" },
                          { value: "focus-at-work", label: "Focus at work", description: "Do not disturb and stay awake on weekdays" },
                          { value: "on-battery", label: "On battery", description: "Lower brightness below 30% battery" }
                        ]
                        onChanged: function(value) {
                          var routine = Model.templateRoutine(value, root.config.routines)
                          if (routine) root.requestSelectDraft(routine)
                        }
                        Accessible.name: "Create routine from template"
                      }

                      PanelSeparator { width: parent.width }

                      Text {

                        textFormat: Text.PlainText
                        visible: root.config.routines.length === 0
                        width: parent.width
                        text: "No routines yet. Start with the microphone template or a blank sequence."
                        color: Qt.darker(Color.foreground, 1.55)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                      }

                      ListView {
                        id: routineList
                        width: parent.width
                        height: parent.height - y
                        clip: true
                        spacing: Style.space(4)
                        model: root.config.routines
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: CursorSurface {
                          required property var modelData
                          required property int index
                          width: routineList.width
                          implicitHeight: routineRow.implicitHeight + Style.space(16)
                          current: modelData.id === root.selectedRoutineId
                          hasCursor: activeFocus
                          activeFocusOnTab: root.configLoaded && !root.mutating
                          Keys.onReturnPressed: root.requestSelectRoutine(modelData.id)
                          Keys.onEnterPressed: root.requestSelectRoutine(modelData.id)
                          Keys.onSpacePressed: root.requestSelectRoutine(modelData.id)
                          Accessible.role: Accessible.Button
                          Accessible.name: modelData.name
                          Accessible.description: Model.summarizeTriggers(modelData)
                            + (root.activeIds[modelData.id] ? ", active" : "")

                          Column {
                            id: routineRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.space(9)
                            anchors.rightMargin: Style.space(9)
                            spacing: Style.space(3)
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: modelData.name
                              color: modelData.enabled ? Color.foreground : Qt.darker(Color.foreground, 1.65)
                              font.family: Style.font.family
                              font.pixelSize: Style.font.body
                              font.bold: modelData.id === root.selectedRoutineId
                              elide: Text.ElideRight
                            }
                            Text {
                              textFormat: Text.PlainText
                              width: parent.width
                              text: Model.summarizeTriggers(modelData)
                              color: Qt.darker(Color.foreground, 1.65)
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                            }
                            Text {
                              textFormat: Text.PlainText
                              visible: !!root.activeIds[modelData.id]
                              width: parent.width
                              text: "ACTIVE"
                              color: Color.accent
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                              font.bold: true
                              font.letterSpacing: 0.7
                            }
                            Text {
                              textFormat: Text.PlainText
                              property var run: root.lastRunFor(modelData.id)
                              visible: !!run
                              width: parent.width
                              text: run ? (run.status.toUpperCase() + " / " + run.durationMs + " ms") : ""
                              color: run && run.status === "failed" ? Color.urgent : Color.accent
                              font.family: Style.font.family
                              font.pixelSize: Style.font.caption
                            }
                          }

                          MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.requestSelectRoutine(modelData.id)
                          }
                        }
                      }
                    }
                  }

                  RoutineEditor {
                    id: routineEditor
                    visible: !root.compact || root.compactEditorOpen
                    width: root.compact ? parent.width : parent.width - parent.spacing - routineSidebar.width
                    height: parent.height
                    routine: root.editorRoutine
                    bindings: root.bindings
                    appOptions: root.appOptions
                    commandOptions: root.commandOptions
                    themeOptions: root.themeOptions
                    wifiOptions: root.wifiOptions
                    toggleOptions: root.toggleOptions
                    isActive: !!(root.editorRoutine && root.activeIds[root.editorRoutine.id])
                    targetWindow: window
                    busy: root.uiLocked
                    persisted: root.editorPersisted
                    showBack: root.compact
                    onSaveRequested: function(routine) { root.saveRoutine(routine) }
                    onDeleteRequested: function(id) { root.requestDelete(id) }
                    onDuplicateRequested: function(id) { root.duplicateRoutine(id) }
                    onRunRequested: function(id) { root.runRoutine(id) }
                    onBackRequested: {
                      root.requestEditorBack()
                    }
                  }
                }
              }

              QQC.ScrollView {
                id: automationScroll
                anchors.fill: parent
                visible: root.activeView === "automations"
                clip: true
                contentWidth: availableWidth
                QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

                Column {
                  width: automationScroll.availableWidth
                  spacing: Style.space(10)

                  Repeater {
                    model: [
                      { event: "post-boot", number: "01", title: "After desktop starts", detail: "A clean place for session setup and launch routines." },
                      { event: "theme-set", number: "02", title: "Theme changed", detail: "Receives the active theme slug as argument 1." },
                      { event: "font-set", number: "03", title: "Font changed", detail: "Receives the selected font name as argument 1." },
                      { event: "battery-low", number: "04", title: "Battery low", detail: "Receives the remaining percentage as argument 1." },
                      { event: "post-update", number: "05", title: "After update", detail: "Runs after packages and migrations finish." },
                      { event: "pre-refresh-pacman", number: "06", title: "Before Pacman refresh", detail: "Runs immediately before repository configuration refresh." }
                    ]

                    BorderSurface {
                      required property var modelData
                      property var attachedRoutines: root.routinesForHook(modelData.event)
                      width: parent.width
                      implicitHeight: automationContent.implicitHeight + Style.space(22)
                      radius: Style.cornerRadius
                      color: Util.alpha(Color.foreground, 0.025)
                      borderSpec: Border.flat(Util.alpha(Color.foreground, 0.13), 1)

                      Row {
                        id: automationContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(14)
                        anchors.rightMargin: Style.space(14)
                        spacing: Style.space(16)

                        Text {

                          textFormat: Text.PlainText
                          text: modelData.number
                          color: Color.accent
                          font.family: Style.font.family
                          font.pixelSize: Style.font.title
                          font.bold: true
                        }
                        Column {
                          width: parent.width - Style.space(56) - attachedColumn.width
                          spacing: Style.space(3)
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: modelData.title
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                          }
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: modelData.detail
                            color: Qt.darker(Color.foreground, 1.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                          }
                        }
                        Column {
                          id: attachedColumn
                          width: Style.space(220)
                          spacing: Style.space(4)
                          Text {
                            textFormat: Text.PlainText
                            text: attachedRoutines.length
                              ? attachedRoutines.length + (attachedRoutines.length === 1 ? " ROUTINE" : " ROUTINES")
                              : "NO ROUTINES"
                            color: attachedRoutines.length ? Color.accent : Qt.darker(Color.foreground, 1.7)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 0.7
                          }
                          Repeater {
                            model: attachedRoutines
                            PlainTextButton {
                              required property var modelData
                              width: attachedColumn.width
                              plainText: modelData.name
                              leftAlign: true
                              focusable: true
                              onClicked: root.requestSelectRoutine(modelData.id)
                              Accessible.name: modelData.name
                              Accessible.role: Accessible.Button
                            }
                          }
                        }
                      }
                    }
                  }

                  PanelSectionHeader {
                    text: "CONDITIONS"
                    width: parent.width
                  }

                  BorderSurface {
                    width: parent.width
                    implicitHeight: serviceCardContent.implicitHeight + Style.space(24)
                    radius: Style.cornerRadius
                    color: Util.alpha(Color.accent, 0.035)
                    borderSpec: Border.flat(Util.alpha(Color.accent, 0.22), 1)
                    Column {
                      id: serviceCardContent
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(14)
                      anchors.rightMargin: Style.space(14)
                      spacing: Style.space(7)

                      Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(7)
                          height: width
                          radius: width / 2
                          color: root.serviceStatus && root.serviceStatus.enabled ? root.enabledGreen : Color.urgent
                        }

                        Text {
                          textFormat: Text.PlainText
                          text: root.serviceStatus && root.serviceStatus.enabled
                            ? "CONDITION SERVICE ONLINE"
                            : "CONDITION SERVICE PAUSED"
                          color: root.serviceStatus && root.serviceStatus.enabled ? root.enabledGreen : Color.urgent
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          font.letterSpacing: 0.7
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: root.serviceInputsText()
                        color: Qt.darker(Color.foreground, 1.35)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                      }
                    }
                  }

                  BorderSurface {
                    visible: root.conditionRoutines.length === 0
                    width: parent.width
                    implicitHeight: emptyConditionsContent.implicitHeight + Style.space(28)
                    radius: Style.cornerRadius
                    color: Util.alpha(Color.foreground, 0.025)
                    borderSpec: Border.flat(Util.alpha(Color.foreground, 0.13), 1)

                    Row {
                      id: emptyConditionsContent
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(14)
                      anchors.rightMargin: Style.space(14)
                      spacing: Style.space(14)

                      Text {
                        textFormat: Text.PlainText
                        text: "00"
                        color: Qt.darker(Color.foreground, 1.65)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.title
                        font.bold: true
                      }

                      Column {
                        width: parent.width - Style.space(210) - parent.spacing
                        spacing: Style.space(4)

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: "No condition routines yet"
                          color: Color.foreground
                          font.family: Style.font.family
                          font.pixelSize: Style.font.subtitle
                          font.bold: true
                        }

                        Text {
                          textFormat: Text.PlainText
                          width: parent.width
                          text: "Add a time, Wi-Fi, power, or Omarchy toggle condition. Omachord will start and end the routine automatically."
                          color: Qt.darker(Color.foreground, 1.55)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          wrapMode: Text.WordWrap
                        }
                      }

                      Button {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(164)
                        text: "Build a routine"
                        bordered: true
                        focusable: true
                        enabled: root.configLoaded && !root.mutating
                        onClicked: root.requestSelectDraft(Model.blankRoutine(root.config.routines))
                        Accessible.name: "Create a condition routine"
                        Accessible.role: Accessible.Button
                      }
                    }
                  }

                  Repeater {
                    model: root.conditionRoutines

                    BorderSurface {
                      required property var modelData
                      property var serviceState: root.serviceRoutineState(modelData.id)
                      width: parent.width
                      implicitHeight: conditionRow.implicitHeight + Style.space(22)
                      radius: Style.cornerRadius
                      color: Util.alpha(Color.foreground, 0.025)
                      borderSpec: Border.flat(Util.alpha(Color.foreground, 0.13), 1)

                      Row {
                        id: conditionRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(14)
                        anchors.rightMargin: Style.space(14)
                        spacing: Style.space(16)

                        Column {
                          width: parent.width - Style.space(140) - parent.spacing
                          spacing: Style.space(3)
                          PlainTextButton {
                            width: parent.width
                            plainText: modelData.name
                            leftAlign: true
                            focusable: true
                            onClicked: root.requestSelectRoutine(modelData.id)
                            Accessible.name: modelData.name
                            Accessible.role: Accessible.Button
                          }
                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            text: "If " + Model.summarizeConditions(modelData)
                            color: Qt.darker(Color.foreground, 1.55)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                          }
                        }
                        Text {
                          textFormat: Text.PlainText
                          width: Style.space(140)
                          text: root.activeIds[modelData.id]
                            ? "ACTIVE"
                            : (!modelData.enabled ? "DISABLED"
                              : (serviceState && serviceState.matched === true ? "MATCHED"
                                : (serviceState && serviceState.matched === false ? "WAITING" : "NOT EVALUATED")))
                          color: root.activeIds[modelData.id] ? Color.accent : Qt.darker(Color.foreground, 1.7)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          font.letterSpacing: 0.7
                          horizontalAlignment: Text.AlignRight
                        }
                      }
                    }
                  }

                  Item { width: 1; height: Style.space(12) }
                }
              }
            }

            BorderSurface {
              id: noticeBar
              visible: root.noticeText !== ""
              width: parent.width
              implicitHeight: notice.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: root.noticeError ? Util.alpha(Color.urgent, 0.08) : Util.alpha(Color.accent, 0.055)
              borderSpec: Border.flat(root.noticeError ? Util.alpha(Color.urgent, 0.5) : Util.alpha(Color.accent, 0.35), 1)
              Text {
                textFormat: Text.PlainText
                id: notice
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                text: root.noticeText
                color: root.noticeError ? Color.urgent : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 100
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
