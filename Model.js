function clone(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value))
}

function codePointLength(value) {
  var text = String(value || "")
  var length = 0
  for (var i = 0; i < text.length; i++) {
    var first = text.charCodeAt(i)
    if (first >= 0xD800 && first <= 0xDBFF && i + 1 < text.length) {
      var second = text.charCodeAt(i + 1)
      if (second >= 0xDC00 && second <= 0xDFFF) i++
    }
    length++
  }
  return length
}

function truncateCodePoints(value, maximum) {
  var text = String(value || "")
  var end = 0
  var length = 0
  while (end < text.length && length < maximum) {
    var first = text.charCodeAt(end++)
    if (first >= 0xD800 && first <= 0xDBFF && end < text.length) {
      var second = text.charCodeAt(end)
      if (second >= 0xDC00 && second <= 0xDFFF) end++
    }
    length++
  }
  return text.slice(0, end)
}

function defaultConfig() {
  return { version: 1, routines: [] }
}

function slugify(value) {
  var slug = String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  slug = (slug || "routine").slice(0, 80).replace(/-+$/g, "")
  return slug || "routine"
}

function uniqueId(name, routines) {
  var base = slugify(name)
  var used = {}
  var list = routines || []
  for (var i = 0; i < list.length; i++) used[String(list[i].id)] = true
  if (!used[base]) return base
  var suffix = 2
  while (true) {
    var ending = "-" + suffix
    var prefix = base.slice(0, 80 - ending.length).replace(/-+$/g, "") || "routine"
    var candidate = prefix + ending
    if (!used[candidate]) return candidate
    suffix++
  }
}

function microphoneTemplate(routines) {
  return {
    id: uniqueId("Meeting microphone", routines),
    name: "Meeting microphone",
    enabled: true,
    triggers: [],
    actions: [{
      type: "microphone-toggle",
      sound: true,
      mutedSound: "/usr/share/sounds/freedesktop/stereo/service-logout.oga",
      liveSound: "/usr/share/sounds/freedesktop/stereo/service-login.oga"
    }]
  }
}

// The Omarchy events a routine can listen to. One list feeds the editor, the
// Activity view, and the README so their wording cannot drift.
var HOOKS = [
  { value: "post-boot", label: "After desktop starts", description: "Runs after the graphical session starts", glyph: "\u{F0425}" },
  { value: "theme-set", label: "Theme changed", description: "Theme slug is argument 1", glyph: "\u{F03D8}" },
  { value: "font-set", label: "Font changed", description: "Font name is argument 1", glyph: "\u{F0130}" },
  { value: "battery-low", label: "Battery low", description: "Battery percentage is argument 1", glyph: "\u{F0079}" },
  { value: "post-update", label: "After update", description: "Runs after packages and migrations", glyph: "\u{F0450}" },
  { value: "pre-refresh-pacman", label: "Before Pacman refresh", description: "Runs before repositories are refreshed", glyph: "\u{F0453}" }
]

function hookInfo(event) {
  for (var i = 0; i < HOOKS.length; i++) if (HOOKS[i].value === event) return HOOKS[i]
  return { value: String(event || ""), label: String(event || ""), description: "", glyph: "" }
}

// Curated starting points that mirror common phone "modes"; every template is
// a draft the user still names, tweaks, and saves.
var TEMPLATE_KEYS = ["in-the-dark", "focus-at-work", "on-battery"]

// Everything the "New routine" picker offers, blank and microphone included.
function templateOptions() {
  return [
    { value: "blank", label: "Blank routine", description: "Start from nothing" },
    { value: "microphone", label: "Meeting microphone", description: "Mute or unmute the microphone with a sound cue" },
    { value: "in-the-dark", label: "In the dark", description: "Night light and a dimmer screen every evening" },
    { value: "focus-at-work", label: "Focus at work", description: "Do not disturb and stay awake on weekdays" },
    { value: "on-battery", label: "On battery", description: "Lower brightness below 30% battery" }
  ]
}

