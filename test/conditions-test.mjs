import fs from "node:fs"
import vm from "node:vm"
import assert from "node:assert/strict"

const source = fs.readFileSync(new URL("../Conditions.js", import.meta.url), "utf8")
const conditions = {}
vm.createContext(conditions)
vm.runInContext(source, conditions)

// 2026-08-31 is a Monday.
const plain = value => JSON.parse(JSON.stringify(value))
const at = (day, hour, minute) => new Date(2026, 7, day, hour, minute, 0, 0)
const env = (overrides) => Object.assign({
  now: at(31, 12, 0), ssid: null, wifiAvailable: true, onBattery: false, batteryPercent: -1, toggles: {}
}, overrides || {})

assert.equal(conditions.parseHHMM("18:30"), 18 * 60 + 30)
assert.equal(conditions.parseHHMM("24:00"), -1)
assert.equal(conditions.parseHHMM("9:00"), -1)

const night = { type: "time", start: "18:30", end: "08:00", weekdays: [] }
assert.equal(conditions.timeMatches(night, at(31, 23, 30)), true)
assert.equal(conditions.timeMatches(night, at(31, 1, 0)), true)
assert.equal(conditions.timeMatches(night, at(31, 8, 0)), false, "the end minute is exclusive")
assert.equal(conditions.timeMatches(night, at(31, 18, 30)), true, "the start minute is inclusive")
assert.equal(conditions.timeMatches(night, at(31, 12, 0)), false)

const fridayNight = { type: "time", start: "22:00", end: "02:00", weekdays: ["fri"] }
assert.equal(conditions.timeMatches(fridayNight, at(28, 23, 0)), true, "Friday 23:00")
assert.equal(conditions.timeMatches(fridayNight, at(29, 1, 0)), true, "Saturday 01:00 belongs to the Friday window")
assert.equal(conditions.timeMatches(fridayNight, at(29, 23, 0)), false, "Saturday 23:00 is not Friday")
assert.equal(conditions.timeMatches(fridayNight, at(28, 1, 0)), false, "Friday 01:00 belongs to the Thursday window")

const office = { type: "time", start: "09:00", end: "17:00", weekdays: ["mon", "tue", "wed", "thu", "fri"] }
assert.equal(conditions.timeMatches(office, at(31, 10, 0)), true)
assert.equal(conditions.timeMatches(office, at(30, 10, 0)), false, "Sunday")
assert.equal(conditions.timeMatches({ type: "time", start: "09:00", end: "09:00", weekdays: [] }, at(31, 9, 0)), false)

const wifi = { type: "wifi", ssids: ["Office", "Office-5G"] }
assert.equal(conditions.wifiMatches(wifi, "Office"), true)
assert.equal(conditions.wifiMatches(wifi, "office"), false, "names are case-sensitive")
assert.equal(conditions.wifiMatches(wifi, null), false)
assert.equal(conditions.evaluate(wifi, env({ ssid: "Office", wifiAvailable: false })), false, "no NetworkManager means no match")

assert.equal(conditions.powerMatches({ type: "power", source: "ac", batteryBelow: 0 }, false, 50), true)
assert.equal(conditions.powerMatches({ type: "power", source: "ac", batteryBelow: 0 }, true, 50), false)
assert.equal(conditions.powerMatches({ type: "power", source: "battery", batteryBelow: 0 }, true, -1), true)
assert.equal(conditions.powerMatches({ type: "power", source: "battery", batteryBelow: 30 }, true, 29), true)
assert.equal(conditions.powerMatches({ type: "power", source: "battery", batteryBelow: 30 }, true, 30), false)
assert.equal(conditions.powerMatches({ type: "power", source: "battery", batteryBelow: 30 }, true, -1), false, "unknown level never satisfies a threshold")
assert.equal(conditions.powerMatches({ type: "power", source: "battery", batteryBelow: 30 }, false, 10), false)

assert.equal(conditions.toggleMatches({ type: "omarchy-toggle", flag: "suspend-off" }, { "suspend-off": true }), true)
assert.equal(conditions.toggleMatches({ type: "omarchy-toggle", flag: "suspend-off" }, {}), false)
assert.equal(conditions.evaluate({ type: "moon-phase" }, env()), false)

