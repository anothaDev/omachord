#!/usr/bin/env python3
"""Brightness capability and recovery regressions; no real display is accessed."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runner_fixture", ROOT / "test/runner-parsing-staging-test.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)

DISPLAY_STUB = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
focus = (root / "focus").read_text().strip()
if name == "hyprctl":
    if args in (["reload"], ["configerrors"]): sys.exit(0)
    if args == ["monitors", "-j"]:
        if (root / "monitor-data").exists():
            print((root / "monitor-data").read_text()); sys.exit(0)
        print(json.dumps([dict(name=n, make="Test", model="Display", serial=("replaced" if (root / ("replaced-"+n)).exists() else n),
            focused=n == focus, disabled=False, dpmsStatus=True) for n in ("DP-1", "DP-2")
            if not (root / ("absent-"+n)).exists()]))
        sys.exit(0)
if name == "omarchy-brightness-display":
    assert args.pop(0) == "--no-osd"
    target = focus
    # Like the real Omarchy wrapper, an empty --monitor falls back to focus.
    if args[:1] == ["--monitor"]: target = args[1] or focus; args = args[2:]
    fault = (root / "fault").read_text().strip()
    if not args:
        if fault == "unavailable": sys.exit(1)
        # A slow DDC display applies a write only after some later reads.
        late = root / "late-value"
        if late.exists():
            remaining = int((root / "late-reads").read_text())
            if remaining <= 0:
                (root / target).write_text(late.read_text())
                late.unlink()
            else:
                (root / "late-reads").write_text(str(remaining - 1))
        print((root / target).read_text().strip())
        if (root / "switch-after-read").exists():
            (root / "focus").write_text("DP-2")
            (root / "switch-after-read").unlink()
        sys.exit(0)
    value = int(args[0].removesuffix("%"))
    if not target.startswith(("eDP-", "LVDS-", "DSI-")): value = max(1, value)
    if fault == "write-fail": sys.exit(1)
    if fault == "rounded": value += 1
    if fault == "late":
        (root / "late-value").write_text(str(value))
        (root / "late-reads").write_text("1")
        with (root / "writes.jsonl").open("a") as log:
            log.write(json.dumps([target, value])+"\n")
    elif fault != "dropped-write":
        (root / target).write_text(str(value))
        with (root / "writes.jsonl").open("a") as log:
            log.write(json.dumps([target, value])+"\n")
        if (root / "mutate-recovery-after-write").exists():
            (root / "mutate-recovery-after-write").unlink()
            path = root / "state/omarchy/omachord/active/brightness-check.json"
            record = json.loads(path.read_text())
            record["setters"][-1]["before"] = 73
            changed = json.dumps(record)
            path.write_text(changed)
            (root / "mutated-recovery").write_text(changed)
    sys.exit(0)
sys.exit(99)
'''

NAME_FAILURE_STUB = r'''#!/usr/bin/python3
import os, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
if len(args) == 2 and "r" in args[0] and (args[1] == ".name" or args[1].startswith(".name |")):
    counter = root / "name-calls"
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if count == int(os.environ.get("FAIL_BRIGHTNESS_NAME_AT", "0")):
        (root / "name-failure").touch()
        sys.exit(2)
os.execv("/usr/bin/jq", ["jq", *sys.argv[1:]])
'''


class BrightnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omachord-brightness-")
        self.addCleanup(self.temp.cleanup)
        self.f = support.Fixture(Path(self.temp.name) / "fixture")
        f = self.f
        stub = f.root / "display.py"
        stub.write_text(DISPLAY_STUB)
        stub.chmod(0o700)
        (f.root / "bin/hyprctl").unlink()
        for name in ("hyprctl", "omarchy-brightness-display"):
            (f.root / "bin" / name).symlink_to(stub)
        for name, value in {"focus":"DP-1", "fault":"", "DP-1":"80", "DP-2":"40"}.items():
            (f.root / name).write_text(value)
        self.snapshot = f.state / "active/brightness-check.json"

    def install(self, value=40, before=None, restore=True):
        actions = list(before or []) + [{"type":"brightness", "value":value, "restore":restore}]
        self.f.install(support.document(support.routine("brightness-check", actions=actions)))

    def run_routine(self, operation, success=True):
        result = self.f.run(operation, "brightness-check", "test")
        self.assertEqual(result.returncode == 0, success, result)
        body = json.loads(result.stdout)
        self.assertEqual(body["ok"], success)
        return body

    def writes(self):
        path = self.f.root / "writes.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def seed_legacy_snapshot(self, version=2, **extra):
        plan = json.dumps({"actions":[], "mode":"restore"}, sort_keys=True, separators=(",", ":"))
        record = dict(version=version, routineId="brightness-check", activatedAt="2026-09-23T00:00:00Z",
                      trigger="test", keepUntil="conditions", expiresAt=None, onEndMode="restore",
                      endActionIndex=0, claims=["brightness"],
                      setters=[dict(index=0, type="brightness", before=80, applied=40, restore=True)])
        if version == 2:
            record["endPlanDigest"] = "sha256:" + hashlib.sha256(plan.encode()).hexdigest()
        record.update(extra)
        self.snapshot.parent.mkdir(mode=0o700, exist_ok=True)
        self.snapshot.write_text(json.dumps(record))
        self.snapshot.chmod(0o600)

    def test_failed_monitor_name_extraction_never_redirects_to_focus(self):
        self.install(restore=False)
        stub = self.f.root / "name-jq.py"
        stub.write_text(NAME_FAILURE_STUB)
        stub.chmod(0o700)
        (self.f.root / "bin/jq").unlink()
        (self.f.root / "bin/jq").symlink_to(stub)

        def reset_display():
            for name, value in {"focus":"DP-1", "DP-1":"80", "DP-2":"60"}.items():
                (self.f.root / name).write_text(value)
            for name in ("name-calls", "name-failure", "writes.jsonl"):
                (self.f.root / name).unlink(missing_ok=True)
            (self.f.root / "switch-after-read").touch()

        reset_display()
        self.run_routine("run")
        count = int((self.f.root / "name-calls").read_text())
        self.assertGreater(count, 0, "the fault shim must recognize target-name extraction")
        # Discover the external producer calls, rather than baking in the old
        # tenth-call write-argv extraction. Each injection uses the public CLI.
        for index in range(1, count + 1):
            with self.subTest(extraction=index):
                reset_display()
                result = self.f.run("run", "brightness-check", "test",
                                    extra={"FAIL_BRIGHTNESS_NAME_AT":str(index)})
                self.assertTrue((self.f.root / "name-failure").exists())
                self.assertFalse(json.loads(result.stdout)["ok"], result)
                self.assertNotEqual(result.returncode, 0, result)
                self.assertEqual((self.f.root / "DP-2").read_text(), "60")
                self.assertTrue(all(target == "DP-1" for target, _ in self.writes()))

    def test_end_brightness_requirement_blocks_all_start_effects(self):
        marker = self.f.root / "earlier-effect"
        self.f.install(support.document(support.routine("brightness-check",
            actions=[{"type":"exec", "program":"/usr/bin/touch", "args":[str(marker)]}],
            onEnd={"mode":"actions", "actions":[{"type":"brightness", "value":20, "restore":False}]})))
        (self.f.root / "fault").write_text("unavailable")
        result = self.run_routine("activate", success=False)
        self.assertEqual(result["code"], "brightness-unavailable")
        self.assertFalse(marker.exists())
        self.assertFalse(self.snapshot.exists())
        self.assertEqual(self.writes(), [])

    def test_end_brightness_uses_activation_target_after_focus_changes(self):
        self.f.install(support.document(support.routine("brightness-check",
            actions=[{"type":"brightness", "value":40, "restore":True}],
            onEnd={"mode":"actions", "actions":[{"type":"brightness", "value":20, "restore":False}]})))
        (self.f.root / "DP-2").write_text("60")
        self.run_routine("activate")
        (self.f.root / "focus").write_text("DP-2")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "20")
        self.assertEqual((self.f.root / "DP-2").read_text(), "60")
        self.assertEqual(self.writes(), [["DP-1", 40], ["DP-1", 80], ["DP-1", 20]])

    def test_failed_end_requirement_producer_never_falls_back(self):
        self.f.install(support.document(support.routine("brightness-check",
            actions=[{"type":"exec", "program":"/usr/bin/true", "args":[]}],
            onEnd={"mode":"actions", "actions":[{"type":"brightness", "value":20, "restore":False}]})))
        self.run_routine("activate")
        record = json.loads(self.snapshot.read_text())
        record["version"] = 2
        record.pop("brightnessTarget")
        self.snapshot.write_text(json.dumps(record))
        stub = self.f.root / "failed-end-jq.py"
        stub.write_text('''#!/usr/bin/python3
import os, sys
if any("any(.onEnd.actions[]" in arg for arg in sys.argv[1:]): sys.exit(2)
os.execv("/usr/bin/jq", ["jq", *sys.argv[1:]])
''')
        stub.chmod(0o700)
        (self.f.root / "bin/jq").unlink()
        (self.f.root / "bin/jq").symlink_to(stub)
        self.run_routine("deactivate", success=False)
        self.assertTrue(self.snapshot.exists())
        self.assertEqual(self.writes(), [])

    def test_final_nonrestoring_effect_cannot_silently_replace_recovery(self):
        script = ('import json,sys; from pathlib import Path; p=Path(sys.argv[1]); '
                  'r=json.loads(p.read_text()); r["setters"][0]["before"]=73; '
                  'p.write_text(json.dumps(r))')
        self.f.install(support.document(support.routine("brightness-check", actions=[
            {"type":"brightness", "value":40, "restore":True},
            {"type":"exec", "program":"/usr/bin/python3", "args":["-c", script, str(self.snapshot)]}])))
        self.run_routine("activate", success=False)
        self.assertEqual(json.loads(self.snapshot.read_text())["setters"][0]["before"], 73)
        self.assertEqual(self.writes(), [["DP-1", 40]])

    def test_unconfirmed_restore_rounding_retains_recovery_on_retry(self):
        self.install()
        self.run_routine("activate")
        (self.f.root / "fault").write_text("rounded")
        self.run_routine("deactivate", success=False)
        self.assertEqual((self.f.root / "DP-1").read_text(), "81")
        self.assertTrue(self.snapshot.exists())
        writes = self.writes()
        (self.f.root / "fault").write_text("")
        self.run_routine("deactivate", success=False)
        self.assertTrue(self.snapshot.exists())
        self.assertEqual(json.loads(self.snapshot.read_text())["setters"][0]["before"], 80)
        self.assertEqual((self.f.root / "DP-1").read_text(), "81")
        self.assertEqual(self.writes(), writes, "an uncertain restore must not guess on retry")

    def test_concurrent_recovery_change_is_retained_without_rollback_writes(self):
        marker = self.f.root / "later-effect"
        self.f.install(support.document(support.routine("brightness-check", actions=[
            {"type":"dnd", "value":True, "restore":True},
            {"type":"brightness", "value":40, "restore":True},
            {"type":"exec", "program":"/usr/bin/touch", "args":[str(marker)]}])))
        (self.f.root / "mutate-recovery-after-write").touch()
        self.run_routine("activate", success=False)
        changed = self.f.root / "mutated-recovery"
        self.assertTrue(changed.exists(), "the concurrent mutation must actually occur")
        self.assertEqual(self.snapshot.read_bytes(), changed.read_bytes())
        self.assertEqual(self.writes(), [["DP-1", 40]], "CAS conflict must stop rollback writes")
        self.assertEqual((self.f.root / "DP-1").read_text(), "40")
        self.assertEqual((self.f.root / "dnd").read_text(), "on")
        self.assertFalse(marker.exists())

    def test_binding_legacy_partial_write_does_not_confirm_or_discard_it(self):
        self.install()
        self.seed_legacy_snapshot()
        (self.f.root / "DP-1").write_text("41")
        inspection = self.f.run("recovery", "inspect", "brightness-check")
        self.assertEqual(inspection.returncode, 0, inspection)
        revision = json.loads(inspection.stdout)["revision"]
        reply = self.f.run("recovery", "bind-brightness", "brightness-check", revision, "DP-1")
        self.assertEqual(reply.returncode, 0, reply)
        self.assertEqual(self.writes(), [], "binding must not change physical brightness")
        self.run_routine("deactivate", success=False)
        self.assertTrue(self.snapshot.exists())
        self.assertEqual((self.f.root / "DP-1").read_text(), "41")
        self.assertEqual(self.writes(), [])

    def test_repeated_brightness_actions_preserve_manual_earlier_value(self):
        self.install(value=60, before=[{"type":"brightness", "value":40, "restore":True}])
        self.run_routine("activate")
        self.assertEqual(self.writes(), [["DP-1", 40], ["DP-1", 60]])
        (self.f.root / "DP-1").write_text("40")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "40")
        self.assertEqual(self.writes(), [["DP-1", 40], ["DP-1", 60]])
        self.assertFalse(self.snapshot.exists())

    def test_binding_v1_extra_digest_never_publishes_invalid_recovery(self):
        self.install()
        self.seed_legacy_snapshot(version=1, endPlanDigest="not-a-digest")
        (self.f.root / "DP-1").write_text("40")
        original = self.snapshot.read_bytes()
        inspection = self.f.run("recovery", "inspect", "brightness-check")
        if inspection.returncode != 0:
            self.assertFalse(json.loads(inspection.stdout)["ok"])
            self.assertEqual(self.snapshot.read_bytes(), original)
            self.assertEqual(self.writes(), [])
            return
        revision = json.loads(inspection.stdout)["revision"]
        reply = self.f.run("recovery", "bind-brightness", "brightness-check", revision, "DP-1")
        self.assertEqual(self.writes(), [])
        if reply.returncode != 0:
            self.assertFalse(json.loads(reply.stdout)["ok"])
            self.assertEqual(self.snapshot.read_bytes(), original)
            return
        # Safe rejection or normalization are both allowed; success must leave
        # a record that the public recovery API can still read and restore.
        updated = self.f.run("recovery", "inspect", "brightness-check")
        self.assertEqual(updated.returncode, 0, updated)
        self.assertEqual(json.loads(updated.stdout)["snapshot"]["version"], 3)
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")

    def test_malformed_availability_metadata_blocks_all_effects(self):
        marker = self.f.root / "earlier-effect"
        self.install(before=[{"type":"exec", "program":"/usr/bin/touch", "args":[str(marker)]}])
        for field, value in (("disabled", "true"), ("dpmsStatus", "false"),
                             ("disabled", None), ("dpmsStatus", 1)):
            with self.subTest(field=field, value=value):
                monitor = dict(name="DP-1", make="Test", model="Display", serial="DP-1",
                               focused=True, disabled=False, dpmsStatus=True)
                monitor[field] = value
                (self.f.root / "monitor-data").write_text(json.dumps([monitor]))
                result = self.run_routine("activate", success=False)
                self.assertEqual(result["code"], "brightness-unavailable")
                self.assertFalse(marker.exists())
                self.assertFalse(self.snapshot.exists())
                self.assertEqual(self.writes(), [])

    def test_unavailable_brightness_blocks_entire_activation_before_effects(self):
        marker = self.f.root / "earlier-effect"
        self.install(before=[{"type":"exec", "program":"/usr/bin/touch", "args":[str(marker)]}])
        (self.f.root / "fault").write_text("unavailable")
        result = self.run_routine("activate", success=False)
        self.assertEqual(result["code"], "brightness-unavailable")
        self.assertFalse(marker.exists(), "capability preflight must precede every routine effect")
        self.assertFalse(self.snapshot.exists())
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")

    def test_focus_changes_never_redirect_activation_or_restore(self):
        self.install()
        (self.f.root / "DP-2").write_text("60")
        (self.f.root / "switch-after-read").touch()
        self.run_routine("activate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "40")
        self.assertEqual((self.f.root / "DP-2").read_text(), "60")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")
        self.assertEqual((self.f.root / "DP-2").read_text(), "60")

    def test_external_zero_normalization_does_not_lose_recovery(self):
        self.install(value=0)
        self.run_routine("activate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "1")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")

    def test_dropped_write_does_not_report_activation(self):
        self.install()
        (self.f.root / "fault").write_text("dropped-write")
        self.run_routine("activate", success=False)
        self.assertFalse(self.snapshot.exists(), "an unchanged before value needs no recovery")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")

    def test_unavailable_nonrestoring_run_has_no_earlier_effects(self):
        marker = self.f.root / "earlier-effect"
        self.install(restore=False, before=[{"type":"exec", "program":"/usr/bin/touch", "args":[str(marker)]}])
        (self.f.root / "fault").write_text("unavailable")
        result = self.run_routine("run", success=False)
        self.assertEqual(result["code"], "brightness-unavailable")
        self.assertFalse(marker.exists())

    def test_failed_read_retains_recovery_until_target_returns(self):
        self.install()
        self.run_routine("activate")
        original = self.snapshot.read_bytes()
        (self.f.root / "fault").write_text("unavailable")
        self.run_routine("deactivate", success=False)
        self.assertEqual(self.snapshot.read_bytes(), original)
        (self.f.root / "fault").write_text("")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")

    def test_disconnected_or_replaced_target_never_falls_back(self):
        self.install()
        self.run_routine("activate")
        original = self.snapshot.read_bytes()
        (self.f.root / "focus").write_text("DP-2")
        for prefix in ("absent-", "replaced-"):
            marker = self.f.root / (prefix+"DP-1")
            marker.touch()
            self.run_routine("deactivate", success=False)
            self.assertEqual(self.snapshot.read_bytes(), original)
            self.assertEqual((self.f.root / "DP-2").read_text(), "40")
            marker.unlink()

    def test_unconfirmed_rounding_keeps_recovery_not_a_false_override(self):
        self.install()
        (self.f.root / "fault").write_text("rounded")
        self.run_routine("activate", success=False)
        self.assertTrue(self.snapshot.exists())
        self.assertFalse(json.loads(self.snapshot.read_text())["setters"][0]["confirmed"])
        self.run_routine("deactivate", success=False)
        self.assertTrue(self.snapshot.exists())

    def test_confirmed_manual_override_is_preserved(self):
        self.install()
        self.run_routine("activate")
        (self.f.root / "DP-1").write_text("55")
        result = self.run_routine("deactivate")
        self.assertEqual(result["skipped"], 1)
        self.assertEqual((self.f.root / "DP-1").read_text(), "55")

    def test_legacy_recovery_requires_revision_bound_explicit_display(self):
        self.install()
        self.run_routine("activate")
        record = json.loads(self.snapshot.read_text())
        record["version"] = 2
        record.pop("brightnessTarget", None)
        for setter in record["setters"]:
            setter.pop("target", None)
            setter.pop("confirmed", None)
        self.snapshot.write_text(json.dumps(record))
        self.run_routine("deactivate", success=False)
        inspection = json.loads(self.f.run("recovery", "inspect", "brightness-check").stdout)
        stale = self.f.run("recovery", "bind-brightness", "brightness-check", "sha256:"+"0"*64, "DP-1")
        self.assertNotEqual(stale.returncode, 0)
        reply = self.f.run("recovery", "bind-brightness", "brightness-check", inspection["revision"], "DP-1")
        self.assertEqual(reply.returncode, 0, reply)
        self.assertEqual(json.loads(self.snapshot.read_text())["version"], 3)
        updated = json.loads(self.f.run("recovery", "inspect", "brightness-check").stdout)
        refused = self.f.run("recovery", "bind-brightness", "brightness-check", updated["revision"], "DP-2")
        self.assertNotEqual(refused.returncode, 0, "a bound target must not be redirected")
        (self.f.root / "focus").write_text("DP-2")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")
        self.assertEqual((self.f.root / "DP-2").read_text(), "40")

    def test_internal_backlight_can_use_real_zero(self):
        (self.f.root / "monitor-data").write_text(json.dumps([
            dict(name="eDP-1", make="Test", model="Panel", serial="panel", focused=True)]))
        (self.f.root / "eDP-1").write_text("80")
        self.install(value=0)
        self.run_routine("activate")
        self.assertEqual((self.f.root / "eDP-1").read_text(), "0")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "eDP-1").read_text(), "80")

    def test_untargetable_apple_helper_is_not_called(self):
        (self.f.root / "monitor-data").write_text(json.dumps([
            dict(name="DP-1", make="Apple Computer Inc", model="StudioDisplay", serial="apple", focused=True)]))
        self.install()
        result = self.run_routine("activate", success=False)
        self.assertEqual(result["code"], "brightness-unavailable")
        self.assertFalse((self.f.root / "writes.jsonl").exists())

    def test_failed_restore_write_keeps_confirmed_receipt(self):
        self.install()
        self.run_routine("activate")
        original = json.loads(self.snapshot.read_text())["setters"][0]
        (self.f.root / "fault").write_text("write-fail")
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                self.run_routine("deactivate", success=False)
                retained = json.loads(self.snapshot.read_text())["setters"][0]
                for field in ("before", "applied", "target", "confirmed"):
                    self.assertEqual(retained[field], original[field])
                self.assertEqual(retained["restoreState"], "pending")
                self.assertEqual((self.f.root / "DP-1").read_text(), "40")

    def test_recovery_target_schema_rejects_malformed_control_data(self):
        self.install()
        self.run_routine("activate")
        original = json.loads(self.snapshot.read_text())
        for target in (None, {}, {"name":"--help", "identity":"sha256:"+"a"*64},
                       {"name":"DP-1", "identity":"untrusted"}):
            with self.subTest(target=target):
                record = json.loads(json.dumps(original))
                record["setters"][0]["target"] = target
                self.snapshot.write_text(json.dumps(record))
                result = self.run_routine("deactivate", success=False)
                self.assertEqual(result["code"], "unsafe-state")
                self.assertEqual((self.f.root / "DP-1").read_text(), "40")

    def test_restore_only_recovery_preserves_brightness_schema_and_target(self):
        self.install()
        self.run_routine("activate")
        before = json.loads(self.snapshot.read_text())["setters"][0]["target"]
        inspection = json.loads(self.f.run("recovery", "inspect", "brightness-check").stdout)
        (self.f.root / "fault").write_text("unavailable")
        reply = self.f.run("recovery", "restore", "brightness-check", inspection["revision"], "--skip-end-actions")
        self.assertNotEqual(reply.returncode, 0)
        record = json.loads(self.snapshot.read_text())
        self.assertEqual(record["version"], 3)
        self.assertEqual(record["setters"][0]["target"], before)

    def inspect_revision(self):
        inspection = self.f.run("recovery", "inspect", "brightness-check")
        self.assertEqual(inspection.returncode, 0, inspection)
        return json.loads(inspection.stdout)["revision"]

    def hold_after_rounded_restore(self):
        self.install()
        self.run_routine("activate")
        (self.f.root / "fault").write_text("rounded")
        self.run_routine("deactivate", success=False)
        (self.f.root / "fault").write_text("")
        held = self.run_routine("deactivate", success=False)
        self.assertEqual(held["code"], "brightness-held", held)
        self.assertIn("accept-brightness", held["error"])
        self.assertEqual((self.f.root / "DP-1").read_text(), "81")

    def test_external_zero_original_is_restored_as_backend_minimum(self):
        (self.f.root / "DP-1").write_text("0")
        self.install()
        self.run_routine("activate")
        self.assertEqual(json.loads(self.snapshot.read_text())["setters"][0]["before"], 0)
        result = self.run_routine("deactivate")
        self.assertEqual(result["restored"], 1)
        self.assertFalse(self.snapshot.exists(), "restoring an original 0 must complete")
        self.assertEqual((self.f.root / "DP-1").read_text(), "1")
        self.assertEqual(self.writes(), [["DP-1", 40], ["DP-1", 1]])

    def test_external_zero_pending_restore_completes_at_minimum(self):
        (self.f.root / "DP-1").write_text("0")
        self.install()
        self.run_routine("activate")
        record = json.loads(self.snapshot.read_text())
        record["setters"][0]["restoreState"] = "pending"
        self.snapshot.write_text(json.dumps(record))
        (self.f.root / "DP-1").write_text("1")
        self.run_routine("deactivate")
        self.assertFalse(self.snapshot.exists())
        self.assertEqual(self.writes(), [["DP-1", 40]], "an already-restored minimum needs no write")

    def test_accept_brightness_releases_held_record_without_writing(self):
        self.hold_after_rounded_restore()
        writes = self.writes()
        stale = self.f.run("recovery", "accept-brightness", "brightness-check", "sha256:"+"0"*64)
        self.assertNotEqual(stale.returncode, 0)
        self.assertEqual(json.loads(stale.stdout)["code"], "stale-recovery")
        self.assertTrue(self.snapshot.exists())
        usage = self.f.run("recovery", "accept-brightness", "brightness-check")
        self.assertEqual(json.loads(usage.stdout)["code"], "usage")
        reply = self.f.run("recovery", "accept-brightness", "brightness-check", self.inspect_revision())
        self.assertEqual(reply.returncode, 0, reply)
        body = json.loads(reply.stdout)
        self.assertEqual(body["state"], "deactivated")
        self.assertFalse(self.snapshot.exists())
        self.assertEqual((self.f.root / "DP-1").read_text(), "81", "the display is left as it is")
        self.assertEqual(self.writes(), writes)

    def test_accept_brightness_is_bound_to_the_inspected_record(self):
        self.hold_after_rounded_restore()
        revision = self.inspect_revision()
        record = json.loads(self.snapshot.read_text())
        record["activatedAt"] = "2026-09-24T00:00:00Z"
        changed = json.dumps(record)
        self.snapshot.write_text(changed)
        reply = self.f.run("recovery", "accept-brightness", "brightness-check", revision)
        self.assertEqual(json.loads(reply.stdout)["code"], "stale-recovery", reply)
        self.assertEqual(self.snapshot.read_text(), changed)

    def test_accept_brightness_requires_an_unresolved_brightness_entry(self):
        self.f.install(support.document(support.routine("brightness-check",
            actions=[{"type":"dnd", "value":True, "restore":True}])))
        self.run_routine("activate")
        original = self.snapshot.read_bytes()
        reply = self.f.run("recovery", "accept-brightness", "brightness-check", self.inspect_revision())
        self.assertEqual(json.loads(reply.stdout)["code"], "invalid-recovery", reply)
        self.assertEqual(self.snapshot.read_bytes(), original)

    def test_upgraded_legacy_manual_change_can_be_accepted(self):
        self.install()
        self.seed_legacy_snapshot()
        (self.f.root / "DP-1").write_text("41")
        reply = self.f.run("recovery", "bind-brightness", "brightness-check", self.inspect_revision(), "DP-1")
        self.assertEqual(reply.returncode, 0, reply)
        self.assertEqual(self.run_routine("deactivate", success=False)["code"], "brightness-held")
        reply = self.f.run("recovery", "accept-brightness", "brightness-check", self.inspect_revision())
        self.assertEqual(reply.returncode, 0, reply)
        self.assertFalse(self.snapshot.exists())
        self.assertEqual((self.f.root / "DP-1").read_text(), "41")
        self.assertEqual(self.writes(), [])

    def test_bind_can_confirm_a_legacy_write_still_showing_its_value(self):
        self.install()
        for live, confirmed in (("40", True), ("41", False)):
            with self.subTest(live=live):
                self.seed_legacy_snapshot()
                (self.f.root / "DP-1").write_text(live)
                reply = self.f.run("recovery", "bind-brightness", "brightness-check", self.inspect_revision(),
                                   "DP-1", "--confirm-if-applied")
                self.assertEqual(reply.returncode, 0, reply)
                self.assertIs(json.loads(self.snapshot.read_text())["setters"][0]["confirmed"], confirmed)
                self.assertEqual(self.writes(), [])
        # A confirmed receipt makes a later manual change an override, not a hold.
        self.seed_legacy_snapshot()
        (self.f.root / "DP-1").write_text("40")
        self.f.run("recovery", "bind-brightness", "brightness-check", self.inspect_revision(), "DP-1", "--confirm-if-applied")
        (self.f.root / "DP-1").write_text("55")
        self.assertEqual(self.run_routine("deactivate")["skipped"], 1)
        self.assertEqual((self.f.root / "DP-1").read_text(), "55")
        bad = self.f.run("recovery", "bind-brightness", "brightness-check", "sha256:"+"0"*64, "DP-1", "--confirm")
        self.assertEqual(json.loads(bad.stdout)["code"], "usage")

    def test_bind_rejects_legacy_end_actions_without_brightness(self):
        self.f.install(support.document(support.routine("brightness-check",
            actions=[{"type":"exec", "program":"/usr/bin/true", "args":[]}],
            onEnd={"mode":"actions", "actions":[{"type":"exec", "program":"/usr/bin/true", "args":[]}]})))
        self.run_routine("activate")
        record = json.loads(self.snapshot.read_text())
        self.assertEqual(record["version"], 2)
        original = self.snapshot.read_bytes()
        reply = self.f.run("recovery", "bind-brightness", "brightness-check", self.inspect_revision(), "DP-1")
        self.assertEqual(json.loads(reply.stdout)["code"], "invalid-recovery", reply)
        self.assertEqual(self.snapshot.read_bytes(), original)

    def test_bind_accepts_legacy_end_actions_that_use_brightness(self):
        self.f.install(support.document(support.routine("brightness-check",
            actions=[{"type":"exec", "program":"/usr/bin/true", "args":[]}],
            onEnd={"mode":"actions", "actions":[{"type":"brightness", "value":20, "restore":False}]})))
        self.run_routine("activate")
        record = json.loads(self.snapshot.read_text())
        record["version"] = 2
        record.pop("brightnessTarget")
        self.snapshot.write_text(json.dumps(record))
        reply = self.f.run("recovery", "bind-brightness", "brightness-check", self.inspect_revision(), "DP-1")
        self.assertEqual(reply.returncode, 0, reply)
        self.assertEqual(json.loads(self.snapshot.read_text())["version"], 3)
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "20")

    def test_late_applying_write_is_confirmed_by_rereading(self):
        self.install()
        (self.f.root / "fault").write_text("late")
        self.run_routine("activate")
        setter = json.loads(self.snapshot.read_text())["setters"][0]
        self.assertTrue(setter["confirmed"])
        self.assertEqual(setter["applied"], 40)
        self.assertEqual((self.f.root / "DP-1").read_text(), "40")
        self.run_routine("deactivate")
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")
        self.assertEqual(self.writes(), [["DP-1", 40], ["DP-1", 80]])

    def test_value_still_at_original_is_not_final_until_it_settles(self):
        self.install()
        self.run_routine("activate")
        record = json.loads(self.snapshot.read_text())
        record["setters"][0]["restoreState"] = "pending"
        self.snapshot.write_text(json.dumps(record))
        # The display reads 80 once, then an earlier write to 40 lands.
        (self.f.root / "DP-1").write_text("80")
        (self.f.root / "late-value").write_text("40")
        (self.f.root / "late-reads").write_text("1")
        self.run_routine("deactivate", success=False)
        self.assertEqual(json.loads(self.snapshot.read_text())["setters"][0]["restoreState"], "pending")
        self.assertEqual(self.writes(), [["DP-1", 40]])
        self.run_routine("deactivate")
        self.assertFalse(self.snapshot.exists())
        self.assertEqual((self.f.root / "DP-1").read_text(), "80")

    def test_backlight_step_rounding_is_tolerated_and_recorded(self):
        (self.f.root / "monitor-data").write_text(json.dumps([
            dict(name="eDP-1", make="Test", model="Panel", serial="panel", focused=True)]))
        (self.f.root / "eDP-1").write_text("80")
        self.install()
        (self.f.root / "fault").write_text("rounded")
        self.run_routine("activate")
        setter = json.loads(self.snapshot.read_text())["setters"][0]
        self.assertTrue(setter["confirmed"])
        self.assertEqual(setter["applied"], 41, "applied records what the backlight really shows")
        self.run_routine("deactivate")
        self.assertFalse(self.snapshot.exists())
        self.assertEqual((self.f.root / "eDP-1").read_text(), "81")

    def test_backlight_tolerance_is_one_step_only(self):
        (self.f.root / "monitor-data").write_text(json.dumps([
            dict(name="eDP-1", make="Test", model="Panel", serial="panel", focused=True)]))
        (self.f.root / "eDP-1").write_text("80")
        self.install()
        (self.f.root / "fault").write_text("dropped-write")
        self.run_routine("activate", success=False)
        self.assertFalse(self.snapshot.exists())
        self.assertEqual((self.f.root / "eDP-1").read_text(), "80")


if __name__ == "__main__":
    unittest.main()