function templateRoutine(key, routines) {
  switch (key) {
    case "blank": return blankRoutine(routines)
    case "microphone": return microphoneTemplate(routines)
    case "in-the-dark": return {
      id: uniqueId("In the dark", routines),
      name: "In the dark",
      enabled: true,
      triggers: [],
      conditions: [{ type: "time", start: "18:30", end: "08:00", weekdays: [] }],
      actions: [
        { type: "nightlight", value: true, restore: true },
        { type: "brightness", value: 40, restore: true }
      ]
    }
    case "focus-at-work": return {
      id: uniqueId("Focus at work", routines),
      name: "Focus at work",
      enabled: true,
      triggers: [],
      conditions: [{ type: "time", start: "09:00", end: "17:00", weekdays: ["mon", "tue", "wed", "thu", "fri"] }],
      actions: [
        { type: "dnd", value: true, restore: true },
        { type: "stay-awake", value: true, restore: true }
      ]
    }
    case "on-battery": return {
      id: uniqueId("On battery", routines),
      name: "On battery",
      enabled: true,
      triggers: [],
      conditions: [{ type: "power", source: "battery", batteryBelow: 30 }],
      actions: [
        { type: "brightness", value: 40, restore: true },
        { type: "notification", title: "Battery saver", body: "Brightness lowered until you plug in.", urgency: "low", glyph: "" }
      ]
    }
  }
  return null
}

function blankRoutine(routines) {
  return {
    id: uniqueId("New routine", routines),
    name: "New routine",
    enabled: true,
    triggers: [],
    actions: []
  }
}

function defaultAction(type) {
  switch (type) {
    case "microphone-toggle": return {
      type: type,
      sound: true,
      mutedSound: "/usr/share/sounds/freedesktop/stereo/service-logout.oga",
      liveSound: "/usr/share/sounds/freedesktop/stereo/service-login.oga"
    }
    case "launch-app": return { type: type, desktopId: "" }
    case "omarchy-command": return { type: type, route: "omarchy audio input mute", args: [] }
    case "notification": return { type: type, title: "Routine complete", body: "", urgency: "low", glyph: "" }
    case "osd": return { type: type, icon: "", message: "Routine complete", progress: -1, duration: 1200 }
    case "sound": return { type: type, path: "/usr/share/sounds/freedesktop/stereo/complete.oga" }
    case "delay": return { type: type, milliseconds: 500 }
    case "exec": return { type: type, program: "", args: [] }
    case "shell": return { type: type, command: "" }
    case "nightlight": return { type: type, value: true, restore: true }
    case "dnd": return { type: type, value: true, restore: true }
    case "stay-awake": return { type: type, value: true, restore: true }
    case "theme": return { type: type, value: "", restore: true }
    case "brightness": return { type: type, value: 50, restore: true }
  }
  return { type: type }
}

function normalizeChord(value) {
  var parts = String(value || "").replace(/\+/g, " ").trim().split(/\s+/)
  var mods = { SUPER: false, SHIFT: false, CTRL: false, ALT: false }
  var key = ""
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim().toUpperCase()
    if (!part) return ""
    if (part === "META" || part === "WIN") part = "SUPER"
    if (part === "CONTROL") part = "CTRL"
    if (mods[part] !== undefined) mods[part] = true
    else if (key) return ""
    else key = part
  }
  if (!key) return ""
  if (["COMMA", "PERIOD", "MINUS", "EQUAL", "SLASH"].indexOf(key) !== -1)
    key = key.toLowerCase()
  var output = []
  var order = ["SUPER", "SHIFT", "CTRL", "ALT"]
  for (var j = 0; j < order.length; j++) if (mods[order[j]]) output.push(order[j])
  output.push(key)
  return output.join(" + ")
}

function shortcutTrigger(routine) {
  var triggers = routine && routine.triggers ? routine.triggers : []
  for (var i = 0; i < triggers.length; i++)
    if (triggers[i].type === "shortcut") return triggers[i]
  return null
}

function hookValues(routine) {
  var values = []
  var triggers = routine && routine.triggers ? routine.triggers : []
  for (var i = 0; i < triggers.length; i++)
    if (triggers[i].type === "hook") values.push(triggers[i].event)
  return values
}

function setShortcut(routine, keys, override) {
  var next = clone(routine)
  var normalized = normalizeChord(keys)
  next.triggers = (next.triggers || []).filter(function(trigger) { return trigger.type !== "shortcut" })
  if (normalized) next.triggers.unshift({ type: "shortcut", keys: normalized, override: override === true })
  return next
}

function setHooks(routine, values) {
  var next = clone(routine)
  next.triggers = (next.triggers || []).filter(function(trigger) { return trigger.type !== "hook" })
  for (var i = 0; i < values.length; i++) next.triggers.push({ type: "hook", event: String(values[i]) })
  return next
}

