import fs from "node:fs"
import vm from "node:vm"
import assert from "node:assert/strict"

const source = fs.readFileSync(new URL("../Model.js", import.meta.url), "utf8")
const model = {}
vm.createContext(model)
vm.runInContext(source, model)

assert.equal(model.normalizeChord("ctrl + super + comma"), "SUPER + CTRL + comma")
assert.equal(model.normalizeChord("SUPER SHIFT CTRL + SPACE"), "SUPER + SHIFT + CTRL + SPACE")
assert.equal(model.normalizeChord("shift + alt + f12"), "SHIFT + ALT + F12")
assert.equal(model.normalizeChord("SUPER + CTRL"), "")
assert.equal(model.normalizeChord("SUPER + LEFT MOUSE BUTTON"), "")

const mic = model.microphoneTemplate([])
assert.equal(mic.id, "meeting-microphone")
assert.equal(mic.actions[0].type, "microphone-toggle")
assert.equal(model.microphoneTemplate([mic]).id, "meeting-microphone-2")

const longName = "Very long routine name ".repeat(10)
const longId = model.uniqueId(longName, [])
assert.ok(longId.length <= 80)
assert.match(longId, /^[a-z0-9]+(?:-[a-z0-9]+)*$/)
const suffixedLongId = model.uniqueId(longName, [{ id: longId }])
assert.ok(suffixedLongId.length <= 80)
assert.notEqual(suffixedLongId, longId)
const emojiName = "😀".repeat(100)
assert.equal(model.codePointLength(emojiName), 100)
assert.equal(model.truncateCodePoints(emojiName, 100), emojiName)
assert.equal(model.codePointLength(model.truncateCodePoints(emojiName + "x", 100)), 100)

const config = { version: 1, routines: [mic] }
const duplicate = model.duplicateRoutine(config, mic.id)
assert.equal(duplicate.routine.id, "meeting-microphone-copy")
assert.equal(duplicate.routine.enabled, false)
assert.equal(config.routines.length, 1, "source config must remain immutable")

const maxNameRoutine = { ...mic, id: "max-name", name: "x".repeat(100) }
const longDuplicate = model.duplicateRoutine({ version: 1, routines: [maxNameRoutine] }, "max-name")
assert.ok(longDuplicate.routine.name.length <= 100)
assert.ok(longDuplicate.routine.id.length <= 80)

let edited = model.setShortcut(mic, "ctrl + super + m", true)
assert.deepEqual(JSON.parse(JSON.stringify(edited.triggers[0])), {
  type: "shortcut",
  keys: "SUPER + CTRL + M",
  override: true
})
edited = model.setHooks(edited, ["post-boot", "theme-set"])
assert.deepEqual(Array.from(model.hookValues(edited)), ["post-boot", "theme-set"])
assert.equal(model.shortcutTrigger(model.setShortcut(edited, "SUPER + LEFT MOUSE BUTTON", true)), null)

const bindings = [
  { keys: "SUPER + M", description: "Existing", managed: false },
  { keys: "SUPER + K", description: "Omachord: Managed", managed: true }
]
assert.equal(model.conflictFor(bindings, "super + m").description, "Existing")
assert.equal(model.conflictFor(bindings, "SUPER + K"), null)
assert.equal(model.filterBindings(bindings, "managed", "all").length, 1)
assert.equal(model.filterBindings(bindings, "", "managed").length, 1)

const sequence = {
  id: "sequence",
  name: "Sequence",
  enabled: true,
  triggers: [],
  actions: [
    { type: "delay", milliseconds: 100 },
    { type: "notification", title: "Done", body: "", urgency: "low", glyph: "" }
  ]
}
const moved = model.moveAction(sequence, 1, -1)
assert.equal(moved.actions[0].type, "notification")
assert.equal(sequence.actions[0].type, "delay", "source routine must remain immutable")

const plainValue = value => JSON.parse(JSON.stringify(value))
const setter = { type: "dnd", value: true, restore: true }
assert.deepEqual(plainValue(model.defaultAction("nightlight")), { type: "nightlight", value: true, restore: true })
assert.deepEqual(plainValue(model.defaultAction("theme")), { type: "theme", value: "", restore: true })
assert.deepEqual(plainValue(model.defaultAction("brightness")), { type: "brightness", value: 50, restore: true })
assert.deepEqual(plainValue(model.defaultCondition("time")), { type: "time", start: "18:30", end: "08:00", weekdays: [] })
assert.deepEqual(plainValue(model.defaultCondition("power")), { type: "power", source: "battery", batteryBelow: 0 })

