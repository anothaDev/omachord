#!/usr/bin/env python3
"""Automatic requests queued behind Disconnect must not start afterward."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from fs_test_support import prepare_fixture

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "bin/omachord"

for ingress in ("hook", "shortcut", "shortcut-activate"):
    with tempfile.TemporaryDirectory(prefix="omachord-automatic-") as temporary:
        fixture = Path(temporary)
        instrumented_runner = prepare_fixture(ROOT, fixture / "instrumented") / "bin/omachord"
        for directory in ("home/.config/hypr", "home/.config/omarchy", "state", "data", "runtime", "tmp", "bin"):
            (fixture / directory).mkdir(parents=True, mode=0o700)
        for name, body in (("omarchy", "exit 0"), ("hyprctl", "exit 0")):
            path = fixture / "bin" / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o700)
        env = {"HOME": str(fixture / "home"), "XDG_CONFIG_HOME": str(fixture / "home/.config"),
               "XDG_STATE_HOME": str(fixture / "state"), "XDG_DATA_HOME": str(fixture / "data"),
               "XDG_RUNTIME_DIR": str(fixture / "runtime"), "TMPDIR": str(fixture / "tmp"),
               "PATH": str(fixture / "bin") + ":/usr/bin:/bin", "LC_ALL": "C",
               "OMACHORD_RUNNER_PATH": str(RUNNER)}

        def run(*args, payload=None):
            result = subprocess.run([str(RUNNER), *args], input=payload, text=True,
                                    capture_output=True, env=env, timeout=20)
            assert result.returncode == 0, (args, result.stdout, result.stderr)
            return json.loads(result.stdout)

        marker = fixture / "effect"
        config = {"version": 1, "routines": [{"id": "queued-event", "name": "Queued event", "enabled": True,
                  "triggers": [{"type": "hook", "event": "post-boot"},
                               {"type": "shortcut", "keys": "SUPER + ALT + F12", "override": False}],
                  "actions": [{"type": "exec", "program": "/usr/bin/touch", "args": [str(marker)]}],
                  "keepUntil": {"minutes": 1}}]}
        run("config", "apply", "missing", payload=json.dumps(config))
        run("connect")
        hook = fixture / "home/.config/omarchy/hooks/post-boot.d/anothadev.omachord"
        if ingress == "hook":
            command = [str(hook)]
        elif ingress == "shortcut":
            command = [str(RUNNER), "run", "queued-event", "shortcut"]
        else:
            command = [str(RUNNER), "activate", "queued-event", "shortcut"]
        successful = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        assert successful.returncode == 0 and marker.exists(), successful
        run("deactivate", "queued-event")
        marker.unlink()

        ready, release = fixture / "ready", fixture / "release"
        paused = env | {"OMACHORD_FS_TEST_MATCH": str(fixture / "home/.config/hypr/omachord.lua"),
                        "OMACHORD_FS_TEST_PAUSE": "before-publish", "OMACHORD_FS_TEST_READY": str(ready),
                        "OMACHORD_FS_TEST_RELEASE": str(release)}
        disconnect = subprocess.Popen([str(instrumented_runner), "disconnect"], env=paused,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        request = None
        try:
            deadline = time.monotonic() + 10
            while not ready.exists():
                assert disconnect.poll() is None, disconnect.communicate()
                assert time.monotonic() < deadline, "Disconnect did not reach its barrier"
                time.sleep(0.01)
            # The actual generated dispatcher still exists, but its runner
            # cannot acquire the shared lock until the exclusive transaction ends.
            request = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(0.15)
            assert request.poll() is None, "Request did not queue behind Disconnect"
            release.touch()
            disconnected, errors = disconnect.communicate(timeout=20)
            reply, request_errors = request.communicate(timeout=10)
            assert disconnect.returncode == 0 and json.loads(disconnected)["connected"] is False, errors
            assert request.returncode != 0, (ingress, reply, request_errors)
            assert json.loads(reply)["code"] == "not-connected", reply
            assert not marker.exists(), "An automatic effect ran after Off"
            assert run("active") == [], "An automatic activation survived Off"
            assert (fixture / "state/omarchy/omachord/connection.disabled.json").exists()
            # Explicit manual/test runner-only capabilities remain available.
            run("run", "queued-event", "manual")
            assert marker.exists()
            run("deactivate", "queued-event", "test")
            marker.unlink()
            run("connect")
            reenabled = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            assert reenabled.returncode == 0 and marker.exists(), reenabled
            print("PASS: queued " + ingress + " stays revoked after Off; manual and reenabled execution work.")
        finally:
            release.touch(exist_ok=True)
            for child in (disconnect, request):
                if child is not None and child.poll() is None:
                    child.terminate()
                    child.wait(timeout=20)
print("Automatic trigger revocation tests passed.")
