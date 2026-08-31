// Pure condition evaluation shared by Service.qml and the Node test suite.
// Nothing here touches Qt; the service feeds it an environment snapshot.

var WEEKDAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
var DAY_MS = 86400000

function parseHHMM(text) {
  var match = /^([01][0-9]|2[0-3]):([0-5][0-9])$/.exec(String(text || ""))
  return match ? Number(match[1]) * 60 + Number(match[2]) : -1
}

function minutesOfDay(date) {
  return date.getHours() * 60 + date.getMinutes()
}

// A window is inclusive of its start minute and exclusive of its end minute.
// When it crosses midnight the weekday test applies to the day it started on.
function timeMatches(condition, now) {
  var start = parseHHMM(condition.start)
  var end = parseHHMM(condition.end)
  if (start < 0 || end < 0 || start === end) return false
  var minute = minutesOfDay(now)
  var startDayOffset = 0
  var inside
  if (start < end) {
    inside = minute >= start && minute < end
  } else if (minute >= start) {
    inside = true
  } else if (minute < end) {
    inside = true
    startDayOffset = -1
  } else {
    inside = false
  }
  if (!inside) return false
  var weekdays = Array.isArray(condition.weekdays) ? condition.weekdays : []
  if (!weekdays.length) return true
  var day = new Date(now.getTime())
  day.setDate(day.getDate() + startDayOffset)
  return weekdays.indexOf(WEEKDAY_KEYS[day.getDay()]) !== -1
}

function wifiMatches(condition, ssid) {
  if (!ssid) return false
  var names = Array.isArray(condition.ssids) ? condition.ssids : []
  return names.indexOf(String(ssid)) !== -1
}

// An unknown battery level never satisfies a threshold.
function powerMatches(condition, onBattery, percent) {
  if (condition.source === "ac") return !onBattery
  if (condition.source !== "battery" || !onBattery) return false
  var below = Number(condition.batteryBelow || 0)
  if (below <= 0) return true
  return typeof percent === "number" && percent >= 0 && percent < below
}

function toggleMatches(condition, toggles) {
  return !!(toggles && toggles[String(condition.flag || "")] === true)
}

function evaluate(condition, env) {
  if (!condition) return false
  switch (condition.type) {
    case "time": return timeMatches(condition, env.now)
    case "wifi": return env.wifiAvailable !== false && wifiMatches(condition, env.ssid)
    case "power": return powerMatches(condition, env.onBattery === true, env.batteryPercent)
    case "omarchy-toggle": return toggleMatches(condition, env.toggles)
  }
  return false
}

// true when every condition holds, false when any fails, null when the
// routine has no conditions and is therefore not condition-driven.
function evaluateAll(conditions, env) {
  if (!Array.isArray(conditions) || conditions.length === 0) return null
  for (var i = 0; i < conditions.length; i++)
    if (!evaluate(conditions[i], env)) return false
  return true
}

function msUntilMinute(now, minute) {
  var target = new Date(now.getTime())
  target.setHours(Math.floor(minute / 60), minute % 60, 0, 0)
  var diff = target.getTime() - now.getTime()
  if (diff <= 0) diff += DAY_MS
  return diff
}

// Milliseconds until the nearest start or end edge of any time condition,
// or null when no time condition exists.
function nextTimeBoundaryMs(routines, now) {
  var best = null
  for (var r = 0; r < routines.length; r++) {
    var conditions = routines[r] && Array.isArray(routines[r].conditions) ? routines[r].conditions : []
    for (var c = 0; c < conditions.length; c++) {
      if (conditions[c].type !== "time") continue
      var edges = [parseHHMM(conditions[c].start), parseHHMM(conditions[c].end)]
      for (var e = 0; e < edges.length; e++) {
        if (edges[e] < 0) continue
        var ms = msUntilMinute(now, edges[e])
        if (best === null || ms < best) best = ms
      }
    }
  }
  return best
}

function msSinceMinute(now, minute) {
  var target = new Date(now.getTime())
  target.setHours(Math.floor(minute / 60), minute % 60, 0, 0)
  var diff = now.getTime() - target.getTime()
  if (diff < 0) diff += DAY_MS
  return diff
}

// Milliseconds since the most recent start or end edge of a routine's time
// conditions, or a full day when it has none. A run-history entry older than
// this predates the current true period and must not be treated as a latch.
function latchHorizonMs(routine, now) {
  var best = DAY_MS
  var conditions = routine && Array.isArray(routine.conditions) ? routine.conditions : []
  for (var c = 0; c < conditions.length; c++) {
    if (conditions[c].type !== "time") continue
    var edges = [parseHHMM(conditions[c].start), parseHHMM(conditions[c].end)]
    for (var e = 0; e < edges.length; e++) {
      if (edges[e] < 0) continue
      var ms = msSinceMinute(now, edges[e])
      if (ms < best) best = ms
    }
  }
  return best
}

