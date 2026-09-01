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
  id: "dark", conditions: 1, matched: true, active: true, trigger: "condition", expiresAt: null, latched: true,
  details: [{ type: "time", matched: true, summary: "18:30–08:00", state: "now 23:00" }],
  failure: null
}, "existing keys keep their meaning; details and failure are added")

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


// ------------------------------------------------------------ describing
const describe = (condition, overrides) => plain(conditions.describeCondition(condition, env(overrides)))

assert.deepEqual(describe(night, { now: at(31, 23, 0) }),
  { type: "time", matched: true, summary: "18:30–08:00", state: "now 23:00" })
assert.deepEqual(describe(night, { now: at(31, 9, 12) }),
  { type: "time", matched: false, summary: "18:30–08:00", state: "now 09:12" })
assert.deepEqual(describe(office, { now: at(31, 10, 0) }),
  { type: "time", matched: true, summary: "09:00–17:00 on Mon, Tue, Wed, Thu, Fri", state: "now 10:00" })
assert.equal(describe(office, { now: at(30, 10, 0) }).matched, false, "Sunday is described as not matched")
assert.equal(describe({ type: "time", start: "09:00", end: "17:00", weekdays: ["tue", "mon"] }).summary,
  "09:00–17:00 on Mon, Tue", "weekdays are listed in week order")
assert.equal(describe({ type: "time", start: "9:00", end: "17:00", weekdays: [] }).summary,
  "--:--–17:00", "an unreadable edge is shown as a placeholder")

assert.deepEqual(describe(wifi, { ssid: "Office" }),
  { type: "wifi", matched: true, summary: "Wi-Fi Office, Office-5G", state: "connected to Office" })
assert.deepEqual(describe(wifi, { ssid: "Home" }),
  { type: "wifi", matched: false, summary: "Wi-Fi Office, Office-5G", state: "connected to Home" })
assert.deepEqual(describe(wifi, { ssid: null }),
  { type: "wifi", matched: false, summary: "Wi-Fi Office, Office-5G", state: "not connected" })
assert.deepEqual(describe(wifi, { ssid: "Office", wifiAvailable: false }),
  { type: "wifi", matched: false, summary: "Wi-Fi Office, Office-5G", state: "Wi-Fi unavailable" })
assert.equal(describe({ type: "wifi", ssids: [] }).summary, "Wi-Fi")

assert.deepEqual(describe({ type: "power", source: "ac", batteryBelow: 0 }, { onBattery: false, batteryPercent: 80 }),
  { type: "power", matched: true, summary: "plugged in", state: "plugged in" })
assert.deepEqual(describe({ type: "power", source: "ac", batteryBelow: 0 }, { onBattery: true, batteryPercent: 80 }),
  { type: "power", matched: false, summary: "plugged in", state: "on battery 80%" })
assert.deepEqual(describe({ type: "power", source: "battery", batteryBelow: 30 }, { onBattery: true, batteryPercent: 14 }),
  { type: "power", matched: true, summary: "on battery below 30%", state: "on battery 14%" })
assert.deepEqual(describe({ type: "power", source: "battery", batteryBelow: 30 }, { onBattery: true, batteryPercent: 50 }),
  { type: "power", matched: false, summary: "on battery below 30%", state: "on battery 50%" })
assert.deepEqual(describe({ type: "power", source: "battery", batteryBelow: 30 }, { onBattery: true, batteryPercent: -1 }),
  { type: "power", matched: false, summary: "on battery below 30%", state: "on battery" },
  "an unknown level is neither shown nor matched against a threshold")
assert.deepEqual(describe({ type: "power", source: "battery", batteryBelow: 0 }, { onBattery: true, batteryPercent: -1 }),
  { type: "power", matched: true, summary: "on battery", state: "on battery" })
assert.deepEqual(describe({ type: "power", source: "battery", batteryBelow: 0 }, { onBattery: false, batteryPercent: 90 }),
  { type: "power", matched: false, summary: "on battery", state: "plugged in" })

assert.deepEqual(describe({ type: "omarchy-toggle", flag: "suspend-off" }, { toggles: { "suspend-off": true } }),
  { type: "omarchy-toggle", matched: true, summary: "toggle suspend-off on", state: "on" })
assert.deepEqual(describe({ type: "omarchy-toggle", flag: "suspend-off" }, { toggles: {} }),
  { type: "omarchy-toggle", matched: false, summary: "toggle suspend-off on", state: "off" })

assert.deepEqual(describe({ type: "moon-phase" }),
  { type: "moon-phase", matched: false, summary: "moon-phase", state: "" })
assert.deepEqual(plain(conditions.describeCondition(null, env())),
  { type: "", matched: false, summary: "", state: "" })

const failure = { at: 1000, op: "activate", revision, error: "activate: shell not running" }
let detailed = plain(conditions.routineSummary(routines[1],
  env({ now: at(31, 10, 0), ssid: "Home" }), {}, {}, { work: failure }, 300000))
