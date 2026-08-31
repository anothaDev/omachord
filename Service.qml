import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Services.UPower
import "Conditions.js" as Conditions

// Headless condition watcher loaded by omarchy-shell as the plugin's
// "service" kind. It only decides *when* a routine should start or end;
// every change goes through bin/omachord, which owns validation, locking,
// snapshots, and restore.
Item {
  id: root

  // Injected by omarchy-shell when the property exists.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string stateDir: Quickshell.env("OMACHORD_STATE_DIR") || (stateHome + "/omarchy/omachord")
  readonly property string configPath: Quickshell.env("OMACHORD_CONFIG_FILE") || (home + "/.config/omarchy/omachord.json")
  readonly property string togglesDir: stateHome + "/omarchy/toggles"
  readonly property string runnerPath: Quickshell.env("OMACHORD_RUNNER_PATH")
    || (manifest && manifest.__sourceDir
      ? String(manifest.__sourceDir) + "/bin/omachord"
      : home + "/.config/omarchy/plugins/anothadev.omachord/bin/omachord")

  readonly property int safetyMs: 60000
  readonly property int reconcileMs: 300000
  readonly property int failureRetryMs: 300000
  readonly property int maxPending: 256

  property bool enabled: false
  property string disabledReason: "starting"
  property bool configLoaded: false
  property string configRevision: ""
  property var routines: []
  property bool activeLoaded: false
  property var active: ({})
  property var latched: ({})
  property var failures: ({})
  property bool latchesSeeded: false
  property var pendingLogs: null
  property var seenLogs: ({})
  property var toggles: ({})
  property var pending: []
  property var currentJob: null
  property var awaitingDeactivation: ({})
  property string lastEvent: "starting"
  property string lastEventAt: ""
  property var lastResult: null
  property real lastTick: Date.now()
  property real lastReconcile: 0

  // ------------------------------------------------------------ inputs
  readonly property bool wifiAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: findWifiDevice()
  readonly property var wifiNetworks: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
  readonly property string ssid: connectedSsid()
  readonly property bool onBattery: UPower.onBattery
  readonly property int batteryPercent: UPower.displayDevice && UPower.displayDevice.isPresent
    ? Math.round(Number(UPower.displayDevice.percentage || 0) * 100) : -1

  onSsidChanged: scheduleEvaluate()
  onOnBatteryChanged: scheduleEvaluate()
  onBatteryPercentChanged: scheduleEvaluate()
  onWifiAvailableChanged: scheduleEvaluate()

  function findWifiDevice() {
    if (!wifiAvailable) return null
    var devices = networkDevices || []
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || device.type !== DeviceType.Wifi) continue
      if (device.connected) return device
      if (!fallback) fallback = device
    }
    return fallback
  }

  // Only the name leaves this function: WifiNetwork objects come and go with
  // NetworkManager scans, so nothing else keeps a reference to one.
  function connectedSsid() {
    var networks = wifiNetworks || []
    for (var i = 0; i < networks.length; i++)
      if (networks[i] && networks[i].connected) return String(networks[i].name || "")
    return ""
  }

  function nowIso() {
    return new Date().toISOString()
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    lastEventAt = nowIso()
    lastEvent = event + suffix
    console.log("omachord " + lastEventAt + " " + lastEvent)
  }

  function parseJson(text, fallback) {
    try { return JSON.parse(String(text || "")) } catch (e) { return fallback }
  }

  function currentEnv(now) {
    return {
      now: now,
      ssid: ssid || null,
      wifiAvailable: wifiAvailable,
      onBattery: onBattery,
      batteryPercent: batteryPercent,
      toggles: toggles
    }
  }

  // ------------------------------------------------------- refreshing
  function refresh(process) {
    if (process.running) {
      process.refreshQueued = true
      return
    }
    process.refreshQueued = false
    process.startPending = true
    process.running = true
  }

  function finishRefresh(process) {
    if (!process.refreshQueued) return
    process.refreshQueued = false
    Qt.callLater(function() {
      if (process.running) process.refreshQueued = true
      else {
        process.startPending = true
        process.running = true
      }
    })
  }

  function failedRefreshStart(process, kind) {
    if (!process.startPending || process.running) return
    process.startPending = false
    if (kind === "status") applyStatus(null)
    else if (kind === "config") applyConfig(null)
    finishRefresh(process)
    scheduleEvaluate()
  }

  function finishAutostart(text, exitCode) {
    autostartProc.startPending = false
    var parsed = exitCode === 0 ? parseJson(text, null) : null
    if (parsed && parsed.disabled === true) logEvent("autostart", "disabled by user")
    else if (parsed && parsed.connected === true) logEvent("autostart", "connected")
    else logEvent("autostart", parsed && parsed.error ? parsed.error : "unavailable")
    reconcile("autostart")
  }

  function reconcile(why) {
    lastReconcile = Date.now()
    logEvent("reconcile", why)
    refresh(statusProc)
    refresh(configProc)
    refresh(activeProc)
    refresh(togglesProbe)
    if (!latchesSeeded) refresh(logsProc)
  }

  function applyStatus(parsed) {
    var ready = !!parsed && parsed.ok === true && parsed.integrationComplete === true
    if (ready !== enabled) logEvent(ready ? "enabled" : "disabled", ready ? "" : "not connected")
    enabled = ready
    disabledReason = ready ? "" : (parsed && parsed.ok ? "not connected" : "runner status unavailable")
  }

  function applyConfig(parsed) {
    if (!parsed || parsed.ok !== true || parsed.committed !== true || !parsed.config
        || !Array.isArray(parsed.config.routines)) {
      configLoaded = false
      routines = []
      configRevision = ""
      return
    }
    var rows = []
    for (var i = 0; i < parsed.config.routines.length; i++) {
      var routine = parsed.config.routines[i]
      if (!routine || routine.enabled !== true) continue
      if (!Array.isArray(routine.conditions) || routine.conditions.length === 0) continue
      rows.push(routine)
    }
    routines = rows
    configRevision = String(parsed.revision || "")
    configLoaded = true
    var revisionLatches = Object.assign({}, latched)
    var revisionFailures = Object.assign({}, failures)
    for (var failed in revisionFailures) {
      if (String(revisionFailures[failed].revision || "") === configRevision) continue
      if (revisionFailures[failed].op === "activate") delete revisionLatches[failed]
      delete revisionFailures[failed]
    }
    latched = revisionLatches
    failures = revisionFailures
    pruneLatches()
    if (pendingLogs) {
      var queued = pendingLogs
      pendingLogs = null
      applyLogs(queued)
    }
  }

  // Latches only make sense for routines that still have conditions.
  function pruneLatches() {
    var keep = ({})
    for (var i = 0; i < routines.length; i++) keep[String(routines[i].id)] = true
    var nextLatched = ({})
    var nextFailures = ({})
    for (var id in latched) if (keep[id]) nextLatched[id] = latched[id]
    for (var failed in failures) if (keep[failed]) nextFailures[failed] = failures[failed]
    latched = nextLatched
    failures = nextFailures
  }

  // A shell restart forgets which routines already fired or were ended by
  // hand; the runner's history is the durable record of both.
  function applyLogs(rows) {
    if (!configLoaded) return
    if (!latchesSeeded) {
      var seeded = Conditions.seedLatches(routines, rows, new Date())
      var initial = Object.assign({}, latched)
      for (var id in seeded) initial[id] = true
      latched = initial
      latchesSeeded = true
      var initialSeen = ({})
      for (var s = 0; s < rows.length; s++) initialSeen[JSON.stringify(rows[s])] = true
      seenLogs = initialSeen
      logEvent("latches-seeded", Object.keys(seeded).join(" ") || "none")
      return
    }
    if (!rows.length) return
    var known = seenLogs
    for (var entry = rows.length - 1; entry >= 0; entry--) {
      var signature = JSON.stringify(rows[entry])
      if (!known[signature]) applyLiveLog(rows[entry])
    }
    var current = ({})
    for (var seen = 0; seen < rows.length; seen++) current[JSON.stringify(rows[seen])] = true
    seenLogs = current
  }

  function applyLiveLog(entry) {
    var trigger = String(entry.trigger || "")
    var status = String(entry.status || "")
    var routineId = String(entry.routineId || "")
    if (status === "deactivated" && trigger !== "condition" && trigger !== "service") {
      for (var r = 0; r < routines.length; r++) {
        if (String(routines[r].id) !== routineId) continue
        if (Conditions.evaluateAll(routines[r].conditions, currentEnv(new Date())) === true) latch(routineId)
        break
      }
    } else if (status === "failed" && trigger !== "condition" && trigger !== "service"
        && String(entry.error || "").indexOf("activate:") === 0
        && String(entry.error || "").indexOf("recovery record kept") === -1) {
      unlatch(routineId)
    }
  }

  function applyActive(rows, generation) {
    var next = ({})
    for (var i = 0; i < rows.length; i++)
      if (rows[i] && rows[i].routineId) next[String(rows[i].routineId)] = rows[i]
    var waiting = Object.assign({}, awaitingDeactivation)
    for (var id in waiting) {
      if (generation < waiting[id]) delete next[id]
      else delete waiting[id]
    }
    awaitingDeactivation = waiting
    active = next
    activeLoaded = true
  }

  function applyToggles(text) {
    var lines = String(text || "").split("\n")
    var next = ({})
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name) next[name] = true
    }
    toggles = next
  }

  // ------------------------------------------------------- evaluation
  function scheduleEvaluate() {
    debounceTimer.restart()
  }

  function evaluate() {
    if (!enabled || !configLoaded || !activeLoaded || !latchesSeeded) {
      pending = []
      armBoundaryTimer(new Date())
      return
    }
    var now = new Date()
    var env = currentEnv(now)
    var deactivatingId = currentJob && currentJob.op === "deactivate" ? currentJob.id : ""
    var observed = Conditions.observedActiveIds(routines, env, active, deactivatingId)
    if (observed.length) {
      var observedLatches = Object.assign({}, latched)
      for (var a = 0; a < observed.length; a++) observedLatches[observed[a]] = true
      latched = observedLatches
    }
    var plan = Conditions.desiredTransitions(routines, env, active, latched)
    if (plan.release.length) {
      var released = Object.assign({}, latched)
      var retry = Object.assign({}, failures)
      for (var r = 0; r < plan.release.length; r++) {
        delete released[plan.release[r]]
        if (retry[plan.release[r]] && retry[plan.release[r]].op === "activate")
          delete retry[plan.release[r]]
      }
      latched = released
      failures = retry
    }
    var desired = plan.transitions.slice()
    var expired = Conditions.expiredIds(active, now)
    for (var e = 0; e < expired.length; e++) {
      latch(expired[e])
      desired.push({ id: expired[e], op: "deactivate", reason: "timer" })
    }
    var retainedFailures = Object.assign({}, failures)
    for (var failed in retainedFailures) {
      if (retainedFailures[failed].op !== "deactivate") continue
      var stillDesired = false
      for (var d = 0; d < desired.length; d++) {
        if (desired[d].id === failed && desired[d].op === "deactivate") {
          stillDesired = true
          break
        }
      }
      if (!stillDesired) delete retainedFailures[failed]
    }
    failures = retainedFailures
    pending = Conditions.reconcileJobs(desired, currentJob, configRevision, failures,
      now.getTime(), failureRetryMs, maxPending)
    armBoundaryTimer(now)
    runNext()
  }

  function armBoundaryTimer(now) {
    boundaryTimer.stop()
    boundaryTimer.interval = Conditions.settleMs(
      Conditions.nextTimeBoundaryMs(routines, now),
      nextExpiryDelay(now),
      safetyMs)
    boundaryTimer.start()
  }

  function nextExpiryDelay(now) {
    var next = Conditions.nextExpiryMs(active, now)
    if (next !== 0) return next
    var expired = Conditions.expiredIds(active, now)
    for (var i = 0; i < expired.length; i++) {
      var failure = failures[expired[i]]
      if (!failure || failure.op !== "deactivate" || failure.revision !== configRevision
          || now.getTime() - Number(failure.at) >= failureRetryMs) return 0
    }
    return null
  }

  function tick() {
    var now = Date.now()
    var gap = now - lastTick
    lastTick = now
    var expiredFailures = Object.assign({}, failures)
    var changed = false
    for (var id in expiredFailures) {
      if (now - Number(expiredFailures[id].at) < failureRetryMs) continue
      var operation = expiredFailures[id].op
      delete expiredFailures[id]
      if (operation === "activate") unlatch(id)
      changed = true
    }
    if (changed) failures = expiredFailures
    if (gap > 3 * safetyMs) {
      reconcile("resume after " + Math.round(gap / 1000) + "s")
      return
    }
    if (now - lastReconcile > reconcileMs) {
      reconcile("periodic")
      return
    }
    refresh(togglesProbe)
    scheduleEvaluate()
  }

  function latch(id) {
    var next = Object.assign({}, latched)
    next[String(id)] = true
    latched = next
  }

  function unlatch(id) {
    if (!latched[String(id)]) return
    var next = Object.assign({}, latched)
    delete next[String(id)]
    latched = next
  }

  // ------------------------------------------------------- execution
  function runNext() {
    if (runnerProc.running || currentJob || !pending.length) return
    if (!enabled) {
      pending = []
      return
    }
    var job = pending[0]
    pending = pending.slice(1)
    if (job.revision !== configRevision) {
      logEvent("runner-discard", job.op + " " + job.id + " stale revision")
      scheduleEvaluate()
      return
    }
    currentJob = job
    logEvent("runner-start", job.op + " " + job.id + " " + job.reason)
    runnerProc.command = [root.runnerPath, job.op, job.id, job.reason, job.revision]
    runnerProc.running = true
  }

  function finishJob(text, exitCode) {
    var job = currentJob
    currentJob = null
    var parsed = parseJson(text, null)
    lastResult = parsed || { ok: false, error: "runner exited " + exitCode }
    if (!job) return
    var ok = exitCode === 0 && !!parsed && parsed.ok === true
    logEvent("runner-exit", job.op + " " + job.id + " " + (ok ? "ok" : "failed: " + (parsed && parsed.error ? parsed.error : exitCode)))
    if (ok) {
      if (job.op === "activate") latch(job.id)
      if (job.op === "deactivate") {
        var waiting = Object.assign({}, awaitingDeactivation)
        waiting[job.id] = activeProc.generation + 1
        awaitingDeactivation = waiting
        var optimisticActive = Object.assign({}, active)
        delete optimisticActive[job.id]
        active = optimisticActive
      }
      var cleared = Object.assign({}, failures)
      if (cleared[job.id] && cleared[job.id].op === job.op) delete cleared[job.id]
      failures = cleared
    }
    if (!ok) {
      // Do not hammer the runner while the cause persists (a stopped shell, a
      // restore that could not complete); retry after the failure window or
      // once the conditions have gone false.
      var next = Object.assign({}, failures)
      if (job.revision === configRevision) {
        if (job.op === "activate") latch(job.id)
        next[job.id] = { at: Date.now(), op: job.op, revision: job.revision }
        failures = next
      }
      if (parsed && parsed.code === "stale-config") refresh(configProc)
    }
    refresh(activeProc)
  }

  function statusJson() {
    var now = new Date()
    var env = currentEnv(now)
    var rows = []
    for (var i = 0; i < routines.length; i++)
      rows.push(Conditions.routineSummary(routines[i], env, active, latched))
    return JSON.stringify({
      ready: configLoaded && activeLoaded && latchesSeeded,
      enabled: enabled,
      reason: enabled ? "" : disabledReason,
      runnerPath: runnerPath,
      configRevision: configRevision,
      env: {
        ssid: env.ssid,
        wifiAvailable: env.wifiAvailable,
        onBattery: env.onBattery,
        batteryPercent: env.batteryPercent,
        toggles: Object.keys(toggles)
      },
      routines: rows,
      activeCount: Object.keys(active).length,
      queue: pending.length,
      running: runnerProc.running,
      lastEvent: lastEvent,
      lastEventAt: lastEventAt,
      lastResult: lastResult
    })
  }

  // ------------------------------------------------------- processes
  Process {
    id: autostartProc
    property bool startPending: false
    command: [root.runnerPath, "autostart"]
    stdout: StdioCollector { id: autostartStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.finishAutostart(autostartStdout.text, exitCode)
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() {
        if (autostartProc.startPending && !autostartProc.running)
          root.finishAutostart("", -1)
      })
  }

  Process {
    id: statusProc
    property bool refreshQueued: false
    property bool startPending: false
    command: [root.runnerPath, "status"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      statusProc.startPending = false
      root.applyStatus(exitCode === 0 ? root.parseJson(statusStdout.text, null) : null)
      root.finishRefresh(statusProc)
      root.scheduleEvaluate()
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() { root.failedRefreshStart(statusProc, "status") })
  }

  Process {
    id: configProc
    property bool refreshQueued: false
    property bool startPending: false
    command: [root.runnerPath, "config", "snapshot"]
    stdout: StdioCollector { id: configStdout; waitForEnd: true }
    onExited: function(exitCode) {
      configProc.startPending = false
      root.applyConfig(exitCode === 0 ? root.parseJson(configStdout.text, null) : null)
      root.finishRefresh(configProc)
      root.scheduleEvaluate()
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() { root.failedRefreshStart(configProc, "config") })
  }

  Process {
    id: activeProc
    property bool refreshQueued: false
    property bool startPending: false
    property int generation: 0
    command: [root.runnerPath, "active"]
    stdout: StdioCollector { id: activeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      activeProc.startPending = false
      if (exitCode === 0) {
        var parsed = root.parseJson(activeStdout.text, null)
        if (Array.isArray(parsed)) root.applyActive(parsed, activeProc.generation)
      }
      root.finishRefresh(activeProc)
      root.scheduleEvaluate()
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() { root.failedRefreshStart(activeProc, "active") })
    onStarted: generation++
  }

  Process {
    id: logsProc
    property bool refreshQueued: false
    property bool startPending: false
    command: [root.runnerPath, "logs", "200"]
    stdout: StdioCollector { id: logsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      logsProc.startPending = false
      if (exitCode === 0) {
        var parsed = root.parseJson(logsStdout.text, null)
        if (Array.isArray(parsed)) {
          if (root.configLoaded) root.applyLogs(parsed)
          else root.pendingLogs = parsed
        }
      }
      root.finishRefresh(logsProc)
      root.scheduleEvaluate()
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() { root.failedRefreshStart(logsProc, "logs") })
  }

  Process {
    id: togglesProbe
    property bool refreshQueued: false
    property bool startPending: false
    command: ["find", root.togglesDir, "-mindepth", "1", "-maxdepth", "1", "-type", "f", "-printf", "%f\n"]
    stdout: StdioCollector { id: togglesStdout; waitForEnd: true }
    onExited: function(exitCode) {
      togglesProbe.startPending = false
      root.applyToggles(exitCode === 0 ? togglesStdout.text : "")
      root.finishRefresh(togglesProbe)
      root.scheduleEvaluate()
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() { root.failedRefreshStart(togglesProbe, "toggles") })
  }

  Process {
    id: runnerProc
    stdout: StdioCollector { id: runnerStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.finishJob(runnerStdout.text, exitCode)
    }
    onRunningChanged: {
      if (!running && root.currentJob) {
        Qt.callLater(function() {
          if (root.currentJob && !runnerProc.running) root.finishJob("", -1)
        })
      }
    }
  }

  // ------------------------------------------------------- watchers
  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh(configProc)
  }

  FileView {
    path: root.stateDir + "/config.commit.json"
    watchChanges: true
    printErrors: false
    onFileChanged: {
      root.refresh(configProc)
      root.refresh(statusProc)
    }
  }

  FileView {
    path: root.stateDir + "/connection.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh(statusProc)
  }

  FileView {
    path: root.stateDir + "/active"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh(activeProc)
  }

  FileView {
    path: root.stateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh(logsProc)
  }

  FileView {
    path: root.stateDir + "/runs.jsonl"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh(logsProc)
  }

  FileView {
    path: root.togglesDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh(togglesProbe)
  }

  Timer {
    id: debounceTimer
    interval: 250
    repeat: false
    onTriggered: root.evaluate()
  }

  Timer {
    id: boundaryTimer
    interval: root.safetyMs
    repeat: false
    onTriggered: root.tick()
  }

  Component.onCompleted: {
    logEvent("service-ready", runnerPath)
    autostartProc.startPending = true
    autostartProc.running = true
  }

  IpcHandler {
    target: "omachord"

    function status(): string {
      return root.statusJson()
    }

    function evaluate(): string {
      root.scheduleEvaluate()
      return "scheduled"
    }

    function reload(): string {
      root.reconcile("ipc")
      return "reloading"
    }
  }
}