// Rebuilds the latch set after a service restart from the runner's history:
// a routine whose latest entry is a non-service deactivation, or a run that
// already happened for this true period, must not fire again until its
// conditions have been false once.
function seedLatches(routines, logs, now) {
  var latched = {}
  var latest = {}
  for (var i = 0; i < (logs || []).length; i++) {
    var entry = logs[i]
    if (!entry || !entry.routineId || latest[entry.routineId]) continue
    latest[String(entry.routineId)] = entry
  }
  for (var r = 0; r < routines.length; r++) {
    var routine = routines[r]
    if (!routine || !routine.id) continue
    if (!Array.isArray(routine.conditions) || routine.conditions.length === 0) continue
    var id = String(routine.id)
    var entry = latest[id]
    if (!entry) continue
    var at = Date.parse(String(entry.timestamp || ""))
    if (isNaN(at) || now.getTime() - at > latchHorizonMs(routine, now)) continue
    var trigger = String(entry.trigger || "")
    var status = String(entry.status || "")
    if (status === "deactivated" && trigger !== "condition") latched[id] = true
    else if (trigger === "condition" && (status === "success" || status === "failed")) latched[id] = true
  }
  return latched
}

function expiryMs(snapshot) {
  if (!snapshot || typeof snapshot.expiresAt !== "string") return null
  var parsed = Date.parse(snapshot.expiresAt)
  return isNaN(parsed) ? null : parsed
}

function expiredIds(active, now) {
  var ids = []
  for (var id in active) {
    var at = expiryMs(active[id])
    if (at !== null && at <= now.getTime()) ids.push(id)
  }
  return ids
}

function nextExpiryMs(active, now) {
  var best = null
  for (var id in active) {
    var at = expiryMs(active[id])
    if (at === null) continue
    var diff = at - now.getTime()
    if (diff <= 0) diff = 0
    if (best === null || diff < best) best = diff
  }
  return best
}

// Only activations the service made itself, that are still meant to follow
// their conditions, are ended when those conditions stop matching.
function conditionOwned(snapshot) {
  if (!snapshot) return false
  var trigger = String(snapshot.trigger || "")
  return (trigger === "condition" || trigger === "service") && snapshot.keepUntil === "conditions"
}

// latched: routine ids that already fired for the current true period, so a
// routine runs once per edge and a manual deactivation is not undone until
// its conditions have been false at least once.
function desiredTransitions(routines, env, active, latched) {
  var transitions = []
  var release = []
  for (var i = 0; i < routines.length; i++) {
    var routine = routines[i]
    if (!routine || routine.enabled === false) continue
    var id = String(routine.id)
    var matched = evaluateAll(routine.conditions, env)
    if (matched === null) continue
    var snapshot = active ? active[id] : null
    if (matched) {
      if (!snapshot && !(latched && latched[id])) transitions.push({ id: id, op: "activate", reason: "condition" })
    } else {
      if (latched && latched[id]) release.push(id)
      if (snapshot && conditionOwned(snapshot)) transitions.push({ id: id, op: "deactivate", reason: "condition" })
    }
  }
  return { transitions: transitions, release: release }
}

// Active routines observed while their conditions hold must latch even when
// they were started outside the service. This prevents a manual end from being
// immediately undone before the conditions have gone false once.
function observedActiveIds(routines, env, active, deactivatingId) {
  var ids = []
  for (var i = 0; i < routines.length; i++) {
    var routine = routines[i]
    if (!routine || !routine.id || !active || !active[String(routine.id)]) continue
    if (String(routine.id) === String(deactivatingId || "")) continue
    if (evaluateAll(routine.conditions, env) === true) ids.push(String(routine.id))
  }
  return ids
}

// The pending queue is a projection of what is desired now, not an append-only
// event log. Recomputing it drops transitions invalidated while another job ran.
function reconcileJobs(transitions, currentJob, revision, failures, nowMs, retryMs, maxPending) {
  var order = []
  var jobs = {}
  for (var i = 0; i < transitions.length; i++) {
    var transition = transitions[i]
    if (!transition || !transition.id || !transition.op) continue
    var id = String(transition.id)
    var op = String(transition.op)
    if (currentJob && String(currentJob.id) === id && String(currentJob.op) === op) continue
    var failure = failures ? failures[id] : null
    if (failure && String(failure.op) === op && String(failure.revision) === String(revision)
        && nowMs - Number(failure.at) < retryMs) continue
    if (!jobs[id]) order.push(id)
    jobs[id] = {
      id: id,
      op: op,
      reason: String(transition.reason || "condition"),
      revision: String(revision || "")
    }
  }
  var rows = []
  for (var o = 0; o < order.length; o++) rows.push(jobs[order[o]])
  if (rows.length > maxPending) rows = rows.slice(rows.length - maxPending)
  return rows
}

// The next wake-up: just after the nearest edge, never later than the safety
// interval that also catches timer drift and suspend/resume.
function settleMs(nextBoundaryMs, nextExpiry, safetyMs) {
  var candidates = [safetyMs]
  if (nextBoundaryMs !== null && nextBoundaryMs !== undefined) candidates.push(nextBoundaryMs + 500)
  if (nextExpiry !== null && nextExpiry !== undefined) candidates.push(nextExpiry + 500)
  var best = safetyMs
  for (var i = 0; i < candidates.length; i++) if (candidates[i] < best) best = candidates[i]
  return Math.max(1000, best)
}

function routineSummary(routine, env, active, latched) {
  var id = String(routine.id)
  var snapshot = active ? active[id] : null
  return {
    id: id,
    conditions: Array.isArray(routine.conditions) ? routine.conditions.length : 0,
    matched: evaluateAll(routine.conditions, env),
    active: !!snapshot,
    trigger: snapshot ? snapshot.trigger : null,
    expiresAt: snapshot ? snapshot.expiresAt : null,
    latched: !!(latched && latched[id])
  }
}
