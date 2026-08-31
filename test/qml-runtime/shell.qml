import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
  id: root

  property bool editorPassed: false
  property int applyRuns: 0

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
    var editor = component.createObject(this, {
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
    editor.addSsid(0, " Office ")
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

    if (stagingPassed && sameTypePreserved && replacementPreservedOtherError
        && moveRemapped && removalRemapped && normalizedDraft && endListIsolated
        && mainErrorSurvivedEndRemoval && endSetterCannotRestore
        && endReplacementCannotRestore && keepUntilStaged && conditionPreserved
        && timeStaged && powerReset && conditionRemoved) {
      root.editorPassed = true
      eofProc.running = true
    } else {
      console.error("OMACHORD_QML_TEST_FAIL", JSON.stringify(editor.draft))
    }
  }
}
