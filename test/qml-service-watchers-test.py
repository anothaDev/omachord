#!/usr/bin/python3
"""Actual Service metadata watchers notify without loading rejected file bodies."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
QML = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property bool ready: false
  Service { id: service }
  function verify() {
    var watchers = 0
    for (var i = 0; i < service.data.length; i++) {
      var item = service.data[i]
      if (item.watchChanges !== true) continue
      watchers++
      if (item.preload !== false || item.loaded !== false)
        throw new Error("watcher loaded input: " + item.path + " preload=" + item.preload + " loaded=" + item.loaded)
    }
    if (watchers !== 6) throw new Error("expected all six service watchers: " + watchers)
    if (service.configLoaded) throw new Error("oversized fixture unexpectedly admitted")
  }
  Timer {
    interval: 1500
    running: true
    onTriggered: {
      try { root.verify(); root.ready = true; console.log("WATCHERS_READY") }
      catch (error) { console.error("WATCHERS_FAIL", String(error)); Qt.quit() }
    }
  }
  FileView {
    path: Quickshell.env("WATCHER_FIXTURE") + "/done"
    preload: false
    watchChanges: true
    onFileChanged: {
      if (!root.ready) return
      try { root.verify(); console.log("WATCHERS_PASS") }
      catch (error) { console.error("WATCHERS_FAIL", String(error)) }
      Qt.quit()
    }
  }
}
'''
RUNNER = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["WATCHER_FIXTURE"])
with (root / "calls").open("a") as output: output.write(json.dumps(sys.argv[1:]) + "\\n")
command = sys.argv[1]
if command in ("active", "logs", "toggles"): print("[]")
elif command == "config": print('{"ok":false,"error":"fixture rejects oversized uncommitted config"}')
elif command == "status": print('{"ok":true,"connected":false,"integrationComplete":false,"configValid":false}')
else: print('{"ok":false,"error":"unavailable fixture"}')
'''


def main():
    assert shutil.which("strace"), "strace is required to verify native file reads"
    version = subprocess.check_output(["/usr/bin/quickshell", "--version"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="osw.", dir="/tmp") as directory:
        fixture = Path(directory)
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "QT_QPA_PLATFORM": "offscreen",
               "QT_QUICK_BACKEND": "software", "WATCHER_FIXTURE": str(fixture),
               "OMACHORD_RUNNER_PATH": str(fixture / "runner"),
               "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(fixture / "absent-session"),
               "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=" + str(fixture / "absent-system")}
        for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                          ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
                          ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")):
            (fixture / name).mkdir(mode=0o700)
            env[key] = str(fixture / name)
        state = fixture / "state/omarchy/omachord"
        state.mkdir(mode=0o700, parents=True)
        active = state / "active"
        active.mkdir(mode=0o700)
        toggles = fixture / "state/omarchy/toggles"
        toggles.mkdir(mode=0o700)
        config = fixture / "oversized.json"
        config.write_bytes(b" " * 8388608)
        files = [config, state / "config.commit.json", state / "connection.json", state / "runs.jsonl"]
        for path in files[1:]: path.write_text("uncommitted sentinel\n")
        (fixture / "done").touch()
        (fixture / "calls").touch()
        env["OMACHORD_STATE_DIR"] = str(state)
        env["OMACHORD_CONFIG_FILE"] = str(config)
        for name in ("Service.qml", "Conditions.js"):
            shutil.copyfile(ROOT / name, fixture / name)
        (fixture / "runner").write_text(RUNNER)
        (fixture / "runner").chmod(0o700)
        (fixture / "shell.qml").write_text(QML)
        log = fixture / "runtime.log"
        trace = fixture / "reads.log"
        with log.open("w") as output:
            process = subprocess.Popen(["/usr/bin/strace", "-qq", "-f", "-yy", "-s", "0",
                "-e", "trace=read,pread64,readv", "-o", str(trace), "/usr/bin/quickshell",
                "--no-duplicate", "--path", str(fixture / "shell.qml"), "--no-color"],
                env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            def wait_for(predicate):
                until = time.monotonic() + 8
                while not predicate():
                    assert process.poll() is None, log.read_text()
                    assert time.monotonic() < until, log.read_text()
                    time.sleep(0.01)
            def calls(command):
                return sum(json.loads(line)[:len(command)] == command
                           for line in (fixture / "calls").read_text().splitlines())
            try:
                wait_for(lambda: "WATCHERS_READY" in log.read_text())
                changes = [(config, ["config", "snapshot"]), (files[1], ["config", "snapshot"]),
                           (files[1], ["status"]), (files[2], ["status"]), (files[3], ["logs"]),
                           (active / "record", ["active"]), (toggles / "flag", ["toggles"])]
                for path, command in changes:
                    before = calls(command)
                    with path.open("ab") as target: target.write(b"x")
                    wait_for(lambda: calls(command) > before)
                (fixture / "done").write_text("done")
                process.wait(timeout=8)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=3)
        result = log.read_text()
        assert process.returncode == 0 and "WATCHERS_PASS" in result and "WATCHERS_FAIL" not in result, result
        syscalls = trace.read_text()
        for path in files:
            reads = re.findall(r"\b(?:read|pread64|readv)\(\d+<" + re.escape(str(path)) + r">", syscalls)
            assert not reads, "native body read bypassed admission: " + str(path)
        print(f"Service metadata watchers passed on {version}: six unloaded watchers, seven refresh notifications, zero body reads (8 MiB rejected config).")


if __name__ == "__main__":
    main()
