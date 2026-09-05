#!/usr/bin/python3
"""Bound panel probes before QML receives any external command/file body."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
STUB = '''#!/usr/bin/python3
import os, sys, time
from pathlib import Path
root = Path(os.environ["PROBE_FIXTURE"])
mode = os.environ.get("PROBE_MODE", "valid")
is_themes = Path(sys.argv[0]).name == "omarchy-theme-list"
assert sys.argv[1:] == ([] if is_themes else ["omachord", "status"]), sys.argv
payload = b"Tokyo Night\\nGruvbox\\n" if is_themes else b'{"ready":true,"enabled":true,"routines":[]}\\n'
if mode == "valid": os.write(1, payload)
elif mode == "benign-stderr":
    os.write(2, b"diagnostic must stay outside the reply\\n")
    os.write(1, payload)
elif mode == "document-stream": os.write(1, b"{}\\n{}\\n")
elif mode == "array": os.write(1, b"[]\\n")
elif mode == "malformed": os.write(1, b"{broken\\n")
elif mode == "nonzero":
    os.write(1, b"PARTIAL-MUST-NOT-ESCAPE")
    sys.exit(7)
elif mode in ("stdout-flood", "stderr-flood"):
    fd = 1 if mode == "stdout-flood" else 2
    while True: os.write(fd, b"x" * 65536)
elif mode == "hang": time.sleep(30)
elif mode == "held-pipe":
    os.write(1, payload)
    if os.fork() == 0:
        time.sleep(0.8)
        (root / "survived").write_text("unexpected descendant")
        os._exit(0)
else: raise AssertionError(mode)
'''


def main():
    temp_parent = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else "/tmp"
    with tempfile.TemporaryDirectory(prefix="omachord-panel-capture.", dir=temp_parent) as directory:
        base = Path(directory)
        env = {"PATH": str(base / "bin") + ":/usr/bin:/bin", "LANG": "C", "PROBE_FIXTURE": str(base),
               "OMACHORD_CONTROL_TIMEOUT": "0.2s"}
        for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_STATE_HOME", "state"), ("XDG_DATA_HOME", "data"),
                          ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"), ("TMPDIR", "tmp")):
            (base / name).mkdir(mode=0o700)
            env[key] = str(base / name)
        (base / "bin").mkdir(mode=0o700)
        for program in ("omarchy-theme-list", "omarchy-shell"):
            stub = base / "bin" / program
            stub.write_text(STUB)
            stub.chmod(0o700)

        def run(command, success, *args):
            start = time.monotonic()
            result = subprocess.run([str(ROOT / "bin/omachord"), command, *args], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
            assert time.monotonic() - start < 2, (command, env.get("PROBE_MODE"), result)
            assert (result.returncode == 0) == success, (command, result.stdout, result.stderr)
            assert len(result.stdout) <= 1048576 and len(result.stderr) <= 4096, result
            if not success:
                assert json.loads(result.stdout)["ok"] is False, result
                assert b"PARTIAL-MUST-NOT-ESCAPE" not in result.stdout, result
            return result.stdout

        for command in ("themes", "service-status"):
            for mode in ("valid", "benign-stderr", "nonzero", "stdout-flood", "stderr-flood", "hang", "held-pipe"):
                env["PROBE_MODE"] = mode
                output = run(command, mode in ("valid", "benign-stderr", "held-pipe"))
                if mode in ("valid", "benign-stderr", "held-pipe"):
                    expected = b"Tokyo Night\nGruvbox\n" if command == "themes" else b'{"ready":true,"enabled":true,"routines":[]}\n'
                    assert output == expected, output
                if mode == "held-pipe":
                    time.sleep(0.9)
                    assert not (base / "survived").exists(), "output-holding child escaped cleanup"
                print(f"PASS: {command}: {mode}")
            run(command, False, "unexpected")
        for mode in ("document-stream", "array", "malformed"):
            env["PROBE_MODE"] = mode
            run("service-status", False)

        theme = base / "theme"
        theme.mkdir(mode=0o700)
        colors = theme / "colors.toml"
        name = base / "theme.name"
        env["OMACHORD_THEME_DIR"] = str(theme)
        env["OMACHORD_THEME_NAME_FILE"] = str(name)
        colors.write_text('background = "#112233"\ngreen = "#abcdef99" # comment\n')
        name.write_text("  Tokyo Night\n")
        palette = json.loads(run("theme-palette", True))
        assert palette["green"] == "#abcdef99" and palette["name"] == "Tokyo Night", palette
        color_line = b'green="#abcdef"\n'
        colors.write_bytes(color_line + b"#" * (65536 - len(color_line)))
        assert colors.stat().st_size == 65536
        assert json.loads(run("theme-palette", True))["green"] == "#abcdef"
        name.write_bytes(b"n" * 4096)
        assert len(json.loads(run("theme-palette", True))["name"]) == 4096
        for target, limit in ((colors, 65536), (name, 4096)):
            previous = target.read_bytes()
            target.write_bytes(b"x" * (limit + 1))
            run("theme-palette", False)
            target.write_bytes(previous)
            target.unlink()
            os.mkfifo(target, mode=0o600)
            run("theme-palette", False)
            target.unlink()
            target.mkdir(mode=0o700)
            run("theme-palette", False)
            target.rmdir()
            target.write_bytes(previous)
        name.write_bytes(b"\xff")
        run("theme-palette", False)
        colors.unlink()
        name.unlink()
        palette = json.loads(run("theme-palette", True))
        assert palette["green"] == "" and palette["name"] == "", palette
        run("theme-palette", False, "unexpected")
        print("PASS: theme-palette: values, missing files, byte limits, FIFOs, directories, UTF-8")
    print("Panel capture tests passed.")


if __name__ == "__main__":
    main()