assert.deepEqual(detailed, {
  id: "work", conditions: 2, matched: false, active: false, trigger: null, expiresAt: null, latched: false,
  details: [
    { type: "time", matched: true, summary: "09:00–17:00 on Mon, Tue, Wed, Thu, Fri", state: "now 10:00" },
    { type: "wifi", matched: false, summary: "Wi-Fi Office, Office-5G", state: "connected to Home" }
  ],
  failure: { op: "activate", at: 1000, error: "activate: shell not running", retryAt: 301000 }
}, "details follow routine order and the failure carries its retry moment")
assert.equal(plain(conditions.routineSummary(routines[0], env(), {}, {}, { work: failure }, 300000)).failure, null,
  "another routine's failure is not reported")
assert.deepEqual(plain(conditions.routineSummary(routines[0], env(), {}, {},
  { dark: { at: 5, op: "deactivate", revision } }, 10)).failure,
  { op: "deactivate", at: 5, error: "", retryAt: 15 }, "a failure without an error text is still reported")
assert.equal(plain(conditions.routineSummary(routines[0], env(), {}, {},
  { dark: { at: "garbage", op: "activate", revision } }, 10)).failure, null, "an unreadable failure time is dropped")
assert.deepEqual(plain(conditions.routineSummary(routines[3], env(), {}, {})).details, [],
  "an unconditioned routine has no details")

// ------------------------------------------------------------ clock text
const now = at(31, 12, 0)
const ago = (ms) => new Date(now.getTime() - ms).toISOString()
assert.equal(conditions.relativeTime(ago(0), now), "just now")
assert.equal(conditions.relativeTime(ago(59 * 1000), now), "just now")
assert.equal(conditions.relativeTime(ago(-5 * 60000), now), "just now", "a future time is not in the past")
assert.equal(conditions.relativeTime(ago(60 * 1000), now), "1 min ago")
assert.equal(conditions.relativeTime(ago(3 * 60000 + 59000), now), "3 min ago")
assert.equal(conditions.relativeTime(ago(59 * 60000 + 59000), now), "59 min ago")
assert.equal(conditions.relativeTime(ago(60 * 60000), now), "1 h ago")
assert.equal(conditions.relativeTime(ago(2 * 3600000 + 1800000), now), "2 h ago")
assert.equal(conditions.relativeTime(ago(23 * 3600000 + 3599000), now), "23 h ago")
assert.equal(conditions.relativeTime(ago(24 * 3600000), now), "yesterday")
assert.equal(conditions.relativeTime(ago(30 * 3600000), now), "yesterday")
assert.equal(conditions.relativeTime(ago(3 * 86400000), now), "3 days ago")
assert.equal(conditions.relativeTime(at(29, 23, 30).toISOString(), at(31, 0, 30)), "2 days ago",
  "days are counted by local calendar date, not 24 h buckets")
assert.equal(conditions.relativeTime(at(28, 12, 0), now), "3 days ago", "a Date is accepted")
assert.equal(conditions.relativeTime(now.getTime() - 120000, now), "2 min ago", "a millisecond number is accepted")
assert.equal(conditions.relativeTime("garbage", now), "")
assert.equal(conditions.relativeTime("", now), "")
assert.equal(conditions.relativeTime(null, now), "")
assert.equal(conditions.relativeTime(undefined, now), "")
assert.equal(conditions.relativeTime(new Date().toISOString()), "just now", "the clock defaults to now")

assert.equal(conditions.clockTime(iso(31, 9, 5)), "09:05")
assert.equal(conditions.clockTime(iso(31, 23, 59)), "23:59")
assert.equal(conditions.clockTime(iso(31, 0, 0)), "00:00")
assert.equal(conditions.clockTime(at(31, 14, 7)), "14:07", "a Date is accepted")
assert.equal(conditions.clockTime("garbage"), "")
assert.equal(conditions.clockTime(""), "")
assert.equal(conditions.clockTime(null), "")
assert.equal(conditions.clockTime(undefined), "")

const ahead = (ms) => new Date(now.getTime() + ms).toISOString()
assert.equal(conditions.minutesLeft(ahead(5 * 60000), now), 5)
assert.equal(conditions.minutesLeft(ahead(90 * 1000), now), 2, "a partial minute still counts")
assert.equal(conditions.minutesLeft(ahead(30 * 1000), now), 1)
assert.equal(conditions.minutesLeft(ahead(0), now), 0)
assert.equal(Object.is(conditions.minutesLeft(ahead(0), now), 0), true, "never negative zero")
assert.equal(Object.is(conditions.minutesLeft(ahead(-1), now), 0), true, "never negative zero")
assert.equal(conditions.minutesLeft(ahead(-30 * 1000), now), 0, "a moment just passed is not yet a minute overdue")
assert.equal(conditions.minutesLeft(ahead(-90 * 1000), now), -1, "elapsed minutes count like relativeTime")
assert.equal(conditions.minutesLeft(ahead(-5 * 60000), now), -5, "past moments are negative")
assert.equal(conditions.minutesLeft(now.getTime() + 180000, now), 3, "a millisecond number is accepted")
assert.equal(conditions.minutesLeft("garbage", now), null)
assert.equal(conditions.minutesLeft("", now), null)
assert.equal(conditions.minutesLeft(null, now), null)
assert.equal(conditions.minutesLeft(undefined, now), null)
assert.equal(conditions.minutesLeft(new Date(Date.now() + 10 * 60000).toISOString()), 10, "the clock defaults to now")

console.log("Condition tests passed.")
