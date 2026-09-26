#!/usr/bin/python3
"""Private runner protocol fixture: no hardware or real configuration access."""
import json
import os
import subprocess
from pathlib import Path
import sys

directory = Path(os.environ["OMACHORD_QML_TEST_DIR"])
args = sys.argv[1:]
# Accept exactly the argv the real runner accepts (shared bash grammar).
grammar = subprocess.run(["bash", "-c", 'source "$0"; fake_check_argv "$@"',
                          str(directory / "fake-runner-grammar"), *args], capture_output=True, text=True)
if grammar.returncode != 0:
    sys.stdout.write(grammar.stdout)
    sys.exit(grammar.returncode)
with (directory / "calls.log").open("a") as calls:
    calls.write(" ".join(args) + "\n")
plan = json.loads((directory / "plan.json").read_text())
active_path = directory / "fake-active.json"
logs_path = directory / "fake-logs.json"
active = json.loads(active_path.read_text()) if active_path.exists() else []
logs = json.loads(logs_path.read_text()) if logs_path.exists() else []
op = args[0]
if op == "autostart" or op == "status":
    result = {"ok": True, "connected": True, "integrationComplete": True}
elif args == ["config", "snapshot"]:
    result = {"ok": True, "committed": True, "revision": plan["revision"], "config": plan["config"]}
elif op == "active":
    result = active
elif op == "logs":
    result = logs
elif op == "toggles":
    result = plan["toggles"]
elif args == ["widget", "ensure"]:
    result = {"ok": True}
elif op in ("activate", "run", "deactivate"):
    result = plan["manualReply" if args[2] in ("manual", "test") else "reply"].copy()
    if result["ok"]:
        state = result.get("state", "deactivated" if op == "deactivate" else "activated")
        result["state"] = state
        active = [] if state in ("deactivated", "success") else [{
            "routineId": args[1], "trigger": args[2], "keepUntil": "conditions",
            "activatedAt": "2026-09-23T12:00:00Z", "expiresAt": None, "setterCount": 1,
        }]
        active_path.write_text(json.dumps(active))
        if state == "success":
            result.pop("state", None)  # Successful one-shots have no state key.
    # Match the runner's untyped failure history as well as its typed reply.
    logs.insert(0, {"routineId": args[1], "trigger": args[2],
                   "status": state if result["ok"] else "failed", "error": result.get("error", ""),
                   "timestamp": "2026-09-23T12:00:%02dZ" % len(logs)})
    logs_path.write_text(json.dumps(logs))
else:
    raise SystemExit("unexpected fixture call: " + repr(args))
print(json.dumps(result))
if isinstance(result, dict) and result.get("ok") is False:
    sys.exit(1)