function replaceRoutine(config, routine) {
  var next = clone(config || defaultConfig())
  var replaced = false
  for (var i = 0; i < next.routines.length; i++) {
    if (next.routines[i].id === routine.id) {
      next.routines[i] = clone(routine)
      replaced = true
      break
    }
  }
  if (!replaced) next.routines.push(clone(routine))
  return next
}

function removeRoutine(config, id) {
  var next = clone(config || defaultConfig())
  next.routines = next.routines.filter(function(routine) { return routine.id !== id })
  return next
}

function duplicateRoutine(config, id) {
  var next = clone(config || defaultConfig())
  for (var i = 0; i < next.routines.length; i++) {
    if (next.routines[i].id !== id) continue
    var copy = clone(next.routines[i])
    var suffix = " copy"
    var baseName = truncateCodePoints(copy.name || "Routine", 100 - suffix.length)
      .replace(/\s+$/g, "")
    copy.name = (baseName || "Routine") + suffix
    copy.id = uniqueId(copy.name, next.routines)
    copy.enabled = false
    next.routines.splice(i + 1, 0, copy)
    return { config: next, routine: copy }
  }
  return { config: next, routine: null }
}

function moveAction(routine, index, delta) {
  var next = clone(routine)
  var target = index + delta
  if (index < 0 || target < 0 || index >= next.actions.length || target >= next.actions.length) return next
  var action = next.actions[index]
  next.actions[index] = next.actions[target]
  next.actions[target] = action
  return next
}

function filterBindings(bindings, query, filter) {
  var q = String(query || "").toLowerCase()
  var mode = filter || "all"
  return (bindings || []).filter(function(binding) {
    if (mode === "managed" && !binding.managed) return false
    if (mode === "existing" && binding.managed) return false
    return !q || String(binding.keys).toLowerCase().indexOf(q) !== -1
      || String(binding.description).toLowerCase().indexOf(q) !== -1
  })
}

function conflictFor(bindings, keys) {
  var normalized = normalizeChord(keys)
  for (var i = 0; i < (bindings || []).length; i++) {
    var binding = bindings[i]
    if (normalizeChord(binding.keys) === normalized && !binding.managed) return binding
  }
  return null
}

function summarizeTriggers(routine) {
  var shortcut = shortcutTrigger(routine)
  var hooks = hookValues(routine)
  var conditions = routine && Array.isArray(routine.conditions) ? routine.conditions.length : 0
  var parts = []
  if (shortcut) parts.push(shortcut.keys)
  if (hooks.length) parts.push(hooks.length + (hooks.length === 1 ? " event" : " events"))
  if (conditions) parts.push(conditions + (conditions === 1 ? " condition" : " conditions"))
  return parts.length ? parts.join(" / ") : "Manual only"
}

