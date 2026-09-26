import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const panel = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
const editor = fs.readFileSync(path.join(root, "RoutineEditor.qml"), "utf8")
const picker = fs.readFileSync(path.join(root, "ChoicePicker.qml"), "utf8")
const recorder = fs.readFileSync(path.join(root, "ShortcutRecorder.qml"), "utf8")
const popup = fs.readFileSync(path.join(root, "RoutinePopup.qml"), "utf8")
const scrollBarPath = path.join(root, "PanelScrollBar.qml")
const qmlFiles = fs.readdirSync(root).filter(name => name.endsWith(".qml")).sort()

// Index just past the brace that closes the one opened at `open`, skipping
// string literals and comments so their braces do not count.
function closingBrace(source, open) {
  let depth = 0
  for (let i = open; i < source.length; i++) {
    const c = source[i]
    if (c === '"' || c === "'" || c === "`") {
      for (i++; i < source.length && source[i] !== c; i++) if (source[i] === "\\") i++
    } else if (c === "/" && source[i + 1] === "/") {
      while (i < source.length && source[i] !== "\n") i++
    } else if (c === "/" && source[i + 1] === "*") {
      i = source.indexOf("*/", i + 2) + 1
    } else if (c === "{") depth++
    else if (c === "}" && --depth === 0) return i + 1
  }
  throw new Error("unbalanced braces from offset " + open)
}

// The balanced {...} block opened by the first brace in `head`'s match, so a
// pattern cannot silently match across a neighbouring function or object.
function block(source, head, label) {
  const match = head.exec(source)
  assert.ok(match, `${label || head}: not found`)
  const open = source.indexOf("{", match.index)
  return source.slice(open, closingBrace(source, open))
}

function fn(source, name) {
  return block(source, new RegExp(`function ${name}\\([^)]*\\)\\s*\\{`), `function ${name}`)
}

// The innermost QML object or JS block that contains `marker`.
function enclosing(source, marker) {
  const at = source.indexOf(marker)
  assert.ok(at !== -1, `${marker}: not found`)
  for (let open = source.lastIndexOf("{", at); open !== -1; open = source.lastIndexOf("{", open - 1)) {
    const end = closingBrace(source, open)
    if (end > at) return source.slice(open, end)
  }
  throw new Error(`${marker}: no enclosing block`)
}

// Every `Type { ... }` object in a QML source.
function objects(source, type) {
  const rows = []
  const pattern = new RegExp(`\\b${type}\\s*\\{`, "g")
  for (let match; (match = pattern.exec(source));) {
    const open = source.indexOf("{", match.index)
    rows.push(source.slice(open, closingBrace(source, open)))
  }
  return rows
}

assert.ok(fs.existsSync(scrollBarPath),
  "panel scrolling must use the shared Omachord scrollbar")
const scrollBar = fs.readFileSync(scrollBarPath, "utf8")
assert.match(scrollBar, /radius:\s*Math\.min\(Style\.cornerRadius,\s*Style\.space\(1\)\)/,
  "the scrollbar handle must stay sharp instead of becoming a rounded Qt pill")
assert.match(scrollBar, /background:\s*Item\s*\{\s*\}/,
  "the scrollbar track must stay transparent")
