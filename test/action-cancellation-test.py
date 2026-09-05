#!/usr/bin/env python3
"""Exercise real runner startup cancellation without changing production code.

--ref copies the exact three executables from a Git revision into the fixture;
without --ref, it copies the current supplied source. All state and BASH_ENV
instrumentation remain under a disposable private fixture.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--ref")
args = parser.parse_args()

DEBUG_ENV = r'''
set -T
trap '
  if [[ -n ${ACTIVE_SUPERVISOR_PID:-} ]]; then
    inject=false
    if [[ $CANCEL_WINDOW == before-duplicate && $BASH_COMMAND == "pipe_in="* ]]; then
      inject=true
    elif [[ $CANCEL_WINDOW == after-duplicate && $BASH_COMMAND == "exec {pipe_in}>&-" ]]; then
      inject=true
    fi
    if [[ $inject == true ]]; then
      trap - DEBUG
      printf "%s\n" "$BASH_COMMAND" >"$CANCEL_TRACE"
      kill -TERM "$BASHPID"
    fi
  fi
' DEBUG
'''

results = []
with tempfile.TemporaryDirectory(prefix="omachord-startup-cancel-") as temporary:
    base = Path(temporary)
    plugin = base / "plugin"
    (plugin / "bin").mkdir(parents=True, mode=0o700)
    for name in ("omachord", "omachord-fs", "omachord-action-supervisor"):
        path = "bin/" + name
        data = subprocess.check_output(["git", "show", f"{args.ref}:{path}"], cwd=args.source) if args.ref else (args.source / path).read_bytes()
        destination = plugin / path
        destination.write_bytes(data)
        destination.chmod(0o700)
    runner = plugin / "bin/omachord"
    hook = base / "debug.bash"
    hook.write_text(DEBUG_ENV)
    for window in ("before-duplicate", "after-duplicate"):
        fixture = base / window
        for directory in ("home/.config/hypr", "home/.config/omarchy", "state", "data", "runtime", "tmp"):
            (fixture / directory).mkdir(parents=True, mode=0o700)
        env = {"HOME": str(fixture / "home"), "XDG_CONFIG_HOME": str(fixture / "home/.config"),
               "XDG_STATE_HOME": str(fixture / "state"), "XDG_DATA_HOME": str(fixture / "data"),
               "XDG_RUNTIME_DIR": str(fixture / "runtime"), "TMPDIR": str(fixture / "tmp"),
               "PATH": "/usr/bin:/bin", "LC_ALL": "C", "OMACHORD_RUNNER_PATH": str(runner)}
        config = {"version": 1, "routines": [{"id": "cancel-probe", "name": "Cancel probe", "enabled": True,
                  "triggers": [], "actions": [{"type": "exec", "program": "/usr/bin/sleep", "args": ["30"]}]}]}
        installed = subprocess.run([str(runner), "config", "apply", "missing"], input=json.dumps(config),
                                   text=True, capture_output=True, cwd=fixture, env=env, timeout=5)
        assert installed.returncode == 0, installed
        trace = fixture / "signal-window"
        env.update(BASH_ENV=str(hook), CANCEL_WINDOW=window, CANCEL_TRACE=str(trace), OMACHORD_ACTION_TIMEOUT="1.2s")
        started = time.monotonic()
        result = subprocess.run([str(runner), "run", "cancel-probe"], text=True, capture_output=True,
                                cwd=fixture, env=env, timeout=5)
        elapsed = time.monotonic() - started
        injected = trace.read_text().strip() if trace.exists() else "<not injected>"
        # The normal timeout deliberately keeps the old bug finite. Correct
        # EOF cancellation completes well before that timeout, even with the
        # runner's config-validation startup and a 50 ms TERM/KILL grace.
        passed = result.returncode == 143 and trace.exists() and elapsed < 0.8
        row = {"window": window, "status": result.returncode, "elapsed_ms": round(elapsed * 1000),
               "injected_before": injected, "passed": passed}
        results.append(row)
        print(json.dumps(row), flush=True)
raise SystemExit(0 if all(row["passed"] for row in results) else 1)
