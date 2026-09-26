// Where the runner and its configuration live, and how its replies parse.
// Shared by Service.qml, Panel.qml, BarWidget.qml and ThemePalette.qml. It
// never reads the environment itself: callers pass Quickshell.env() values,
// so the same code runs under Node.

var PLUGIN_ID = "anothadev.omachord"

// Mirrors bin/omachord: OMACHORD_OMARCHY_CONFIG_DIR, else ~/.config/omarchy.
function omarchyConfigDir(home, configured) {
  return configured ? String(configured) : String(home || "") + "/.config/omarchy"
}

// Mirrors bin/omachord: OMACHORD_CONFIG_FILE, else omachord.json there.
function configPath(configured, configDir) {
  return configured ? String(configured) : String(configDir) + "/omachord.json"
}

// Only an absolute OMACHORD_RUNNER_PATH is honoured; a relative one would
// resolve against the shell's working directory. Next comes the loaded
// plugin's own copy, then the default install location.
function runnerPath(configured, manifest, configDir) {
  var override = String(configured || "")
  if (override.indexOf("/") === 0) return override
  if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir) + "/bin/omachord"
  return String(configDir) + "/plugins/" + PLUGIN_ID + "/bin/omachord"
}

function parseJson(text, fallback) {
  try { return JSON.parse(String(text || "")) } catch (e) { return fallback }
}
