import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons

ShellRoot {
  id: root
  TestCase { id: input; name: "ThemePalette"; when: false }
  ThemePalette { id: palette; active: false }
  // Only the harness writes these bounded strings to its private fixture.
  FileView { id: colors; path: Quickshell.env("OMACHORD_THEME_DIR") + "/colors.toml"; blockWrites: true; printErrors: false }
  FileView { id: name; path: Quickshell.env("OMACHORD_THEME_NAME_FILE"); blockWrites: true; printErrors: false }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }
  function waitFor(predicate, message) {
    var until = Date.now() + 3500
    while (!predicate() && Date.now() < until) input.wait(20)
    check(predicate(), message)
  }
  function write(green, label) {
    colors.setText('green = "' + green + '"\n')
    name.setText("  " + label + "\n")
  }

  Timer {
    interval: 30
    running: true
    onTriggered: {
      try {
        input.wait(300)
        root.check(palette.revision === 0, "inactive palette started a read")
        root.write("#abcdef", "First Theme")
        palette.active = true
        root.waitFor(function() { return palette.themeName === "First Theme" && palette.hasPalette }, "initial palette did not load")
        root.waitFor(function() { return Qt.colorEqual(palette.success, "#abcdef") }, "green did not preserve its value")
        root.write("#123456", "Polled Theme")
        root.waitFor(function() { return palette.themeName === "Polled Theme" }, "active polling did not notice a direct edit")
        root.write("#654321", "Signal Theme")
        Color.foreground = "#998877"
        root.waitFor(function() { return palette.themeName === "Signal Theme" }, "Color-triggered refresh did not update the palette")
        palette.active = false
        input.wait(500)
        var revision = palette.revision
        root.write("#aabbcc", "Paused Theme")
        input.wait(2200)
        root.check(palette.revision === revision && palette.themeName === "Signal Theme", "inactive palette kept polling")
        palette.active = true
        root.waitFor(function() { return palette.themeName === "Paused Theme" }, "reactivation did not refresh")
        name.setText("x".repeat(4097))
        palette.reload()
        root.waitFor(function() { return !palette.hasPalette && palette.themeName === "" }, "oversized name did not fail to safe defaults")
        root.waitFor(function() { return Qt.colorEqual(palette.success, palette.fallbackSuccess) }, "failure lost fallback green")
        root.write("#112233", "Recovered Theme")
        palette.reload()
        root.waitFor(function() { return palette.themeName === "Recovered Theme" }, "valid files did not recover after rejection")
        palette.runnerPath = Quickshell.env("OMACHORD_QML_TEST_DIR") + "/missing-runner"
        palette.reload()
        root.waitFor(function() { return !palette.hasPalette && palette.themeName === "" }, "failed runner start retained stale palette")
        palette.active = false
        console.log("OMACHORD_QML_TEST_PASS", "bounded theme palette")
      } catch (error) {
        console.error("OMACHORD_QML_TEST_FAIL", String(error))
      }
      Qt.quit()
    }
  }
}