var ACTION_TYPES = [
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

function actionTypeLabel(type) {
  for (var i = 0; i < ACTION_TYPES.length; i++) if (ACTION_TYPES[i].value === type) return ACTION_TYPES[i].label
  return String(type || "")
}

// One short phrase per action, for list summaries and card headers.
function actionLabel(action) {
  if (!action) return ""
  var on = action.value === true
  switch (String(action.type || "")) {
    case "nightlight": return "Night light " + (on ? "on" : "off")
    case "dnd": return "Do not disturb " + (on ? "on" : "off")
    case "stay-awake": return on ? "Stay awake" : "Allow idle"
    case "theme": return action.value ? "Theme " + String(action.value) : "Theme"
    case "brightness": return "Brightness " + (typeof action.value === "number" ? action.value + "%" : "")
    case "microphone-toggle": return "Toggle microphone"
    case "launch-app": return action.desktopId ? "Launch " + String(action.desktopId).replace(/\.desktop$/, "") : "Launch application"
    case "omarchy-command": return action.route ? String(action.route) : "Omarchy command"
    case "notification": return action.title ? "Notify: " + String(action.title) : "Notification"
    case "osd": return action.message ? "OSD: " + String(action.message) : "On-screen display"
    case "sound": return "Play sound"
    case "delay": return "Wait " + (typeof action.milliseconds === "number" ? action.milliseconds + " ms" : "")
    case "exec": return action.program ? "Run " + String(action.program) : "Run program"
    case "shell": return action.command ? "Shell: " + String(action.command) : "Shell command"
  }
  return actionTypeLabel(action.type)
}

function summarizeActions(routine, limit) {
  var actions = routine && Array.isArray(routine.actions) ? routine.actions : []
  var max = typeof limit === "number" && limit > 0 ? limit : 3
  var parts = []
  for (var i = 0; i < actions.length && i < max; i++) parts.push(actionLabel(actions[i]))
  if (actions.length > max) parts.push("+" + (actions.length - max) + " more")
  return parts.join(", ")
}

// How an activation record says a routine was started.
function triggerLabel(trigger) {
  var value = String(trigger || "")
  if (value.indexOf("hook:") === 0) return "by the " + hookInfo(value.slice(5)).label.toLowerCase() + " event"
  switch (value) {
    case "shortcut": return "by shortcut"
    case "condition":
    case "service": return "by its conditions"
    case "timer": return "by timer"
    case "test": return "as a test"
    case "manual": return "by hand"
  }
  return ""
}

function nameFor(config, id) {
  var routines = config && Array.isArray(config.routines) ? config.routines : []
  for (var i = 0; i < routines.length; i++)
    if (routines[i] && routines[i].id === id) return String(routines[i].name || id)
  return String(id || "")
}

var SETTER_TYPES = ["nightlight", "dnd", "stay-awake", "theme", "brightness"]
var CONDITION_TYPES = ["time", "wifi", "power", "omarchy-toggle"]
var WEEKDAY_KEYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
var END_MODES = ["restore", "none", "actions"]

function isSetterAction(action) {
  return !!action && SETTER_TYPES.indexOf(String(action.type)) !== -1
}

function defaultOnEnd() {
  return { mode: "restore", actions: [] }
}

// Fills the optional stateful keys so the editor can bind to them directly.
function normalizeRoutine(routine) {
  if (!routine) return routine
  var next = clone(routine)
  if (!Array.isArray(next.actions)) next.actions = []
  if (!Array.isArray(next.conditions)) next.conditions = []
  if (!next.onEnd || typeof next.onEnd !== "object") next.onEnd = defaultOnEnd()
  if (END_MODES.indexOf(next.onEnd.mode) === -1) next.onEnd.mode = "restore"
  if (!Array.isArray(next.onEnd.actions)) next.onEnd.actions = []
  if (next.keepUntil !== "conditions"
      && !(next.keepUntil && typeof next.keepUntil === "object" && typeof next.keepUntil.minutes === "number"))
    next.keepUntil = "conditions"
  return next
}

// Drops the optional keys again when they hold their defaults, so routines
// that never used them are saved exactly as before.
function compactRoutine(routine) {
  var next = normalizeRoutine(routine)
  if (next.conditions.length === 0) delete next.conditions
  if (next.onEnd.mode === "restore" && next.onEnd.actions.length === 0) delete next.onEnd
  else if (next.onEnd.mode !== "actions") next.onEnd.actions = []
  if (next.keepUntil === "conditions") delete next.keepUntil
  return next
}

function hasConditions(routine) {
  return !!routine && Array.isArray(routine.conditions) && routine.conditions.length > 0
}

function isStateful(routine) {
  var next = normalizeRoutine(routine)
  if (!next) return false
  for (var i = 0; i < next.actions.length; i++)
    if (isSetterAction(next.actions[i]) && next.actions[i].restore === true) return true
  if (next.onEnd.mode === "actions" && next.onEnd.actions.length > 0) return true
  return typeof next.keepUntil === "object"
}

function defaultCondition(type) {
  switch (type) {
    case "time": return { type: type, start: "18:30", end: "08:00", weekdays: [] }
    case "wifi": return { type: type, ssids: [] }
    case "power": return { type: type, source: "battery", batteryBelow: 0 }
    case "omarchy-toggle": return { type: type, flag: "" }
  }
  return { type: type }
}

function addCondition(routine, type) {
  var next = normalizeRoutine(routine)
  next.conditions.push(defaultCondition(type))
  return next
}

function replaceCondition(routine, index, type) {
  var next = normalizeRoutine(routine)
  if (index < 0 || index >= next.conditions.length) return next
  if (next.conditions[index].type === type) return next
  next.conditions[index] = defaultCondition(type)
  return next
}

function removeCondition(routine, index) {
  var next = normalizeRoutine(routine)
  if (index < 0 || index >= next.conditions.length) return next
  next.conditions.splice(index, 1)
  return next
}

function isTimeText(value) {
  return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(String(value || ""))
}

function isFlagName(value) {
  var text = String(value || "")
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(text) && text.indexOf("..") === -1
}

function themeSlug(name) {
  return String(name || "").replace(/<[^>]+>/g, "").toLowerCase().replace(/ /g, "-")
}

function isThemeSlug(value) {
  var text = String(value || "")
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(text) && text.length <= 100
}

function isBoundedString(value, minimum, maximum) {
  if (typeof value !== "string") return false
  var length = codePointLength(value)
  return length >= minimum && length <= maximum
}

function isAbsolutePath(value) {
  return isBoundedString(value, 1, 1000) && value.charAt(0) === "/"
}

function validateArguments(args) {
  if (!Array.isArray(args)) return "Arguments must be a JSON array of strings"
  for (var i = 0; i < args.length; i++) {
    if (typeof args[i] !== "string") return "Every argument must be a string"
    if (codePointLength(args[i]) > 500) return "Arguments cannot exceed 500 characters each"
  }
  return ""
}

function validateCondition(condition) {
  if (!condition) return "Condition is missing"
  switch (condition.type) {
    case "time":
      if (!isTimeText(condition.start) || !isTimeText(condition.end)) return "Times must use 24-hour HH:MM"
      if (condition.start === condition.end) return "A time period must start and end at different times"
      return ""
    case "wifi":
      if (!Array.isArray(condition.ssids) || condition.ssids.length === 0) return "Add at least one Wi-Fi network"
      if (condition.ssids.length > 16) return "A Wi-Fi condition can list at most 16 networks"
      for (var i = 0; i < condition.ssids.length; i++) {
        var ssid = String(condition.ssids[i] || "")
        if (!ssid || ssid.length > 32) return "Wi-Fi network names must be 1 to 32 characters"
        if (condition.ssids.indexOf(ssid) !== i) return "Wi-Fi network names must be unique"
      }
      return ""
    case "power":
      if (condition.source !== "ac" && condition.source !== "battery") return "Choose a power source"
      if (condition.source === "ac" && condition.batteryBelow !== 0) return "A battery threshold needs the battery source"
      return ""
    case "omarchy-toggle":
      return isFlagName(condition.flag) ? "" : "Enter an Omarchy toggle flag name"
  }
  return "Unknown condition type"
}

function validateAction(action, endList) {
  if (!action) return "Action is missing"
  if (isSetterAction(action)) {
    if (endList && action.restore === true) return "Actions that run when a routine ends cannot restore"
    if (typeof action.restore !== "boolean") return "Choose whether to restore the previous value"
    if ((action.type === "nightlight" || action.type === "dnd" || action.type === "stay-awake")
        && typeof action.value !== "boolean") return "Choose whether this setting is on or off"
    if (action.type === "theme" && !isThemeSlug(action.value)) return "Choose a theme"
    if (action.type === "brightness"
        && !(typeof action.value === "number" && action.value >= 0 && action.value <= 100 && Math.floor(action.value) === action.value))
      return "Brightness must be a whole number from 0 to 100"
    return ""
  }
  switch (action.type) {
    case "microphone-toggle":
      if (typeof action.sound !== "boolean") return "Choose whether to play microphone sounds"
      if (!isAbsolutePath(action.mutedSound)) return "Enter an absolute path for the muted sound"
      if (!isAbsolutePath(action.liveSound)) return "Enter an absolute path for the live sound"
      return ""
    case "launch-app":
      if (!isBoundedString(action.desktopId, 1, 300) || action.desktopId.indexOf("/") !== -1)
        return "Choose an application"
      return ""
    case "omarchy-command":
      if (!isBoundedString(action.route, 8, 300) || action.route.indexOf("omarchy ") !== 0)
        return "Choose an Omarchy command"
      return validateArguments(action.args)
    case "notification":
      if (!isBoundedString(action.title, 1, 200)) return "Enter a notification title of at most 200 characters"
      if (action.title.charAt(0) === "-") return "A notification title cannot start with -"
      if (!isBoundedString(action.body, 0, 1000)) return "Notification detail cannot exceed 1000 characters"
      if (action.body.charAt(0) === "-") return "Notification detail cannot start with -"
      if (["low", "normal", "critical"].indexOf(action.urgency) === -1) return "Choose a notification urgency"
      if (!isBoundedString(action.glyph, 0, 20)) return "Notification glyph cannot exceed 20 characters"
      return ""
    case "osd":
      if (!isBoundedString(action.icon, 0, 100)) return "OSD icon cannot exceed 100 characters"
      if (!isBoundedString(action.message, 0, 300)) return "OSD message cannot exceed 300 characters"
      if (!(typeof action.progress === "number" && action.progress >= -1 && action.progress <= 100 && Math.floor(action.progress) === action.progress))
        return "OSD progress must be a whole number from -1 to 100"
      if (!(typeof action.duration === "number" && action.duration >= 0 && action.duration <= 60000 && Math.floor(action.duration) === action.duration))
        return "OSD duration must be a whole number from 0 to 60000 milliseconds"
      return ""
    case "sound":
      return isAbsolutePath(action.path) ? "" : "Enter an absolute audio file path"
    case "delay":
      return typeof action.milliseconds === "number" && action.milliseconds >= 0
        && action.milliseconds <= 300000 && Math.floor(action.milliseconds) === action.milliseconds
        ? "" : "Delay must be a whole number from 0 to 300000 milliseconds"
    case "exec":
      if (!isBoundedString(action.program, 1, 1000)) return "Enter a program to run"
      return validateArguments(action.args)
    case "shell":
      return isBoundedString(action.command, 1, 10000) ? "" : "Enter a shell command"
  }
  return "Choose an action type"
}

// Per-card messages so the editor can mark the failing card instead of only
// naming it at the bottom.
function validationByIndex(routine) {
  var next = normalizeRoutine(routine)
  var result = { conditions: {}, actions: {}, end: {}, routine: "" }
  if (!next) return result
  for (var c = 0; c < next.conditions.length; c++) {
    var conditionMessage = validateCondition(next.conditions[c])
    if (conditionMessage) result.conditions[c] = conditionMessage
  }
  for (var a = 0; a < next.actions.length; a++) {
    var actionMessage = validateAction(next.actions[a], false)
    if (actionMessage) result.actions[a] = actionMessage
  }
  for (var e = 0; e < next.onEnd.actions.length; e++) {
    var endMessage = validateAction(next.onEnd.actions[e], true)
    if (endMessage) result.end[e] = endMessage
  }
  if (typeof next.keepUntil === "object"
      && !(next.keepUntil.minutes >= 1 && next.keepUntil.minutes <= 1440 && Math.floor(next.keepUntil.minutes) === next.keepUntil.minutes))
    result.routine = "Keep the routine for 1 to 1440 minutes"
  return result
}

function validateRoutineDetails(routine) {
  var next = normalizeRoutine(routine)
  var message = ""
  for (var c = 0; c < next.conditions.length; c++) {
    message = validateCondition(next.conditions[c])
    if (message) return "Condition " + (c + 1) + ": " + message
  }
  for (var a = 0; a < next.actions.length; a++) {
    message = validateAction(next.actions[a], false)
    if (message) return "Action " + (a + 1) + ": " + message
  }
  for (var e = 0; e < next.onEnd.actions.length; e++) {
    message = validateAction(next.onEnd.actions[e], true)
    if (message) return "End action " + (e + 1) + ": " + message
  }
  if (typeof next.keepUntil === "object"
      && !(next.keepUntil.minutes >= 1 && next.keepUntil.minutes <= 1440 && Math.floor(next.keepUntil.minutes) === next.keepUntil.minutes))
    return "Keep the routine for 1 to 1440 minutes"
  return ""
}

function summarizeCondition(condition) {
  if (!condition) return ""
  switch (condition.type) {
    case "time": {
      var days = Array.isArray(condition.weekdays) && condition.weekdays.length
        ? condition.weekdays.map(function(day) { return day.charAt(0).toUpperCase() + day.slice(1) }).join(" ") + " "
        : ""
      return days + String(condition.start) + "\u2013" + String(condition.end)
    }
    case "wifi": return "Wi-Fi " + (Array.isArray(condition.ssids) ? condition.ssids.join(", ") : "")
    case "power":
      if (condition.source === "ac") return "Plugged in"
      return condition.batteryBelow > 0 ? "Battery below " + condition.batteryBelow + "%" : "On battery"
    case "omarchy-toggle": return "Toggle " + String(condition.flag || "")
  }
  return String(condition.type)
}

function summarizeConditions(routine) {
  if (!hasConditions(routine)) return ""
  return routine.conditions.map(summarizeCondition).join(", ")
}