assert.match(editor, /QQC\.ScrollBar\.vertical:\s*PanelScrollBar\s*\{/,
  "the routine editor must use the shared Omachord scrollbar")
assert.match(enclosing(panel, "id: shortcutList"), /QQC\.ScrollBar\.vertical:\s*PanelScrollBar\s*\{/,
  "the shortcuts list must expose the shared draggable Omachord scrollbar")
assert.match(enclosing(panel, "id: activityScroll"), /QQC\.ScrollBar\.vertical:\s*PanelScrollBar\s*\{/,
  "the activity view must use the same Omachord scrollbar style")
assert.match(enclosing(panel, "id: shortcutWheel"), /acceptedDevices:\s*PointerDevice\.Mouse/,
  "the shortcuts list must accelerate mouse-wheel scrolling")
assert.match(enclosing(panel, "id: shortcutWheel"), /event\.pixelDelta\.y\s*!==\s*0[\s\S]*?event\.accepted\s*=\s*false/,
  "precision touchpad scrolling must remain native")
assert.match(block(panel, /SmoothedAnimation\s*\{/), /property:\s*"contentY"/,
  "shortcut wheel movement must ease between scroll positions")
assert.match(fn(panel, "clampShortcutContentY"), /Math\.max\(minimum,\s*Math\.min\(maximum,\s*value\)\)/,
  "smooth shortcut scrolling must remain inside the list bounds")

assert.match(panel, /write\(root\.pendingPayload \+ "\\n"\)\s*\n\s*stdinEnabled = false/,
  "apply must close stdin after writing its bounded payload")
assert.match(panel, /\[runnerPath, operation, configRevision\]/,
  "Connect and Repair must send the loaded config revision")
assert.match(panel, /parsed\.committed === true/,
  "the panel must not treat uncommitted snapshots as persisted")
assert.match(panel, /enabled: root\.configLoaded && !root\.loading && !root\.mutating/,
  "Repair must remain unavailable for unseen uncommitted executable content")
assert.match(panel, /operation === "connect" && !configLoaded/,
  "the connection boundary must reject approval of unreviewed config")
assert.match(panel, /The list and revision were refreshed; save again to apply this draft/,
  "stale-save recovery must confirm revision refresh before inviting another save")
assert.match(panel, /latest revision could not be loaded\. Use Refresh before saving again/,
  "stale-save recovery must report revision refresh failure")
assert.match(panel, /config = parsed\.config\s*\n\s*configRevision = parsed\.revision/,
  "stale-save recovery must refresh the base config and revision together")
assert.match(panel, /showConfirmation\(\s*"disconnect"/,
  "turning Omachord off must go through a confirmation")
assert.match(fn(panel, "requestIntegrationToggle"), /mutateConnection\("connect"\)/,
  "the integration switch must turn Omachord on without a confirmation")
assert.match(panel, /Connections \{\s*target: root\.service/,
  "the panel must mirror the in-process service instead of only polling the runner")
assert.match(panel, /readonly property color enabledGreen:/,
  "the enabled integration state must use a dedicated green status color")
assert.match(panel, /active: root\.activeView === modelData\.id/,
  "sidebar navigation must keep its glyph and label on the panel foreground")
assert.match(enclosing(panel, "id: navigationCopy"), /x: root\.compact[\s\S]*?navigationButton\.width/,
  "sidebar copy must use explicit compact positioning instead of swapping anchors after launch")
assert.match(fn(panel, "requestSetRoutineEnabled"), /routineEditor\.dirty[\s\S]*?showConfirmation/,
  "list switches must confirm before replacing an unsaved routine draft")
assert.match(panel, /property var enableIntents: Object\.create\(null\)\n\s*property var enableSubmitted: Object\.create\(null\)/,
  "saved-routine switches must retain latest intents separately from the in-flight batch")
assert.match(enclosing(panel, "id: enableApplyDebounce"), /interval: 75[\s\S]*?onTriggered: root\.submitEnableBatch\(\)/,
  "saved-routine switches must use a short deterministic batching window")
assert.match(fn(panel, "setRoutineEnabled"), /enableIntents = intents[\s\S]*?config = configWithEnableIntents\(config, intents\)[\s\S]*?enableApplyDebounce\.restart\(\)/,
  "a saved-routine switch must update optimistically before scheduling persistence")
assert.match(fn(panel, "submitEnableBatch"), /applyProc\.running \|\| enableSubmittedConfig !== null[\s\S]*?enableSubmitted = Object\.assign\(Object\.create\(null\), enableIntents\)[\s\S]*?startProcess\(applyProc\)/,
  "enable batching must snapshot latest intents and keep exactly one config apply in flight")
assert.match(fn(panel, "clearSubmittedEnableIntents"), /mapOwns\(submitted, id\) && current\[id\]\.enabled === submitted\[id\]\.enabled[\s\S]*?current\[id\]\.definition === submitted\[id\]\.definition\) continue/,
  "an enable apply must acknowledge only submitted values that are still current")
assert.match(fn(panel, "handleEnableApplyResult"), /enableCommittedConfig = Model\.clone\(committed\)[\s\S]*?clearSubmittedEnableIntents\(committed\)[\s\S]*?config = configWithEnableIntents\(committed, enableIntents\)/,
  "newer switch intents must rebase on each successfully committed batch")
assert.match(fn(panel, "handleEnableApplyResult"), /result\.code === "stale-config"[\s\S]*?revisionRefreshPurpose = "enable"[\s\S]*?requestRefreshProcess\(revisionProc\)/,
  "stale enable batches must refresh their base before retrying")
assert.match(fn(panel, "handleRevisionResult"), /purpose === "enable"[\s\S]*?enableCommittedConfig = Model\.clone\(parsed\.config\)[\s\S]*?configWithEnableIntents\(parsed\.config, enableIntents\)[\s\S]*?enableApplyDebounce\.restart\(\)/,
  "stale enable intents must be rebased on the refreshed config and revision")
assert.match(fn(panel, "failEnableBatch"), /config = Model\.clone\(enableCommittedConfig\)[\s\S]*?enableIntents = Object\.create\(null\)/,
  "a hard enable-save failure must roll back optimistic values")
assert.match(panel, /interactive: root\.configLoaded && \(!root\.mutating \|\| root\.mutationOperation === "enable-apply"\)/,
  "unrelated enable switches must remain available while a serialized batch is in flight")
assert.match(panel, /busy: routineRow\.enablePending/,
  "a pending enable switch must show progress and block duplicate activation")
for (const file of ["Panel.qml", "RoutinePopup.qml", "RoutineEditor.qml", "ActionCard.qml"]) {
  const source = fs.readFileSync(path.join(root, file), "utf8")
  assert.doesNotMatch(source, /\b(?:ToggleSwitch|Toggle)\s*\{/,
    `${file} must use the app's pending-aware toggle controls`)
}
assert.match(panel, /routineRow\.enablePending \? "SAVING"/,
  "enable persistence must expose pending state on the affected row")
assert.match(fn(panel, "runRoutine"), /typeof service\.testRoutine === "function"[\s\S]*?service\.testRoutine\(id, reviewed\)/,
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
assert.match(fn(popup, "rowBusy"), /pendingIds\[String\(id\)\] === true/,
  "the popup must disable only the routine row that is already pending")
const service = fs.readFileSync(path.join(root, "Service.qml"), "utf8")
assert.match(fn(service, "testRoutine"), /enqueueManual\("run", id, "test", expectedRevision\)/,
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
// No production QML may start a shell: every process is the runner's argv.
for (const file of qmlFiles) {
  const source = fs.readFileSync(path.join(root, file), "utf8")
  assert.doesNotMatch(source, /"(?:\/(?:usr\/)?bin\/)?(?:ba|z|da|fi)?sh"|"-l?c"/, `${file} must never run shell commands`)
}
assert.match(service, /parsed\.integrationComplete === true/,
  "the service must stay idle until the integration is connected")
assert.match(service, /command: \[root\.runnerPath, "autostart"\]/,
  "the service must enable integration on first use")
assert.match(service, /parsed\.committed !== true/,
  "the service must ignore uncommitted configurations")
// Watching the whole state directory would feed the runner's own probe
// metadata back into another probe. Properties may appear in any order.
for (const file of qmlFiles) {
  const source = fs.readFileSync(path.join(root, file), "utf8")
  for (const view of objects(source, "FileView")) {
    const watched = /^\s*watchChanges:\s*true\b/m.test(view)
    const wholeDirectory = /^\s*path:\s*root\.stateDir\s*(?:\/\/.*)?$/m.test(view)
    assert.ok(!(watched && wholeDirectory),
      `${file} must not watch the whole state directory and feed read-only probe metadata back into itself`)
  }
}
assert.ok(objects(service, "FileView").length >= 5, "the FileView scan must see the service's watchers")
assert.doesNotMatch(service, /command:\s*\["find"/,
  "the service must not launch an ambient unbounded toggle scan")
assert.doesNotMatch(panel, /command:\s*\["find"/,
  "the panel must not launch an ambient unbounded toggle scan")
assert.match(service, /command:\s*\[root\.runnerPath,\s*"toggles"\]/,
  "the service must use the bounded runner toggle probe")
assert.match(panel, /command:\s*\[root\.runnerPath,\s*"toggles"\]/,
  "the panel must use the bounded runner toggle probe")
assert.match(enclosing(panel, "if (!togglesProc.running && togglesProc.startPending)"), /rebuildToggleOptions\(null\)/,
  "a toggle-probe start failure must clear stale panel options")
assert.match(service, /property var toggles: Object\.create\(null\)/,
  "toggle names must be stored in a prototype-safe map")
assert.match(service, /applyToggles\(exitCode === 0 \?[^:]+: null\)/,
  "a failed toggle probe must clear stale condition state")
// One runner/config path resolver, matching bin/omachord's environment.
const runnerSource = fs.readFileSync(path.join(root, "Runner.js"), "utf8")
const runner = {}
vm.createContext(runner)
vm.runInContext(runnerSource, runner)
assert.equal(runner.runnerPath("/opt/runner", { __sourceDir: "/src" }, "/cfg"), "/opt/runner")
assert.equal(runner.runnerPath("relative/runner", { __sourceDir: "/src" }, "/cfg"), "/src/bin/omachord",
  "a relative runner override must be ignored")
assert.equal(runner.runnerPath("", null, "/cfg"), "/cfg/plugins/anothadev.omachord/bin/omachord")
assert.equal(runner.omarchyConfigDir("/home/u", ""), "/home/u/.config/omarchy")
assert.equal(runner.omarchyConfigDir("/home/u", "/alt/omarchy"), "/alt/omarchy",
  "OMACHORD_OMARCHY_CONFIG_DIR must move the default plugin and config paths like the runner")
assert.equal(runner.configPath("", "/alt/omarchy"), "/alt/omarchy/omachord.json")
assert.equal(runner.configPath("/x/config.json", "/alt/omarchy"), "/x/config.json")
assert.equal(runner.parseJson("{\"ok\":true}", null).ok, true)
assert.equal(runner.parseJson("not json", "fallback"), "fallback")
assert.equal(runner.parseJson(undefined, 7), 7)
for (const [file, pattern] of [
  ["Service.qml", /runnerPath: Runner\.runnerPath\(Quickshell\.env\("OMACHORD_RUNNER_PATH"\), manifest,/],
  ["Panel.qml", /runnerPath: Runner\.runnerPath\(Quickshell\.env\("OMACHORD_RUNNER_PATH"\), manifest,/],
  ["ThemePalette.qml", /defaultRunnerPath: Runner\.runnerPath\(Quickshell\.env\("OMACHORD_RUNNER_PATH"\), null,/]
]) {
  const source = fs.readFileSync(path.join(root, file), "utf8")
  assert.match(source, pattern, `${file} must resolve the runner through Runner.js`)
  assert.match(source, /Runner\.omarchyConfigDir\((?:home|Quickshell\.env\("HOME"\)), Quickshell\.env\("OMACHORD_OMARCHY_CONFIG_DIR"\)\)/,
    `${file} must honour OMACHORD_OMARCHY_CONFIG_DIR like the runner`)
  assert.doesNotMatch(source, /\/\.config\/omarchy\/plugins/, `${file} must not hard-code the plugin path`)
}
const bar = fs.readFileSync(path.join(root, "BarWidget.qml"), "utf8")
const barPalette = block(bar, /ThemePalette\s*\{/)
assert.match(barPalette, /runnerPath: root\.service && root\.service\.runnerPath \? String\(root\.service\.runnerPath\) : palette\.defaultRunnerPath/,
  "the bar must run the service's resolved absolute runner, else the shared default")
assert.doesNotMatch(bar, /\/\.config\/omarchy\/plugins|OMACHORD_RUNNER_PATH/, "the bar must not resolve the runner itself")
assert.match(barPalette, /active: root\.opened/,
  "the bar palette must poll only while its popup, the one user of its colours, is open")
assert.match(fs.readFileSync(path.join(root, "Runner.js"), "utf8"), /override\.indexOf\("\/"\) === 0/,
  "relative runner overrides must be ignored")
assert.match(service, /configPath: Runner\.configPath\(Quickshell\.env\("OMACHORD_CONFIG_FILE"\), omarchyConfigDir\)/,
  "the service must watch the configuration file the runner reads")
for (const [file, source] of [["Service.qml", service], ["Panel.qml", panel]])
  assert.match(source, /function parseJson\(text, fallback\) \{ return Runner\.parseJson\(text, fallback\) \}/,
    `${file} must parse runner replies through Runner.parseJson`)
assert.doesNotMatch(fs.readFileSync(path.join(root, "ThemePalette.qml"), "utf8"), /JSON\.parse\(/,
  "ThemePalette.qml must parse runner replies through Runner.parseJson")
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
