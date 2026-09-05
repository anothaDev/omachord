#!/usr/bin/env python3
"""Runner admission and write-before-publication regressions, in isolated homes."""
import hashlib
import json
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "bin/omachord"
LOADER = 'require("default.hypr.require_optional").module("hypr.omachord") -- Oma Chord managed loader'
STUB = r'''#!/usr/bin/python3
import json, os, resource, signal, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
if name == "grep":
    if args[:1] == ["-Fvx"] and os.environ.get("FAIL_FILTER") == "1":
        resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    os.execv("/usr/bin/grep", ["grep", *args])
if name == "tail":
    if args[:2] == ["-n", "200"] and os.environ.get("FAIL_ROTATION") == "1":
        resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    os.execv("/usr/bin/tail", ["tail", *args])
if name == "cat":
    if args[:1] == ["--"] and os.environ.get("FAIL_CONTROL_COPY") == "1":
        print('{"commands":[]}')
        sys.exit(2)
    os.execv("/usr/bin/cat", ["cat", *args])
if name == "jq":
    if os.environ.get("FAIL_END_ROWS") == "1" and any("select(.key >= $start)" in arg for arg in args):
        sys.exit(2)
    if os.environ.get("FAIL_SNAPSHOT_JSON") == "1" and any(".setters +=" in arg for arg in args):
        sys.exit(2)
    if os.environ.get("FAIL_LUA_JSON") == "1" and "-j" in args:
        sys.exit(2)
    if os.environ.get("FAIL_RESTORE_JSON") == "1" and any(".setters | map(select(.restore" in arg for arg in args):
        sys.exit(2)
    if os.environ.get("FAIL_CLAIMS_JSON") == "1" and any("$active.claims" in arg for arg in args):
        sys.exit(2)
    os.execv("/usr/bin/jq", ["jq", *args])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "hyprctl" and args in (["reload"], ["configerrors"]):
    sys.exit(0)
if name == "omarchy" and args == ["menu", "keybindings", "--print"]:
    sys.exit(0)
if name == "omarchy" and args == ["commands", "--json"]:
    print('{"commands":[]}')
    sys.exit(0)
if name == "omarchy-shell":
    state = root / "dnd"
    if args == ["notifications", "isDnd"]:
        print(state.read_text() if state.exists() else "off")
        sys.exit(0)
    if args[:2] == ["notifications", "setDnd"] and args[2:] in (["on"], ["off"]):
        state.write_text(args[2])
        sys.exit(0)
sys.exit(99)
'''


def document(*routines):
    return {"version": 1, "routines": list(routines)}


def routine(identifier="probe", actions=None, triggers=None, **fields):
    return {"id": identifier, "name": identifier, "enabled": True,
            "triggers": triggers or [], "actions": actions or [{"type": "exec", "program": "/usr/bin/true", "args": []}], **fields}


class Fixture:
    def __init__(self, root):
        self.root = root
        for path in ("home/.config/hypr", "home/.config/omarchy", "state", "data", "runtime", "tmp", "bin"):
            (root / path).mkdir(parents=True, mode=0o700)
        stub = root / "stub.py"
        stub.write_text(STUB)
        stub.chmod(0o700)
        for name in ("hyprctl", "omarchy", "omarchy-shell", "grep", "jq", "tail", "cat"):
            (root / "bin" / name).symlink_to(stub)
        self.env = {"HOME": str(root / "home"), "XDG_CONFIG_HOME": str(root / "home/.config"),
                    "XDG_STATE_HOME": str(root / "state"), "XDG_DATA_HOME": str(root / "data"),
                    "XDG_RUNTIME_DIR": str(root / "runtime"), "TMPDIR": str(root / "tmp"),
                    "PATH": str(root / "bin") + ":/usr/bin:/bin", "FIXTURE_ROOT": str(root),
                    "OMACHORD_RUNNER_PATH": str(RUNNER), "LC_ALL": "C"}
        self.config = root / "home/.config/omarchy/omachord.json"
        self.bindings = root / "home/.config/hypr/bindings.lua"
        self.generated = root / "home/.config/hypr/omachord.lua"
        self.state = root / "state/omarchy/omachord"
        self.commit = self.state / "config.commit.json"

    def run(self, *args, data=None, extra=None, trace=None, inject=None, fsize=None):
        command = [str(RUNNER), *args]
        if trace:
            command = ["strace", "-qq", "-y", "-s", "8192", "-e", "trace=write", "-o", str(trace),
                       *(["-e", f"inject=write:error=EIO:when={inject}"] if inject else []), *command]
        def limit():
            resource.setrlimit(resource.RLIMIT_FSIZE, (fsize, fsize))
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        return subprocess.run(command, input=data, text=True, capture_output=True, cwd=self.root,
                              env=self.env | (extra or {}), timeout=30,
                              preexec_fn=limit if fsize is not None else None,
                              restore_signals=fsize is None)

    def install(self, config):
        result = self.run("config", "apply", "missing", data=json.dumps(config))
        assert result.returncode == 0, result

    def seed(self, contents, committed=False):
        self.config.write_text(contents)
        self.config.chmod(0o600)
        if committed:
            self.state.mkdir(parents=True, mode=0o700)
            self.commit.write_text(json.dumps({"version": 1, "revision": "sha256:" + hashlib.sha256(contents.encode()).hexdigest()}))
            self.commit.chmod(0o600)


class RunnerParsingStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omachord-parsing-staging-")
        self.base = Path(self.temporary.name)
        self.count = 0

    def tearDown(self):
        self.temporary.cleanup()

    def fixture(self):
        self.count += 1
        return Fixture(self.base / str(self.count))

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result)
        self.assertFalse(json.loads(result.stdout)["ok"], result)

    def test_admission_rejects_every_non_single_document(self):
        good = json.dumps(document())
        hidden = json.dumps(document(routine("hidden", triggers=[{"type": "hook", "event": "battery-low"}])))
        for candidate in ("", " \n\t", good + hidden, good + " null", good + " true", good + " []", good + " {", "{} " + good):
            with self.subTest(candidate=candidate):
                f = self.fixture()
                self.assert_failed(f.run("config", "validate", data=candidate))
                self.assert_failed(f.run("config", "apply", "missing", data=candidate))
                self.assertFalse(f.config.exists())
                self.assertFalse(f.commit.exists())

    def test_existing_stream_is_rejected_at_read_and_execution_boundaries(self):
        f = self.fixture()
        marker = f.root / "hidden-executed"
        hidden = routine("hidden", actions=[{"type": "exec", "program": "/usr/bin/touch", "args": [str(marker)]}],
                         triggers=[{"type": "hook", "event": "battery-low"}])
        candidate = json.dumps(document()) + "\n" + json.dumps(document(hidden))
        f.seed(candidate, committed=True)
        before = f.commit.read_bytes()
        for args in (("config", "show"), ("config", "snapshot"), ("run", "hidden"),
                     ("activate", "hidden"), ("trigger", "hook", "battery-low"), ("connect",), ("autostart",)):
            with self.subTest(command=args):
                self.assert_failed(f.run(*args))
                self.assertEqual(f.config.read_text(), candidate)
                self.assertEqual(f.commit.read_bytes(), before)
                self.assertFalse(marker.exists())
                self.assertFalse(f.generated.exists())
        self.assertFalse(json.loads(f.run("status").stdout)["configValid"])

    def test_single_document_whitespace_has_one_consistent_routine_set(self):
        f = self.fixture()
        marker = f.root / "executed"
        config = document(routine(actions=[{"type": "exec", "program": "/usr/bin/touch", "args": [str(marker)]}],
                                  triggers=[{"type": "hook", "event": "battery-low"}, {"type": "shortcut", "keys": "SUPER + F12", "override": False}]))
        result = f.run("config", "apply", "missing", data=" \n\t" + json.dumps(config) + "\n \t")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(f.run("connect").returncode, 0)
        snapshot = json.loads(f.run("config", "snapshot").stdout)
        self.assertEqual(snapshot["config"], config)
        self.assertTrue(snapshot["committed"])
        self.assertIn('o.shell_quote("probe")', f.generated.read_text())
        for args in (("run", "probe"), ("activate", "probe"), ("trigger", "hook", "battery-low")):
            self.assertEqual(f.run(*args).returncode, 0)
            self.assertTrue(marker.exists())
            marker.unlink()

    def test_connected_bindings_rejects_an_invalid_config_document(self):
        f = self.fixture()
        self.assertEqual(f.run("connect").returncode, 0)
        # An invalid earlier object currently disappears into the catalogue's
        # fallback; it must not be interpreted differently from config reads.
        f.seed('{}\n' + json.dumps(document()))
        self.assert_failed(f.run("bindings"))

    def test_remove_filter_io_failure_preserves_binding_and_commit(self):
        f = self.fixture()
        f.bindings.write_text(("-- " + "x" * 124 + "\n") * 96 + "tail_setting = true\n")
        self.assertEqual(f.run("connect").returncode, 0)
        before, commit = f.bindings.read_bytes(), f.commit.read_bytes()
        self.assert_failed(f.run("disconnect", extra={"FAIL_FILTER": "1"}))
        self.assertEqual(f.bindings.read_bytes(), before)
        self.assertEqual(f.commit.read_bytes(), commit)
        self.assertFalse((f.state / "connection.disabled.json").exists())
        self.assertEqual(list((f.root / "tmp").iterdir()), [])

    def test_append_io_failure_rolls_back_without_commit(self):
        f = self.fixture()
        before = b"--" + b"x" * 16382
        f.bindings.write_bytes(before)
        self.assert_failed(f.run("connect", fsize=16384))
        self.assertEqual(f.bindings.read_bytes(), before)
        self.assertFalse(f.commit.exists())
        self.assertFalse(f.config.exists())
        self.assertFalse(f.generated.exists())
        self.assertEqual(list((f.root / "tmp").iterdir()), [])

    def test_loader_only_filter_status_one_is_success(self):
        f = self.fixture()
        self.assertEqual(f.run("connect").returncode, 0)
        f.bindings.write_text(LOADER + "\n")
        result = f.run("disconnect")
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(f.bindings.read_bytes(), b"")

    def test_lua_producer_failure_cannot_publish_header_only_output(self):
        f = self.fixture()
        f.seed(json.dumps(document(routine(triggers=[{"type": "shortcut", "keys": "SUPER + F12", "override": False}]))))
        revision = "sha256:" + hashlib.sha256(f.config.read_bytes()).hexdigest()
        self.assert_failed(f.run("connect", revision, extra={"FAIL_LUA_JSON": "1"}))
        self.assertFalse(f.generated.exists())
        self.assertFalse(f.commit.exists())

    def test_snapshot_producer_failure_precedes_setter(self):
        f = self.fixture()
        f.install(document(routine(actions=[{"type": "dnd", "value": True, "restore": True}])))
        self.assert_failed(f.run("activate", "probe", extra={"FAIL_SNAPSHOT_JSON": "1"}))
        self.assertFalse((f.root / "dnd").exists())
        snapshot = f.state / "active/probe.json"
        if snapshot.exists():
            self.assertEqual(json.loads(snapshot.read_text())["setters"], [])

    def test_failed_restore_enumeration_keeps_recovery_record(self):
        f = self.fixture()
        f.install(document(routine(actions=[{"type": "dnd", "value": True, "restore": True}])))
        self.assertEqual(f.run("activate", "probe").returncode, 0)
        snapshot = f.state / "active/probe.json"
        before = snapshot.read_bytes()
        self.assert_failed(f.run("deactivate", "probe", extra={"FAIL_RESTORE_JSON": "1"}))
        self.assertEqual(snapshot.read_bytes(), before)
        self.assertEqual((f.root / "dnd").read_text(), "on")

    def test_failed_end_enumeration_keeps_recovery_record(self):
        f = self.fixture()
        marker = f.root / "end-effect"
        f.install(document(routine(onEnd={"mode": "actions", "actions": [
            {"type": "exec", "program": "/usr/bin/touch", "args": [str(marker)]}]})))
        self.assertEqual(f.run("activate", "probe").returncode, 0)
        snapshot = f.state / "active/probe.json"
        before = snapshot.read_bytes()
        self.assert_failed(f.run("deactivate", "probe", extra={"FAIL_END_ROWS": "1"}))
        self.assertEqual(snapshot.read_bytes(), before)
        self.assertFalse(marker.exists())

    def test_failed_claim_comparison_prevents_second_setter(self):
        f = self.fixture()
        f.install(document(routine(actions=[{"type": "dnd", "value": True, "restore": True}]),
                           routine("second", actions=[{"type": "dnd", "value": False, "restore": True}])))
        self.assertEqual(f.run("activate", "probe").returncode, 0)
        self.assert_failed(f.run("activate", "second", extra={"FAIL_CLAIMS_JSON": "1"}))
        self.assertFalse((f.state / "active/second.json").exists())
        self.assertEqual((f.root / "dnd").read_text(), "on")

    def test_log_rotation_io_failure_preserves_previous_history(self):
        f = self.fixture()
        f.install(document(routine()))
        log = f.state / "runs.jsonl"
        before = (json.dumps({"error": "x" * 300}) + "\n").encode() * 1000
        log.write_bytes(before)
        log.chmod(0o600)
        self.assert_failed(f.run("run", "probe", extra={"FAIL_ROTATION": "1"}))
        self.assertEqual(log.read_bytes(), before)
        self.assertEqual(list((f.root / "tmp").iterdir()), [])

    def test_failed_control_output_copy_is_not_success(self):
        f = self.fixture()
        self.assert_failed(f.run("commands", extra={"FAIL_CONTROL_COPY": "1"}))
        self.assertEqual(list((f.root / "tmp").iterdir()), [])

    @unittest.skipUnless(shutil.which("strace"), "strace is needed for real transient write failure injection")
    def test_failed_default_snapshot_write_is_not_success(self):
        base = self.fixture()
        trace = base.root / "trace"
        self.assertEqual(base.run("config", "snapshot", trace=trace).returncode, 0)
        ordinal = self.write_ordinal(trace, r'{\"version\":1,\"routines\":[]}')
        f = self.fixture()
        trace = f.root / "trace"
        self.assert_failed(f.run("config", "snapshot", trace=trace, inject=ordinal))
        self.assertIn("INJECTED", trace.read_text())
        self.assertFalse(f.config.exists())
        self.assertFalse(f.commit.exists())
        self.assertEqual(list((f.root / "tmp").iterdir()), [])

    @unittest.skipUnless(shutil.which("strace"), "strace is needed for real transient write failure injection")
    def test_earlier_and_final_generator_writes_fail_before_publication(self):
        config = document(routine(triggers=[{"type": "shortcut", "keys": "SUPER + F12", "override": True}]))
        # This fixture deliberately admits reviewed, uncommitted bytes; bare
        # Connect now correctly refuses them before reaching the generator.
        revision = "sha256:" + hashlib.sha256(json.dumps(config).encode()).hexdigest()
        for needle in ('"-- Generated by Omachord', '"  hl.unbind(', '"  o.bind(', '"runner=', r'exec \"$runner\" trigger hook battery-low'):
            with self.subTest(write=needle):
                base = self.fixture()
                base.seed(json.dumps(config))
                trace = base.root / "trace"
                self.assertEqual(base.run("connect", revision, trace=trace).returncode, 0)
                ordinal = self.write_ordinal(trace, needle)
                f = self.fixture()
                f.seed(json.dumps(config))
                original = f.config.read_bytes()
                trace = f.root / "trace"
                self.assert_failed(f.run("connect", revision, trace=trace, inject=ordinal))
                self.assertIn("INJECTED", trace.read_text())
                self.assertEqual(f.config.read_bytes(), original)
                self.assertFalse(f.generated.exists())
                self.assertFalse(f.commit.exists())
                self.assertFalse((f.root / "home/.config/omarchy/hooks/battery-low.d/anothadev.omachord").exists())
                self.assertEqual(list((f.root / "tmp").iterdir()), [])

    @staticmethod
    def write_ordinal(trace, needle):
        lines = [line for line in trace.read_text().splitlines() if re.match(r"write\(", line)]
        return next(i + 1 for i, line in enumerate(lines) if needle in line)

    @unittest.skipUnless(shutil.which("strace"), "strace is needed for real transient write failure injection")
    def test_failed_claim_and_setter_checkpoints_have_no_setter_effect(self):
        config = document(routine(actions=[{"type": "dnd", "value": True, "restore": True}]))
        for needle in (r'\"setters\":[]', r'\"setters\":[{'):
            with self.subTest(write=needle):
                base = self.fixture()
                base.install(config)
                trace = base.root / "trace"
                self.assertEqual(base.run("activate", "probe", trace=trace).returncode, 0)
                ordinal = self.write_ordinal(trace, needle)
                f = self.fixture()
                f.install(config)
                trace = f.root / "trace"
                self.assert_failed(f.run("activate", "probe", trace=trace, inject=ordinal))
                self.assertIn("INJECTED", trace.read_text())
                self.assertFalse((f.root / "dnd").exists())
                snapshot = f.state / "active/probe.json"
                if snapshot.exists():
                    self.assertIsInstance(json.loads(snapshot.read_text()), dict)
                self.assertEqual(list((f.root / "tmp").iterdir()), [])

    @unittest.skipUnless(shutil.which("strace"), "strace is needed for real transient write failure injection")
    def test_failed_end_checkpoint_preserves_prior_record_without_effect(self):
        def prepare(f):
            marker = f.root / "end-executed"
            f.install(document(routine(onEnd={"mode": "actions", "actions": [
                {"type": "exec", "program": "/usr/bin/touch", "args": [str(marker)]}]})))
            self.assertEqual(f.run("activate", "probe").returncode, 0)
            return marker
        base = self.fixture()
        prepare(base)
        trace = base.root / "trace"
        self.assertEqual(base.run("deactivate", "probe", trace=trace).returncode, 0)
        ordinal = self.write_ordinal(trace, r'\"endActionIndex\":1')
        f = self.fixture()
        marker = prepare(f)
        snapshot = f.state / "active/probe.json"
        before = snapshot.read_bytes()
        trace = f.root / "trace"
        self.assert_failed(f.run("deactivate", "probe", trace=trace, inject=ordinal))
        self.assertIn("INJECTED", trace.read_text())
        self.assertFalse(marker.exists())
        self.assertEqual(snapshot.read_bytes(), before)
        self.assertEqual(list((f.root / "tmp").iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
