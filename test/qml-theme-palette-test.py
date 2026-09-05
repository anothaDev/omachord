#!/usr/bin/python3
"""Native ThemePalette test against the actual runner and bounded file helper."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="otp.", dir="/tmp") as directory:
    fixture = Path(directory)
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "QT_QPA_PLATFORM": "offscreen",
           "QT_QUICK_BACKEND": "software", "OMACHORD_RUNNER_PATH": str(root / "bin/omachord"),
           "OMACHORD_QML_TEST_DIR": str(fixture), "OMACHORD_THEME_DIR": str(fixture / "theme"),
           "OMACHORD_THEME_NAME_FILE": str(fixture / "theme.name")}
    for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                      ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")):
        (fixture / name).mkdir(mode=0o700)
        env[key] = str(fixture / name)
    (fixture / "theme").mkdir(mode=0o700)
    (fixture / "Commons").symlink_to("/usr/share/omarchy/shell/Commons")
    shutil.copyfile(root / "ThemePalette.qml", fixture / "ThemePalette.qml")
    shutil.copyfile(root / "test/qml-runtime/theme-palette.qml", fixture / "shell.qml")
    result = subprocess.run(["/usr/bin/quickshell", "--no-duplicate", "--path", str(fixture / "shell.qml"),
                             "--no-color"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=25)
    if result.returncode or "OMACHORD_QML_TEST_PASS" not in result.stdout or any(
            problem in result.stdout for problem in ("OMACHORD_QML_TEST_FAIL", "TypeError", "ReferenceError", "Binding loop", "Unable to assign")):
        raise AssertionError(result.stdout)
    print("Native theme palette tests passed.")