assert.equal(conditions.evaluateAll([], env()), null)
assert.equal(conditions.evaluateAll(undefined, env()), null)
assert.equal(conditions.evaluateAll([night, wifi], env({ now: at(31, 23, 0), ssid: "Office" })), true)
assert.equal(conditions.evaluateAll([night, wifi], env({ now: at(31, 23, 0), ssid: "Home" })), false)

const routines = [
  { id: "dark", enabled: true, conditions: [night] },
  { id: "work", enabled: true, conditions: [office, wifi] },
  { id: "disabled", enabled: false, conditions: [night] },
  { id: "plain", enabled: true, conditions: [] }
]
assert.equal(conditions.nextTimeBoundaryMs(routines, at(31, 12, 0)), 5 * 3600000, "next edge is 17:00")
assert.equal(conditions.nextTimeBoundaryMs(routines, at(31, 23, 59)), (8 * 60 + 1) * 60000, "next edge after 23:59 is 08:00 tomorrow")
assert.equal(conditions.nextTimeBoundaryMs([{ id: "x", conditions: [wifi] }], at(31, 12, 0)), null)

const activeByCondition = { dark: { trigger: "condition", keepUntil: "conditions", expiresAt: null } }
const activeByShortcut = { dark: { trigger: "shortcut", keepUntil: "conditions", expiresAt: null } }
const activeTimed = { dark: { trigger: "condition", keepUntil: { minutes: 5 }, expiresAt: at(31, 12, 5).toISOString() } }

let plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 23, 0) }), {}, {}))
assert.deepEqual(plan.transitions, [{ id: "dark", op: "activate", reason: "condition" }])
assert.deepEqual(plan.release, [])
plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 23, 0) }), {}, { dark: true }))
assert.deepEqual(plan.transitions, [], "a latched routine does not fire again while its conditions hold")
plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 23, 0) }), activeByCondition, {}))
assert.deepEqual(plan.transitions, [], "an active routine is not activated twice")
plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 12, 0) }), activeByCondition, { dark: true }))
assert.deepEqual(plan.transitions, [{ id: "dark", op: "deactivate", reason: "condition" }])
assert.deepEqual(plan.release, ["dark"], "false conditions release the latch")
plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 12, 0) }), activeByShortcut, {}))
assert.deepEqual(plan.transitions, [], "a manual activation is never ended by conditions")
plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 12, 0) }), activeTimed, {}))
assert.deepEqual(plan.transitions, [], "a timed activation is ended by its timer, not its conditions")
plan = plain(conditions.desiredTransitions(routines, env({ now: at(31, 10, 0), ssid: "Office-5G" }), {}, {}))
assert.deepEqual(plan.transitions, [{ id: "work", op: "activate", reason: "condition" }], "disabled and unconditioned routines are ignored")

assert.deepEqual(plain(conditions.observedActiveIds(routines,
  env({ now: at(31, 23, 0) }), activeByShortcut)), ["dark"],
"a manually active routine latches while its conditions hold")
assert.deepEqual(plain(conditions.observedActiveIds(routines,
  env({ now: at(31, 12, 0) }), activeByShortcut)), [],
"a manually active routine does not latch while its conditions are false")
assert.deepEqual(plain(conditions.observedActiveIds(routines,
  env({ now: at(31, 23, 0) }), activeByShortcut, "dark")), [],
"an in-flight deactivation is not re-latched when conditions turn true")

const revision = "sha256:" + "1".repeat(64)
let jobs = plain(conditions.reconcileJobs(
  [{ id: "dark", op: "activate", reason: "condition" }], null, revision, {}, 1000, 300000, 256))
assert.deepEqual(jobs, [{ id: "dark", op: "activate", reason: "condition", revision }],
  "condition jobs carry the evaluated configuration revision")
jobs = plain(conditions.reconcileJobs([], null, revision, {}, 1000, 300000, 256))
assert.deepEqual(jobs, [], "reconciliation removes a queued activation that is no longer desired")
jobs = plain(conditions.reconcileJobs(
  [{ id: "dark", op: "deactivate", reason: "condition" }],
  { id: "work", op: "activate" }, revision,
  { dark: { at: 900, op: "deactivate", revision } }, 1000, 300000, 256))
