import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const panel = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
const editor = fs.readFileSync(path.join(root, "RoutineEditor.qml"), "utf8")
const picker = fs.readFileSync(path.join(root, "ChoicePicker.qml"), "utf8")
const recorder = fs.readFileSync(path.join(root, "ShortcutRecorder.qml"), "utf8")
const popup = fs.readFileSync(path.join(root, "RoutinePopup.qml"), "utf8")

assert.match(panel, /write\(root\.pendingPayload \+ "\\n"\)\s*\n\s*stdinEnabled = false/,
  "apply must close stdin after writing its bounded payload")
assert.match(panel, /\[runnerPath, operation, configRevision\]/,
  "Connect and Repair must send the loaded config revision")
assert.match(panel, /parsed\.committed === true/,
  "the panel must not treat uncommitted snapshots as persisted")
assert.match(panel, /enabled: \(root\.configLoaded \|\| root\.configUncommitted\) && !root\.loading && !root\.mutating/,
  "Connect and Repair must stay available when the configuration is valid but not yet committed")
assert.match(panel, /!\(configLoaded \|\| configUncommitted\)/,
  "mutateConnection must accept an uncommitted configuration so Repair can commit it")
assert.match(panel, /The list and revision were refreshed; save again to apply this draft/,
  "stale-save recovery must confirm revision refresh before inviting another save")
assert.match(panel, /latest revision could not be loaded\. Use Refresh before saving again/,
  "stale-save recovery must report revision refresh failure")
assert.match(panel, /config = parsed\.config\s*\n\s*configRevision = parsed\.revision/,
  "stale-save recovery must refresh the base config and revision together")
assert.match(panel, /showConfirmation\(\s*"disconnect"/,
  "turning Omachord off must go through a confirmation")
assert.match(panel, /function requestIntegrationToggle\(\)[\s\S]*?mutateConnection\("connect"\)/,
  "the integration switch must turn Omachord on without a confirmation")
assert.match(panel, /Connections \{\s*target: root\.service/,
  "the panel must mirror the in-process service instead of only polling the runner")
assert.match(panel, /readonly property color enabledGreen:/,
  "the enabled integration state must use a dedicated green status color")
assert.match(panel, /active: root\.activeView === modelData\.id/,
  "sidebar navigation must keep its glyph and label on the panel foreground")
assert.match(panel, /id: navigationCopy[\s\S]*?x: root\.compact[\s\S]*?navigationButton\.width/,
  "sidebar copy must use explicit compact positioning instead of swapping anchors after launch")
assert.match(panel, /function requestSetRoutineEnabled[\s\S]*?routineEditor\.dirty[\s\S]*?showConfirmation/,
  "list switches must confirm before replacing an unsaved routine draft")

assert.doesNotMatch(editor, /onEditingFinished\s*:/,
  "staged action text must not rebuild delegates when focus changes")
assert.match(editor, /draft\.actions\[index\]\.type === type/,
  "reselecting an action type must preserve its values")
assert.match(editor, /argumentStateAfterMove/,
  "action moves must preserve staged argument errors")
assert.match(editor, /saveRequested\(Model\.compactRoutine\(next\)\)/,
  "saving must drop default lifecycle keys so untouched routines are written unchanged")
assert.match(editor, /Model\.validateRoutineDetails\(next\)/,
  "saving must validate conditions and setters before handing off to the runner")
assert.match(editor, /draft\.conditions\[index\]\.type === type/,
  "reselecting a condition type must preserve its values")
assert.match(editor, /onBindingsChanged: clearResolvedBindingError\(\)/,
  "a refreshed binding catalogue must clear resolved server-side shortcut conflicts")
assert.match(editor, /replace\(\/\\bOma: \/g, "Omachord: "\)/,
  "legacy binding names must never remain visible in editor errors")
assert.match(editor, /persisted && isActive && draft\.enabled === false\) save\(\)/,
  "saving an active routine as disabled must not run it again after apply")
assert.match(panel, /property date displayNow:[\s\S]*?Conditions\.relativeTime\([^)]*root\.displayNow\)/,
  "panel relative timestamps must depend on a live display clock")
assert.match(popup, /property date displayNow:[\s\S]*?Conditions\.minutesLeft\([^)]*displayNow\)/,
  "popup countdowns must depend on a live display clock")
const service = fs.readFileSync(path.join(root, "Service.qml"), "utf8")
assert.match(service, /runnerProc\.command = \[root\.runnerPath, job\.op, job\.id, job\.reason, job\.revision\]/,
  "the service must only ever execute the runner with a literal argv")
assert.match(service, /Conditions\.reconcileJobs\(desired, currentJob, configRevision, failures/,
  "the service queue must be reconciled against current desired state and revision")
assert.doesNotMatch(service, /"bash"|"sh"|"-lc"|"-c"/,
  "the service must never run shell commands")
assert.match(service, /parsed\.integrationComplete === true/,
  "the service must stay idle until the integration is connected")
assert.match(service, /command: \[root\.runnerPath, "autostart"\]/,
  "the service must enable integration on first use")
assert.match(service, /parsed\.committed !== true/,
  "the service must ignore uncommitted configurations")
assert.doesNotMatch(service, /path: root\.stateDir\s*\n\s*watchChanges: true/,
  "the service must not watch the whole state directory and feed read-only probe metadata back into itself")
assert.doesNotMatch(service, /command:\s*\["find"/,
  "the service must not launch an ambient unbounded toggle scan")
assert.doesNotMatch(panel, /command:\s*\["find"/,
  "the panel must not launch an ambient unbounded toggle scan")
assert.match(service, /command:\s*\[root\.runnerPath,\s*"toggles"\]/,
  "the service must use the bounded runner toggle probe")
assert.match(panel, /command:\s*\[root\.runnerPath,\s*"toggles"\]/,
  "the panel must use the bounded runner toggle probe")
assert.match(panel, /if \(!togglesProc\.running && togglesProc\.startPending\)[\s\S]*?rebuildToggleOptions\(null\)/,
  "a toggle-probe start failure must clear stale panel options")
assert.match(service, /property var toggles: Object\.create\(null\)/,
  "toggle names must be stored in a prototype-safe map")
assert.match(service, /applyToggles\(exitCode === 0 \?[^:]+: null\)/,
  "a failed toggle probe must clear stale condition state")
assert.match(service, /configuredRunnerPath\.indexOf\("\/"\) === 0/,
  "the service must ignore relative runner overrides")
assert.match(panel, /configuredRunnerPath\.indexOf\("\/"\) === 0/,
  "the panel must ignore relative runner overrides")
const card = fs.readFileSync(path.join(root, "ActionCard.qml"), "utf8")
assert.doesNotMatch(card, /\broot\./,
  "ActionCard must stay list-agnostic and only speak to the editor through signals")
assert.match(card, /visible: !card\.endList/,
  "end-of-routine actions must not offer a restore toggle")

assert.match(picker, /onPressed: optionList\.currentIndex = parent\.index/,
  "picker clicks must select the pressed row")
assert.match(picker, /selected !== root\.value/,
  "reselecting a picker value must not dirty the routine")
assert.match(recorder, /root\.recording && root\.captureFocused/,
  "shortcut capture must stop after focus leaves")
assert.match(recorder, /Qt\.callLater\(function\(\) \{\s*if \(root\.recording && !shortcutInhibitor\.active\)/,
  "inhibitor deactivation must allow cancellation to report its reason first")

console.log("QML interaction policies passed.")
