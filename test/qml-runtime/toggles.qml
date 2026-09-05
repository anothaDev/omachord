import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons

ShellRoot {
  id: root

  property int assertions: 0
  property bool externalChecked: false
  property string renderOutput: Quickshell.env("OMACHORD_TOGGLE_RENDER_OUT")
  property var renderStates: ["off", "on", "busy"]
  property int renderIndex: 0
  property bool rendering: false
  readonly property string renderState: renderStates[renderIndex] || "off"

  function assertThat(condition, message) {
    assertions++
    if (!condition) throw new Error(message)
  }

  function createControl(name, properties) {
    var component = Qt.createComponent(name + ".qml")
    assertThat(component.status === Component.Ready, component.errorString())
    var control = component.createObject(scene, properties || {})
    assertThat(control !== null, name + " must instantiate")
    return control
  }

  function assertSize(control, expected, message) {
    assertThat(control.implicitWidth === expected[0]
      && control.implicitHeight === expected[1]
      && control.width === expected[2] && control.height === expected[3],
      message + ": got " + [control.implicitWidth, control.implicitHeight, control.width, control.height]
        + ", expected " + expected)
  }

  function testStableSwitchSize() {
    var control = createControl("PendingSwitch")
    var size = [control.implicitWidth, control.implicitHeight, control.width, control.height]
    assertThat(size[0] > control.trackWidth && size[1] > control.trackHeight,
      "standalone switch reserves cursor padding")
    for (var busy of [false, true]) {
      for (var interactive of [true, false]) {
        for (var checked of [false, true]) {
          for (var enabled of [true, false]) {
            control.busy = busy
            control.interactive = interactive
            control.checked = checked
            control.enabled = enabled
            assertSize(control, size, "switch size must not depend on activation or checked state")
          }
        }
      }
    }
    control.destroy()
  }

  function testBusyPresentation() {
    var control = createControl("PendingSwitch")
    assertThat(control.loadingVisible === false, "idle switch must not display a spinner")
    var spinner = input.findChild(control, "pendingSwitchSpinner")
    var animation = input.findChild(control, "pendingSwitchSpinnerAnimation")
    var thumb = input.findChild(control, "pendingSwitchThumb")
    assertThat(spinner !== null && animation !== null && thumb !== null,
      "switch exposes its loading and thumb presentation for visual checks")
    for (var checked of [false, true]) {
      control.checked = checked
      control.busy = true
      assertThat(control.loadingVisible && spinner.visible && animation.running && !thumb.visible,
        "busy replaces the thumb with an animated spinner, for either checked state")
      var rotation = spinner.rotation
      input.wait(80)
      assertThat(spinner.rotation !== rotation, "busy spinner really animates")
      control.visible = false
      assertThat(!control.loadingVisible && !animation.running,
        "hidden control must stop animating")
      control.visible = true
      assertThat(control.loadingVisible && animation.running, "visible busy control resumes animation")
      control.busy = false
      assertThat(!control.loadingVisible && !animation.running && thumb.visible,
        "settled control restores the thumb and stops the spinner")
    }
    control.destroy()
  }

  function activate(control, action) {
    if (action === "request") return control.requestToggle()
    if (action === "mouse") {
      input.mouseClick(control, control.width / 2, control.height / 2)
    } else if (action === "press") {
      control.Accessible.pressAction()
    } else if (action === "toggle") {
      control.Accessible.toggleAction()
    } else {
      control.forceActiveFocus()
      input.keyClick(action === "space" ? Qt.Key_Space
        : action === "enter" ? Qt.Key_Enter : Qt.Key_Return)
    }
  }

  function testActivation(name, signalName) {
    var control = createControl(name, {
      x: 20, y: 20,
      checked: Qt.binding(function() { return root.externalChecked })
    })
    assertThat(typeof control.requestToggle === "function", name + " exposes one guarded requestToggle action")
    assertThat(control.Accessible.role === Accessible.CheckBox && control.Accessible.checkable,
      name + " exposes checkbox semantics")
    var requests = 0
    control[signalName].connect(function() { requests++; control.busy = true })
    for (var action of ["request", "mouse", "space", "enter", "return", "press", "toggle"]) {
      root.externalChecked = false
      control.busy = false
      control.interactive = true
      control.enabled = true
      var before = requests
      var accepted = activate(control, action)
      if (action === "request") assertThat(accepted === true, name + " accepts an idle request")
      assertThat(requests === before + 1, name + " " + action + " emits exactly one request")
      assertThat(!control.checked && !control.Accessible.checked,
        name + " " + action + " must not change the caller-owned value")
      assertThat(control.busy && control.Accessible.description === "Changing state",
        name + " announces the pending operation")
      for (var repeat = 0; repeat < 3; repeat++) {
        var blocked = activate(control, action)
        if (action === "request") assertThat(blocked === false, name + " rejects a busy request")
      }
      assertThat(requests === before + 1 && !control.checked,
        name + " " + action + " ignores repeated busy activation")

      // Success updates the model, then clears busy. Failure only clears busy.
      // Both paths must unlock, and neither path may break the checked binding.
      for (var settledChecked of [true, false]) {
        root.externalChecked = settledChecked
        control.busy = false
        assertThat(control.checked === settledChecked && control.Accessible.checked === settledChecked,
          name + " follows the externally settled state")
        assertThat(control.Accessible.description !== "Changing state", name + " clears busy description")
        before = requests
        activate(control, action)
        assertThat(requests === before + 1 && control.checked === settledChecked,
          name + " " + action + " unlocks after " + (settledChecked ? "success" : "error"))
      }

      control.busy = false
      for (var blockedState of ["interactive", "enabled"]) {
        control[blockedState] = false
        before = requests
        blocked = activate(control, action)
        if (action === "request") assertThat(blocked === false, name + " rejects " + blockedState + "=false")
        assertThat(requests === before && !control.checked,
          name + " " + action + " is blocked when " + blockedState + "=false")
        control[blockedState] = true
      }
    }
    scene.enabled = false
    assertThat(control.requestToggle() === false, name + " respects an inherited disabled state")
    scene.enabled = true
    control.destroy()
  }

  function testRowPresentation() {
    var control = createControl("PendingToggle", {
      label: "<b>Enabled</b>", description: "<i>Caller-owned setting</i>", width: 480
    })
    var track = input.findChild(control, "pendingToggleSwitch")
    assertThat(track !== null && !track.interactive && !track.cursorRing,
      "row contains a presentation-only switch with no cursor padding")
    assertThat(track.Accessible.ignored, "row has only one accessible checkbox")
    assertThat(control.Accessible.name === control.label, "row supplies its accessible label")
    var label = input.findChild(control, "pendingToggleLabel")
    var description = input.findChild(control, "pendingToggleDescription")
    assertThat(label !== null && label.text === control.label && label.textFormat === Text.PlainText,
      "row title is plain text")
    assertThat(description !== null && description.text === control.description
      && description.textFormat === Text.PlainText, "row description is plain text")
    input.wait(20)
    var size = [control.implicitWidth, control.implicitHeight, control.width, control.height]
    var trackSize = [track.implicitWidth, track.implicitHeight, track.width, track.height]
    for (var busy of [false, true]) {
      for (var interactive of [true, false]) {
        for (var checked of [false, true]) {
          control.busy = busy
          control.interactive = interactive
          control.checked = checked
          assertSize(control, size, "row size must remain stable")
          assertSize(track, trackSize, "row switch size must remain stable")
          assertThat(track.loadingVisible === busy, "row forwards pending presentation")
          assertThat(track.checked === checked, "row forwards externally owned checked state")
          assertThat(track.requestToggle() === false, "row switch cannot activate independently")
        }
      }
    }
    control.visible = false
    assertThat(!track.loadingVisible, "hiding a row also stops its spinner")
    control.visible = true
    control.busy = false
    control.interactive = true
    var requests = 0
    control.clicked.connect(function() { requests++; control.busy = true })
    input.mouseClick(track, track.width / 2, track.height / 2)
    assertThat(requests === 1, "clicking the presentation switch activates the whole row once")
    input.mouseClick(track, track.width / 2, track.height / 2)
    assertThat(requests === 1, "clicking a busy presentation switch cannot reactivate its row")
    control.destroy()
  }

  function testPressAcrossSettlement(name, signalName, innerSwitch) {
    var row = selectableRow.createObject(scene)
    var control = createControl(name, {
      x: 20, y: 20,
      checked: Qt.binding(function() { return root.externalChecked })
    })
    control.parent = row
    var target = innerSwitch ? input.findChild(control, "pendingToggleSwitch") : control
    var context = name + (innerSwitch ? " inner switch" : " surface")
    assertThat(target !== null, context + " mouse target exists")
    input.wait(20)
    var requests = 0
    control[signalName].connect(function() { requests++ })
    for (var success of [true, false]) {
      root.externalChecked = false
      control.busy = true
      input.mouseMove(target, target.width / 2, target.height / 2)
      assertThat(control.containsMouse, context + " retains hover while busy")
      var before = requests
      input.mousePress(target, target.width / 2, target.height / 2)
      root.externalChecked = success
      control.busy = false
      input.mouseRelease(target, target.width / 2, target.height / 2)
      assertThat(requests === before, context + " must reject a press begun busy even if "
        + (success ? "success" : "failure") + " settles before release")
      assertThat(control.checked === success, context + " leaves the settled model unchanged")
      assertThat(row.presses === 0 && row.releases === 0 && row.clicks === 0,
        context + " consumes the blocked gesture instead of selecting the parent row")
      input.mouseClick(target, target.width / 2, target.height / 2)
      assertThat(requests === before + 1, context + " accepts the next ordinary click")
    }
    row.destroy()
  }

  function testInterruptedPress(name, signalName, innerSwitch) {
    var row = selectableRow.createObject(scene)
    var control = createControl(name, { x: 20, y: 20 })
    control.parent = row
    var target = innerSwitch ? input.findChild(control, "pendingToggleSwitch") : control
    var context = name + (innerSwitch ? " inner switch" : " surface")
    assertThat(target !== null, context + " interruption target exists")
    input.wait(20)
    var requests = 0
    control[signalName].connect(function() { requests++ })
    for (var property of ["busy", "interactive", "enabled", "visible"]) {
      for (var recoverBeforeRelease of [false, true]) {
        var before = requests
        input.mousePress(target, target.width / 2, target.height / 2)
        control[property] = property === "busy"
        // Also exercise cancellation/re-enabling while the button is held;
        // returning to idle does not make an interrupted gesture eligible.
        if (recoverBeforeRelease) control[property] = property !== "busy"
        input.mouseRelease(target, target.width / 2, target.height / 2)
        assertThat(requests === before, context + " rejects a press interrupted by " + property
          + (recoverBeforeRelease ? " even after recovery before release" : " at release"))
        assertThat(!control.checked, context + " interrupted gesture does not mutate checked")
        assertThat(row.presses === 0 && row.releases === 0 && row.clicks === 0,
          context + " interrupted gesture does not activate the parent")
        control[property] = property !== "busy"
        input.mouseClick(target, target.width / 2, target.height / 2)
        assertThat(requests === before + 1, context + " accepts a fresh click after " + property)
      }
    }

    var before = requests
    input.mousePress(target, target.width / 2, target.height / 2)
    input.mouseMove(scene, scene.width - 2, scene.height - 2)
    input.mouseRelease(scene, scene.width - 2, scene.height - 2)
    assertThat(requests === before && row.clicks === 0, context + " release outside does not activate")
    input.mouseClick(target, target.width / 2, target.height / 2)
    assertThat(requests === before + 1, context + " next click works after release outside")
    row.destroy()
  }

  Component {
    id: selectableRow
    MouseArea {
      width: 560
      height: 160
      property int presses: 0
      property int releases: 0
      property int clicks: 0
      onPressed: presses++
      onReleased: releases++
      onClicked: clicks++
    }
  }

  function finish() {
    console.log("OMACHORD_QML_TOGGLE_TEST_PASS", assertions, "assertions; native mouse, keyboard, accessibility actions")
    Qt.quit()
  }

  function renderNext() {
    if (renderIndex >= renderStates.length) { finish(); return }
    renderSettle.restart()
  }

  Timer {
    id: renderSettle
    interval: 250
    onTriggered: {
      var path = root.renderOutput + "/" + root.renderState + ".png"
      var started = scene.grabToImage(function(result) {
        if (!result.saveToFile(path)) {
          console.error("OMACHORD_QML_TOGGLE_TEST_FAIL", "could not save " + path)
          Qt.quit()
          return
        }
        console.log("OMACHORD_TOGGLE_RENDER_SAVED", path)
        root.renderIndex++
        root.renderNext()
      })
      if (!started) {
        console.error("OMACHORD_QML_TOGGLE_TEST_FAIL", "could not grab " + path)
        Qt.quit()
      }
    }
  }

  Window {
    id: window
    visible: true
    width: 620
    height: 360
    color: Color.background

    Rectangle {
      id: scene
      anchors.fill: parent
      color: Color.background

      Column {
        visible: root.rendering
        x: 28
        y: 24
        width: parent.width - 56
        spacing: 20

        Text {
          textFormat: Text.PlainText
          text: "Pending controls — " + root.renderState
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Row {
          spacing: 24

          PendingSwitch {
            checked: root.renderState !== "off"
            busy: root.renderState === "busy"
            rounded: false
          }

          PendingSwitch {
            checked: root.renderState !== "off"
            busy: root.renderState === "busy"
            rounded: true
          }

          PendingSwitch {
            checked: root.renderState !== "off"
            busy: root.renderState === "busy"
            trackHeight: 16
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PendingToggle {
          width: parent.width
          label: "Enable saved routine"
          description: "The row keeps its size while the operation settles."
          checked: root.renderState !== "off"
          busy: root.renderState === "busy"
        }

        PendingToggle {
          width: parent.width
          label: "Optional action"
          description: "Busy also works while the current state is off."
          checked: root.renderState === "on"
          busy: root.renderState === "busy"
          rounded: true
        }
      }
    }

    // Quickshell is not qmltestrunner. Use QtTest's native event helpers with
    // explicit scheduling and assertions, as in the app's runtime harnesses.
    TestCase {
      id: input
      name: "PendingToggles"
      when: false
    }

    Timer {
      interval: 100
      running: true
      onTriggered: {
        try {
          root.testStableSwitchSize()
          root.testBusyPresentation()
          root.testActivation("PendingSwitch", "toggled")
          root.testRowPresentation()
          root.testActivation("PendingToggle", "clicked")
          root.testPressAcrossSettlement("PendingSwitch", "toggled", false)
          root.testPressAcrossSettlement("PendingToggle", "clicked", false)
          root.testPressAcrossSettlement("PendingToggle", "clicked", true)
          root.testInterruptedPress("PendingSwitch", "toggled", false)
          root.testInterruptedPress("PendingToggle", "clicked", false)
          root.testInterruptedPress("PendingToggle", "clicked", true)
          if (root.renderOutput) {
            root.rendering = true
            root.renderNext()
          } else root.finish()
        } catch (error) {
          console.error("OMACHORD_QML_TOGGLE_TEST_FAIL", error.message)
          Qt.quit()
        }
      }
    }
  }
}