assert.deepEqual(jobs, [], "a failed deactivation is suppressed during its retry window")
jobs = plain(conditions.reconcileJobs(
  [{ id: "dark", op: "deactivate", reason: "condition" }], null, revision,
  { dark: { at: 900, op: "deactivate", revision: "sha256:" + "2".repeat(64) } },
  1000, 300000, 256))
assert.equal(jobs.length, 1, "a failure from an older revision does not suppress current work")
jobs = plain(conditions.reconcileJobs(
  [{ id: "dark", op: "deactivate", reason: "condition" }],
  { id: "work", op: "activate" }, revision,
  { dark: { at: 900, op: "activate", revision } }, 1000, 300000, 256))
assert.equal(jobs.length, 1, "an activation failure does not suppress deactivation")

assert.deepEqual(plain(conditions.expiredIds(activeTimed, at(31, 12, 4))), [])
assert.deepEqual(plain(conditions.expiredIds(activeTimed, at(31, 12, 5))), ["dark"])
assert.equal(conditions.nextExpiryMs(activeTimed, at(31, 12, 3)), 2 * 60000)
assert.equal(conditions.nextExpiryMs(activeByCondition, at(31, 12, 3)), null)
assert.equal(conditions.nextExpiryMs({ dark: { expiresAt: "garbage" } }, at(31, 12, 3)), null)

assert.equal(conditions.settleMs(null, null, 60000), 60000)
assert.equal(conditions.settleMs(10000, null, 60000), 10500)
assert.equal(conditions.settleMs(90000, 20000, 60000), 20500)
assert.equal(conditions.settleMs(0, null, 60000), 1000, "never spin faster than once a second")

const summary = conditions.routineSummary(routines[0], env({ now: at(31, 23, 0) }), activeByCondition, { dark: true })
assert.deepEqual(JSON.parse(JSON.stringify(summary)), {
  id: "dark", conditions: 1, matched: true, active: true, trigger: "condition", expiresAt: null, latched: true
})

assert.equal(conditions.latchHorizonMs(routines[0], at(31, 23, 0)), 4.5 * 3600000, "most recent edge was 18:30")
assert.equal(conditions.latchHorizonMs(routines[0], at(31, 8, 30)), 30 * 60000, "most recent edge was 08:00")
assert.equal(conditions.latchHorizonMs({ id: "x", conditions: [wifi] }, at(31, 8, 30)), 86400000, "no time condition falls back to a day")

const iso = (day, hour, minute) => at(day, hour, minute).toISOString()
const seeded = plain(conditions.seedLatches(routines, [
  { timestamp: iso(31, 15, 50), routineId: "dark", trigger: "shortcut", status: "deactivated" },
  { timestamp: iso(31, 9, 0), routineId: "dark", trigger: "condition", status: "activated" },
  { timestamp: iso(31, 10, 30), routineId: "work", trigger: "condition", status: "success" },
  { timestamp: iso(31, 10, 0), routineId: "plain", trigger: "manual", status: "deactivated" }
], at(31, 16, 0)))
assert.deepEqual(seeded, { dark: true, work: true }, "a manual end and a run within the current period latch; unconditioned routines never do")
assert.deepEqual(plain(conditions.seedLatches(routines, [
  { timestamp: iso(30, 22, 50), routineId: "dark", trigger: "shortcut", status: "deactivated" }
], at(31, 23, 0))), {}, "an entry from before the latest edge is stale")
assert.deepEqual(plain(conditions.seedLatches(routines, [
  { timestamp: iso(31, 22, 50), routineId: "dark", trigger: "condition", status: "deactivated" }
], at(31, 23, 0))), {}, "a deactivation the service made itself does not latch")
assert.deepEqual(plain(conditions.seedLatches(routines, [
  { timestamp: "garbage", routineId: "dark", trigger: "shortcut", status: "deactivated" }
], at(31, 23, 0))), {}, "unparseable timestamps are ignored")

console.log("Condition tests passed.")
