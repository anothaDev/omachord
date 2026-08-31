import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const panel = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
const editor = fs.readFileSync(path.join(root, "RoutineEditor.qml"), "utf8")
const picker = fs.readFileSync(path.join(root, "ChoicePicker.qml"), "utf8")
const recorder = fs.readFileSync(path.join(root, "ShortcutRecorder.qml"), "utf8")

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
assert.match(panel, /: \(root\.status\.integrationComplete \? "Disable" : "Enable"\)/,
  "the default-on integration must expose Enable and Disable rather than setup-oriented Connect")
assert.match(panel, /readonly property color enabledGreen:/,
  "the enabled integration state must use a dedicated green status color")

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