const plain = { id: "plain", name: "Plain", enabled: true, triggers: [], actions: [{ type: "delay", milliseconds: 0 }] }
const normalized = model.normalizeRoutine(plain)
assert.deepEqual(plainValue(normalized.conditions), [])
assert.deepEqual(plainValue(normalized.onEnd), { mode: "restore", actions: [] })
assert.equal(normalized.keepUntil, "conditions")
assert.deepEqual(plainValue(model.normalizeRoutine(normalized)), plainValue(normalized), "normalization must be idempotent")
assert.deepEqual(plainValue(model.compactRoutine(normalized)), plain, "default lifecycle keys must not be written")
assert.equal(plain.conditions, undefined, "source routine must remain immutable")

const stateful = { ...plain, id: "stateful", actions: [setter] }
assert.equal(model.isStateful(plain), false)
assert.equal(model.isStateful(stateful), true)
assert.equal(model.isStateful({ ...plain, actions: [{ ...setter, restore: false }] }), false)
assert.equal(model.isStateful({ ...plain, keepUntil: { minutes: 5 } }), true)
assert.equal(model.isStateful({ ...plain, onEnd: { mode: "actions", actions: [{ type: "delay", milliseconds: 0 }] } }), true)
const compactedEnd = model.compactRoutine({ ...plain, onEnd: { mode: "none", actions: [{ type: "delay", milliseconds: 0 }] } })
assert.deepEqual(plainValue(compactedEnd.onEnd), { mode: "none", actions: [] }, "end actions are dropped unless the actions mode is chosen")

let conditioned = model.addCondition(stateful, "wifi")
assert.equal(conditioned.conditions.length, 1)
assert.equal(model.summarizeTriggers(conditioned), "1 condition")
conditioned.conditions[0].ssids = ["Office"]
assert.deepEqual(plainValue(model.replaceCondition(conditioned, 0, "wifi").conditions[0].ssids), ["Office"], "same-type replacement must preserve values")
assert.equal(model.replaceCondition(conditioned, 0, "power").conditions[0].source, "battery")
assert.equal(model.removeCondition(conditioned, 0).conditions.length, 0)
assert.equal(model.summarizeConditions({ conditions: [
  { type: "time", start: "18:30", end: "08:00", weekdays: ["mon", "fri"] },
  { type: "wifi", ssids: ["Office", "Office-5G"] },
  { type: "power", source: "battery", batteryBelow: 30 },
  { type: "power", source: "ac", batteryBelow: 0 },
  { type: "omarchy-toggle", flag: "suspend-off" }
] }), "Mon Fri 18:30-08:00, Wi-Fi Office, Office-5G, Battery below 30%, Plugged in, Toggle suspend-off")

assert.equal(model.validateCondition({ type: "time", start: "24:00", end: "08:00", weekdays: [] }), "Times must use 24-hour HH:MM")
assert.equal(model.validateCondition({ type: "time", start: "08:00", end: "08:00", weekdays: [] }), "A time period must start and end at different times")
assert.equal(model.validateCondition({ type: "wifi", ssids: [] }), "Add at least one Wi-Fi network")
assert.equal(model.validateCondition({ type: "power", source: "ac", batteryBelow: 5 }), "A battery threshold needs the battery source")
assert.equal(model.validateCondition({ type: "omarchy-toggle", flag: "a/b" }), "Enter an Omarchy toggle flag name")
assert.equal(model.validateCondition({ type: "omarchy-toggle", flag: "suspend-off" }), "")
assert.equal(model.validateAction({ type: "theme", value: "", restore: true }, false), "Choose a theme")
assert.equal(model.validateAction({ type: "brightness", value: 101, restore: true }, false), "Brightness must be a whole number from 0 to 100")
assert.equal(model.validateAction(setter, true), "Actions that run when a routine ends cannot restore")
assert.equal(model.validateAction({ type: "exec", program: "x", args: [] }, true), "")
assert.equal(model.validateRoutineDetails({ ...stateful, keepUntil: { minutes: 0 } }), "Keep the routine for 1 to 1440 minutes")
assert.equal(model.validateRoutineDetails({ ...stateful, conditions: [{ type: "wifi", ssids: [] }] }), "Condition 1: Add at least one Wi-Fi network")
assert.equal(model.validateRoutineDetails(stateful), "")
assert.equal(model.themeSlug("Tokyo Night"), "tokyo-night")
assert.equal(model.themeSlug("Catppuccin <Latte>"), "catppuccin-")

for (const key of model.TEMPLATE_KEYS) {
  const template = model.templateRoutine(key, [])
  assert.ok(template && template.id, `template ${key} must build`)
  assert.equal(model.validateRoutineDetails(template), "", `template ${key} must be saveable as-is`)
  assert.equal(model.isStateful(template), true, `template ${key} must restore when it ends`)
  assert.ok(model.hasConditions(template), `template ${key} must be condition-driven`)
}
assert.equal(model.templateRoutine("in-the-dark", [{ id: "in-the-dark" }]).id, "in-the-dark-2")
assert.equal(model.templateRoutine("unknown", []), null)

console.log("Model tests passed.")
