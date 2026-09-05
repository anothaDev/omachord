import Quickshell
import Quickshell.Io
import QtQuick
import "Conditions.js" as Conditions

ShellRoot {
  id: root

  property bool editorPassed: false
  property int applyRuns: 0

  FloatingWindow {
    id: window
    visible: true
    implicitWidth: 800
    implicitHeight: 700
  }

  function find(item, predicate) {
    if (predicate(item)) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = find(children[i], predicate)
      if (found) return found
    }
    return null
  }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  function selectSsid(editor, name) {
    var picker = find(editor, function(item) { return item.label === "Add a known or visible network" })
    check(!!picker, "Wi-Fi picker is missing")
    var option = { value: name, label: name }
    editor.wifiOptions = [option]
    picker.changed(picker.optionValue(option))
    check(picker.value === "", "Wi-Fi picker did not reset after selection")
  }

  function typeSsid(editor, name) {
    var field = find(editor, function(item) { return item.placeholderText === "Or type a network name" })
    var button = find(editor, function(item) { return item.text === "Add" })
    check(!!field && !!button, "Manual Wi-Fi controls are missing")
    field.text = name
    button.clicked()
    check(field.text === "", "Manual Wi-Fi field did not reset after adding")
  }

  function ssidRoundTrips(editor) {
    try {
      editor.routine = {
        id: "ssid-round-trip", name: "Exact SSIDs", enabled: true,
        triggers: [], conditions: [{ type: "wifi", ssids: [] }],
        actions: [{ type: "delay", milliseconds: 0 }]
      }
      selectSsid(editor, " Studio ")
      typeSsid(editor, "Studio")
      selectSsid(editor, " leading")
      typeSsid(editor, "trailing ")
      selectSsid(editor, " ")
      typeSsid(editor, "   ")
      var expected = [" Studio ", "Studio", " leading", "trailing ", " ", "   "]
      check(JSON.stringify(editor.draft.conditions[0].ssids) === JSON.stringify(expected),
        "Picker and manual entry must preserve exact SSIDs, including whitespace")
      for (var name of expected)
        check(Conditions.wifiMatches(editor.draft.conditions[0], name), "Selected SSID no longer matches: " + JSON.stringify(name))
      check(!Conditions.wifiMatches(editor.draft.conditions[0], "leading"), "SSID matching must remain exact")

      editor.dirty = false
      selectSsid(editor, " Studio ")
      typeSsid(editor, "   ")
      typeSsid(editor, "")
      selectSsid(editor, "")
      check(!editor.dirty && JSON.stringify(editor.draft.conditions[0].ssids) === JSON.stringify(expected),
        "Exact duplicates and empty input must leave the draft unchanged")

      Qt.callLater(function() { finishSsidRoundTrip(editor, expected) })
    } catch (error) {
      console.error("OMACHORD_QML_TEST_FAIL", error.message)
    }
  }

  function finishSsidRoundTrip(editor, expected) {
    try {
      var remove = find(editor, function(item) { return item.iconText === "󰅖" && item.text === " Studio " })
      check(!!remove, "Exact SSID removal control is missing")
      remove.clicked()
      expected.shift()
      check(JSON.stringify(editor.draft.conditions[0].ssids) === JSON.stringify(expected),
        "Removing a spaced SSID must retain its distinct unspaced sibling")
      selectSsid(editor, " Studio ")
      expected.push(" Studio ")
      var saved = null
      editor.saveRequested.connect(function(routine) { saved = routine })
      editor.save()
      check(!!saved && JSON.stringify(saved.conditions[0].ssids) === JSON.stringify(expected),
        "Saving must preserve exact SSIDs")
      editor.routine = saved
      check(JSON.stringify(editor.draft.conditions[0].ssids) === JSON.stringify(expected),
        "Reopening a saved routine must preserve exact SSIDs")

      editor.updateCondition(0, "ssids", [])
      typeSsid(editor, "😀".repeat(8) + "x")
      saved = null
      editor.save()
      check(saved === null && editor.localError.indexOf("UTF-8 bytes") !== -1,
        "Saving a Unicode SSID over 32 UTF-8 bytes must be blocked")
      check(editor.draft.conditions[0].ssids[0] === "😀".repeat(8) + "x",
        "Byte-limit validation must preserve the invalid input for correction")
      editor.removeSsid(0, 0)
      typeSsid(editor, "😀".repeat(8))
      selectSsid(editor, "é".repeat(16))
      editor.save()
      check(!!saved && JSON.stringify(saved.conditions[0].ssids) === JSON.stringify(["😀".repeat(8), "é".repeat(16)]),
        "Manual and picker Unicode names at exactly 32 UTF-8 bytes must save unchanged")
      root.editorPassed = true
      eofProc.running = true
    } catch (error) {
      console.error("OMACHORD_QML_TEST_FAIL", error.message)
    }
  }

  function finishProcessTest(passed, detail) {
    if (editorPassed && passed && applyRuns === 2)
      console.log("OMACHORD_QML_TEST_PASS")
    else console.error("OMACHORD_QML_TEST_FAIL", detail || "runtime process test failed")
  }

  Process {
    id: eofProc
    stdinEnabled: true
    command: ["/bin/bash", "-c", "cat >/dev/null"]
    onStarted: {
      write("bounded payload\n")
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      stdinEnabled = true
      if (exitCode !== 0) {
        root.finishProcessTest(false, "stdin consumer exited " + exitCode)
        return
      }
      root.applyRuns++
      if (root.applyRuns < 2) Qt.callLater(function() { eofProc.running = true })
      else root.finishProcessTest(true, "")
    }
  }

  Component.onCompleted: {
    var component = Qt.createComponent("RoutineEditor.qml")
    if (component.status !== Component.Ready) {
      console.error("OMACHORD_QML_TEST_FAIL", component.errorString())
      return
    }
    var editor = component.createObject(window.contentItem, {
      width: 800,
      height: 700,
      routine: {
        id: "staging",
        name: "Original",
        enabled: true,
        triggers: [],
        actions: [{
          type: "microphone-toggle",
          sound: false,
          mutedSound: "original",
          liveSound: "live"
        }]
      }
    })
    editor.stageRoutineName("User name")
    editor.stageActionText(0, "mutedSound", "user-edit")
    editor.stageArgs("[\"argument-edit\"]", 0)
    editor.updateField("enabled", false)
    editor.updateAction(0, "sound", true)
    var stagingPassed = editor.draft.name === "User name"
        && editor.draft.enabled === false
        && editor.draft.actions[0].mutedSound === "user-edit"
        && editor.draft.actions[0].args[0] === "argument-edit"
        && editor.draft.actions[0].sound === true

    var saveRequests = 0
    var saveAndRunRequests = 0
    editor.saveRequested.connect(function() { saveRequests++ })
    editor.saveAndRunRequested.connect(function() { saveAndRunRequests++ })
    editor.routine = {
      id: "active-disabled",
      name: "Active disabled",
      enabled: true,
      triggers: [],
      actions: [{ type: "dnd", value: true, restore: true }]
    }
    editor.isActive = true
    editor.updateField("enabled", false)
    editor.runOrSave()
    var disabledActiveSavesOnly = saveRequests === 1 && saveAndRunRequests === 0
    editor.isActive = false

    editor.routine = {
      id: "structure",
      name: "Structure",
      enabled: true,
      triggers: [],
      actions: [
        { type: "exec", program: "/bin/first", args: ["first"] },
        { type: "exec", program: "/bin/second", args: ["second"] }
      ]
    }
    editor.replaceAction(1, "exec")
    var sameTypePreserved = editor.draft.actions[1].program === "/bin/second"
      && editor.draft.actions[1].args[0] === "second"
    editor.stageArgs("[", 0)
    editor.stageArgs("{", 1)
    editor.replaceAction(1, "shell")
    var replacementPreservedOtherError = !!editor.argumentErrors["0"]
      && !editor.argumentErrors["1"]
      && editor.argumentTexts["0"] === "["
      && editor.argumentTexts["1"] === undefined
    editor.moveAction(0, 1)
    var moveRemapped = !!editor.argumentErrors["1"]
      && editor.argumentTexts["1"] === "["
    editor.removeAction(0)
    var removalRemapped = !!editor.argumentErrors["0"]
      && editor.argumentTexts["0"] === "["

    editor.routine = {
      id: "lifecycle",
      name: "Lifecycle",
      enabled: true,
      triggers: [],
      actions: [{ type: "dnd", value: true, restore: true }]
    }
    var normalizedDraft = editor.draft.keepUntil === "conditions"
      && editor.draft.onEnd.mode === "restore"
      && editor.draft.conditions.length === 0
      && editor.stateful === true
    editor.setEndMode("actions")
    editor.addEndActionType = "exec"
    editor.addAction("end")
    editor.stageArgs("[", 0)
    editor.stageArgs("[\"end-arg\"]", 0, "end")
    var endListIsolated = editor.draft.onEnd.actions.length === 1
      && editor.draft.onEnd.actions[0].args[0] === "end-arg"
      && !!editor.argumentErrors["0"]
      && !editor.argumentErrors["end:0"]
    editor.removeAction(0, "end")
    var mainErrorSurvivedEndRemoval = !!editor.argumentErrors["0"]
      && editor.argumentTexts["0"] === "["
      && editor.argumentTexts["end:0"] === undefined
    editor.addEndActionType = "nightlight"
    editor.addAction("end")
    var endSetterCannotRestore = editor.draft.onEnd.actions[0].restore === false
    editor.replaceAction(0, "brightness", "end")
    var endReplacementCannotRestore = editor.draft.onEnd.actions[0].restore === false
    editor.setKeepUntil("minutes")
    editor.setKeepMinutes(45)
    var keepUntilStaged = editor.draft.keepUntil.minutes === 45

    editor.addConditionType = "wifi"
    editor.addCondition()
    editor.addSsid(0, "Office")
    editor.addSsid(0, "")
    editor.replaceCondition(0, "wifi")
    var conditionPreserved = editor.draft.conditions.length === 1
      && editor.draft.conditions[0].ssids.length === 1
      && editor.draft.conditions[0].ssids[0] === "Office"
    editor.removeSsid(0, 0)
    editor.addConditionType = "time"
    editor.addCondition()
    editor.stageConditionText(1, "start", "22:15")
    editor.toggleWeekday(1, "fri")
    editor.toggleWeekday(1, "mon")
    var timeStaged = editor.draft.conditions[1].start === "22:15"
      && editor.draft.conditions[1].weekdays.join(",") === "mon,fri"
    editor.replaceCondition(1, "power")
    editor.updateCondition(1, "batteryBelow", 30)
    editor.updateCondition(1, "source", "ac")
    var powerReset = editor.draft.conditions[1].source === "ac"
      && editor.draft.conditions[1].batteryBelow === 0
    editor.removeCondition(0)
    var conditionRemoved = editor.draft.conditions.length === 1
      && editor.draft.conditions[0].type === "power"

    if (stagingPassed && disabledActiveSavesOnly && sameTypePreserved && replacementPreservedOtherError
        && moveRemapped && removalRemapped && normalizedDraft && endListIsolated
        && mainErrorSurvivedEndRemoval && endSetterCannotRestore
        && endReplacementCannotRestore && keepUntilStaged && conditionPreserved
        && timeStaged && powerReset && conditionRemoved) {
      Qt.callLater(function() {
        ssidRoundTrips(editor)
      })
    } else {
      console.error("OMACHORD_QML_TEST_FAIL", JSON.stringify(editor.draft))
    }
  }
}
