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
  readonly property string themeDir: Quickshell.env("OMACHORD_THEME_DIR")
    || (home + "/.local/state/omarchy/current/theme")
  readonly property string themeNamePath: Quickshell.env("OMACHORD_THEME_NAME_FILE")
    || (home + "/.local/state/omarchy/current/theme.name")

  // Used when the theme ships no colors.toml (older themes) or no green.
  property color fallbackSuccess: "#68c98b"
  property color success: fallbackSuccess
  Behavior on success { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  property string themeName: ""
  property bool hasPalette: false
  property int revision: 0

  function reload() {
    settle.restart()
  }

  function colorToken(text, key) {
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = /^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)["']?\s*(#.*)?$/.exec(lines[i])
      if (match && match[1] === key) return match[2]
    }
    return ""
  }

  function applyColors(text) {
    var green = colorToken(text, "green")
    hasPalette = green !== ""
    success = green ? green : fallbackSuccess
    revision++
  }

  function applyName(text) {
    themeName = String(text || "").trim()
  }

  // A theme switch replaces the staged theme directory wholesale, so a file
  // watch on the old inode goes quiet; the shell's palette change is the
  // reliable signal. The short delay lets omarchy-theme-set finish staging.
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
    onTriggered: {
      colorsFile.reload()
      nameFile.reload()
    }
  }

  FileView {
    id: colorsFile
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyColors(text())
    onLoadFailed: root.applyColors("")
    onFileChanged: reload()
  }

  FileView {
    id: nameFile
    path: root.themeNamePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyName(text())
    onLoadFailed: root.applyName("")
    onFileChanged: reload()
  }
}
