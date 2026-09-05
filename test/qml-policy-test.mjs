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
const scrollBarPath = path.join(root, "PanelScrollBar.qml")

assert.ok(fs.existsSync(scrollBarPath),
  "panel scrolling must use the shared Omachord scrollbar")
const scrollBar = fs.readFileSync(scrollBarPath, "utf8")
assert.match(scrollBar, /radius:\s*Math\.min\(Style\.cornerRadius,\s*Style\.space\(1\)\)/,
  "the scrollbar handle must stay sharp instead of becoming a rounded Qt pill")
assert.match(scrollBar, /background:\s*Item\s*\{\s*\}/,
  "the scrollbar track must stay transparent")
assert.match(editor, /QQC\.ScrollBar\.vertical:\s*PanelScrollBar\s*\{/,
  "the routine editor must use the shared Omachord scrollbar")
assert.match(panel, /id:\s*shortcutList[\s\S]*?QQC\.ScrollBar\.vertical:\s*PanelScrollBar\s*\{/,
  "the shortcuts list must expose the shared draggable Omachord scrollbar")
assert.match(panel, /id:\s*activityScroll[\s\S]*?QQC\.ScrollBar\.vertical:\s*PanelScrollBar\s*\{/,
  "the activity view must use the same Omachord scrollbar style")
assert.match(panel, /id:\s*shortcutWheel[\s\S]*?acceptedDevices:\s*PointerDevice\.Mouse/,
  "the shortcuts list must accelerate mouse-wheel scrolling")
assert.match(panel, /id:\s*shortcutWheel[\s\S]*?event\.pixelDelta\.y\s*!==\s*0[\s\S]*?event\.accepted\s*=\s*false/,
  "precision touchpad scrolling must remain native")
assert.match(panel, /SmoothedAnimation\s*\{[\s\S]*?property:\s*"contentY"/,
  "shortcut wheel movement must ease between scroll positions")
assert.match(panel, /function clampShortcutContentY\(value\)[\s\S]*?Math\.max\(minimum,\s*Math\.min\(maximum,\s*value\)\)/,
  "smooth shortcut scrolling must remain inside the list bounds")

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
assert.match(panel, /property var enableIntents: \(\{\}\)[\s\S]*?property var enableSubmitted: \(\{\}\)/,
  "saved-routine switches must retain latest intents separately from the in-flight batch")
assert.match(panel, /id: enableApplyDebounce\s*\n\s*interval: 75[\s\S]*?onTriggered: root\.submitEnableBatch\(\)/,
  "saved-routine switches must use a short deterministic batching window")
assert.match(panel, /function setRoutineEnabled[\s\S]*?enableIntents = intents[\s\S]*?config = configWithEnableIntents\(config, intents\)[\s\S]*?enableApplyDebounce\.restart\(\)/,
  "a saved-routine switch must update optimistically before scheduling persistence")
assert.match(panel, /function submitEnableBatch[\s\S]*?applyProc\.running \|\| enableSubmittedConfig !== null[\s\S]*?enableSubmitted = Object\.assign\(\{\}, enableIntents\)[\s\S]*?startProcess\(applyProc\)/,
  "enable batching must snapshot latest intents and keep exactly one config apply in flight")
assert.match(panel, /mapOwns\(submitted, id\) && current\[id\] === submitted\[id\]\) continue/,
  "an enable apply must acknowledge only submitted values that are still current")
assert.match(panel, /enableCommittedConfig = Model\.clone\(committed\)[\s\S]*?clearSubmittedEnableIntents\(committed\)[\s\S]*?config = configWithEnableIntents\(committed, enableIntents\)/,
  "newer switch intents must rebase on each successfully committed batch")
assert.match(panel, /result\.code === "stale-config"[\s\S]*?revisionRefreshPurpose = "enable"[\s\S]*?requestRefreshProcess\(revisionProc\)/,
  "stale enable batches must refresh their base before retrying")
assert.match(panel, /purpose === "enable"[\s\S]*?enableCommittedConfig = Model\.clone\(parsed\.config\)[\s\S]*?configWithEnableIntents\(parsed\.config, enableIntents\)[\s\S]*?enableApplyDebounce\.restart\(\)/,
  "stale enable intents must be rebased on the refreshed config and revision")
assert.match(panel, /function failEnableBatch[\s\S]*?config = Model\.clone\(enableCommittedConfig\)[\s\S]*?enableIntents = \(\{\}\)/,
  "a hard enable-save failure must roll back optimistic values")
assert.match(panel, /interactive: root\.configLoaded && \(!root\.mutating \|\| root\.mutationOperation === "enable-apply"\)/,
  "enable switches must remain interactive while their serialized batch is in flight")
assert.match(panel, /routineRow\.enablePending \? "SAVING"/,
  "enable persistence must expose pending state on the affected row")
assert.match(panel, /typeof service\.testRoutine === "function"[\s\S]*?service\.testRoutine\(id\)/,
  "live panel actions must use the service's concurrent manual workers when available")
assert.match(panel, /running: root\.editorRoutine \? root\.routineActionBusy\(root\.editorRoutine\.id\) : false/,
  "routine action progress must be tracked per routine instead of globally")

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
assert.match(popup, /function rowBusy\(id\)[\s\S]*?pendingIds\[String\(id\)\] === true/,
  "the popup must disable only the routine row that is already pending")
const service = fs.readFileSync(path.join(root, "Service.qml"), "utf8")
assert.match(service, /function testRoutine\(id\)[\s\S]*?enqueueManual\("run", id, "test"\)/,
  "the concurrent service path must preserve editor testing of disabled routines")
assert.match(service, /runnerProc\.command = \[root\.runnerPath, job\.op, job\.id, job\.reason, job\.revision\]/,
  "the service must only ever execute the runner with a literal argv")
assert.match(service, /readonly property int maxManualWorkers: 4/,
  "manual routine work must use a bounded worker pool")
assert.match(service, /if \(manualPendingIds\[job\.id\]\) return/,
  "condition work must not race a manual operation for the same routine")
assert.match(service, /if \(Object\.keys\(manualInFlight\)\.length \|\| runnerProc\.running \|\| currentJob\) return/,
  "connection changes must wait for all routine work to drain")
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
