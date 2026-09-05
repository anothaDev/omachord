import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The parts of the active Omarchy theme the shell does not expose: its name
// and its success green. Foreground, background, accent, and urgent already
// arrive live through qs.Commons.Color (omarchy-theme-set pushes them over
// shell IPC), so this item listens to those changes and re-reads the staged
// theme files right after, which keeps every color in step with a theme
// switch without a restart.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configuredRunnerPath: Quickshell.env("OMACHORD_RUNNER_PATH")
  property string runnerPath: configuredRunnerPath.indexOf("/") === 0
    ? configuredRunnerPath
    : home + "/.config/omarchy/plugins/anothadev.omachord/bin/omachord"
  property bool active: visible
  property bool readQueued: false

  // Used when the theme ships no colors.toml (older themes) or no green.
  property color fallbackSuccess: "#68c98b"
  property color success: fallbackSuccess
  Behavior on success { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  property string themeName: ""
  property bool hasPalette: false
  property int revision: 0

  function reload() {
    if (active) settle.restart()
  }

  function applyPalette(result) {
    var green = result && typeof result.green === "string"
      && /^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$/.test(result.green) ? result.green : ""
    hasPalette = green !== ""
    success = green ? green : fallbackSuccess
    themeName = result && typeof result.name === "string" ? result.name : ""
    revision++
  }

  function readPalette() {
    if (!active) return
    if (paletteProc.running) readQueued = true
    else { paletteProc.startPending = true; paletteProc.running = true }
  }

  function finishRead(result) {
    applyPalette(result && result.ok === true ? result : null)
    if (readQueued) {
      readQueued = false
      Qt.callLater(readPalette)
    }
  }

  onActiveChanged: {
    if (active) reload()
    else { settle.stop(); readQueued = false }
  }
  Component.onCompleted: reload()

  // Shell changes settle for 250ms. A coalesced 2s active-only poll also picks
  // up direct file edits without FileView's unbounded eager reads.
  Connections {
    target: Color
    function onForegroundChanged() { root.reload() }
    function onBackgroundChanged() { root.reload() }
    function onAccentChanged() { root.reload() }
    function onShellValuesChanged() { root.reload() }
  }

  Timer {
    id: settle
    interval: 250
    repeat: false
    onTriggered: root.readPalette()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.active
    onTriggered: root.readPalette()
  }

  Process {
    id: paletteProc
    property bool startPending: false
    command: [root.runnerPath, "theme-palette"]
    stdout: StdioCollector { id: paletteOutput; waitForEnd: true }
    onStarted: startPending = false
    onExited: function(exitCode) {
      startPending = false
      var result = null
      if (exitCode === 0) {
        try { result = JSON.parse(paletteOutput.text) } catch (e) {}
      }
      root.finishRead(result)
    }
    onRunningChanged: if (!running && startPending)
      Qt.callLater(function() {
        if (paletteProc.running || !paletteProc.startPending) return
        paletteProc.startPending = false
        root.finishRead(null)
      })
  }
}
