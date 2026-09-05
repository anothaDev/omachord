#!/usr/bin/python3
"""Native Service/Panel dictionary lifecycle coverage with isolated peers."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="ori.", dir="/tmp") as directory:
    fixture = Path(directory)
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "QT_QPA_PLATFORM": "offscreen",
           "QT_QUICK_BACKEND": "software", "OMACHORD_RUNNER_PATH": str(fixture / "runner"),
           "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(fixture / "absent-session"),
           "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=" + str(fixture / "absent-system")}
    for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                      ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")):
        (fixture / name).mkdir(mode=0o700)
        env[key] = str(fixture / name)
    for name in ("Commons", "Ui"):
        (fixture / name).symlink_to("/usr/share/omarchy/shell/" + name)
    for pattern in ("*.qml", "*.js"):
        for path in root.glob(pattern): shutil.copyfile(path, fixture / path.name)
    shutil.copyfile(root / "test/qml-runtime/routine-id-maps.qml", fixture / "shell.qml")
    (fixture / "runner").write_text('''#!/bin/bash
case "$1" in
  active|logs|toggles) printf '[]\\n' ;;
  *) printf '{"ok":false}\\n' ;;
esac
''')
    (fixture / "runner").chmod(0o700)
    result = subprocess.run(["/usr/bin/quickshell", "--no-duplicate", "--path", str(fixture / "shell.qml"),
                             "--no-color"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=15)
    if result.returncode or "OMACHORD_QML_TEST_PASS" not in result.stdout or any(
            failure in result.stdout for failure in ("OMACHORD_QML_TEST_FAIL", "TypeError", "ReferenceError", "Binding loop", "Unable to assign")):
        raise AssertionError(result.stdout)
    print("Native Service/Panel routine ID map tests passed.")
