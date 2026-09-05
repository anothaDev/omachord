#!/usr/bin/env python3
"""Shipped executables must ignore ambient fixture-only instrumentation flags."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin/omachord-fs"
RUNNER = ROOT / "bin/omachord"


class ProductionInstrumentationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omachord-production-boundary-")
        self.root = Path(self.temporary.name)
        self.env = {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"}
        self.destination = self.root / "value"
        self.archive = self.root / "archive"

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, payload=b"payload", extra=None):
        return subprocess.run([str(HELPER), "atomic-write", str(self.destination), "600", "private", str(self.archive)],
                              input=payload, capture_output=True, env=self.env | (extra or {}), timeout=3)

    def test_count_symlink_cannot_rewrite_unrelated_sentinel(self):
        sentinel = self.root / "sentinel"
        sentinel.write_bytes(b"41\n")
        count = self.root / "count"
        count.symlink_to(sentinel)
        result = self.write(extra={"OMACHORD_FS_TEST_MATCH": str(self.destination),
                                  "OMACHORD_FS_TEST_PAUSE": "before-publish", "OMACHORD_FS_TEST_ORDINAL": "99",
                                  "OMACHORD_FS_TEST_COUNT_FILE": str(count),
                                  "OMACHORD_FS_TEST_READY": str(self.root / "ready"),
                                  "OMACHORD_FS_TEST_RELEASE": str(self.root / "release")})
        self.assertEqual(sentinel.read_bytes(), b"41\n", result)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(self.destination.read_bytes(), b"payload")
        self.assertFalse((self.root / "ready").exists())

    def test_count_and_ready_paths_are_never_created(self):
        external = self.root / "unrelated"
        external.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(external, target_is_directory=True)
        release = self.root / "release"
        release.touch()
        result = self.write(extra={"OMACHORD_FS_TEST_MATCH": str(self.destination),
                                  "OMACHORD_FS_TEST_PAUSE": "before-publish",
                                  "OMACHORD_FS_TEST_COUNT_FILE": str(self.root / "count"),
                                  "OMACHORD_FS_TEST_READY": str(alias / "ready"),
                                  "OMACHORD_FS_TEST_RELEASE": str(release)})
        self.assertEqual(((self.root / "count").exists(), (external / "ready").exists()),
                         (False, False), result)
        self.assertEqual(result.returncode, 0, result)

    def test_sync_and_fingerprint_fault_flags_do_not_change_publication(self):
        for name in ("OMACHORD_FS_TEST_FAIL_SYNC", "OMACHORD_FS_TEST_FAIL_FINGERPRINT"):
            with self.subTest(flag=name):
                result = self.write(extra={"OMACHORD_FS_TEST_MATCH": str(self.destination), name: "1"})
                self.assertEqual(result.returncode, 0, result)
                self.assertEqual(self.destination.read_bytes(), b"payload")

    def test_remove_fault_flag_does_not_block_removal(self):
        self.assertEqual(self.write().returncode, 0)
        result = subprocess.run([str(HELPER), "remove-file", str(self.destination), "private", str(self.archive)],
                                capture_output=True, timeout=3, env=self.env | {
                                    "OMACHORD_FS_TEST_MATCH": str(self.destination), "OMACHORD_FS_TEST_FAIL_REMOVE": "1"})
        self.assertEqual(result.returncode, 0, result)
        self.assertFalse(self.destination.exists())

    def test_fuser_fault_flag_does_not_force_retention(self):
        self.assertEqual(self.write(b"original").returncode, 0)
        result = self.write(b"replacement", {"OMACHORD_FS_TEST_FAIL_FUSER": "1"})
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(self.destination.read_bytes(), b"replacement")
        retained = [path for path in self.root.rglob("*") if path.is_file() and path.read_bytes() == b"original"]
        self.assertEqual(retained, [], result)

    def runner_environment(self):
        for directory in ("home/.config/hypr", "home/.config/omarchy", "state", "data", "runtime", "tmp", "bin"):
            (self.root / directory).mkdir(parents=True, mode=0o700, exist_ok=True)
        omarchy = self.root / "bin/omarchy"
        omarchy.write_text("#!/bin/bash\nexit 0\n")
        omarchy.chmod(0o700)
        hyprctl = self.root / "bin/hyprctl"
        hyprctl.write_text('''#!/bin/bash
printf '%s\\n' "$1" >>"$FIXTURE_ROOT/calls"
case $1 in
  reload) touch "$FIXTURE_ROOT/reloaded" ;;
  configerrors)
    if [[ ${REJECT_RELOAD:-0} == 1 && -e $FIXTURE_ROOT/reloaded ]]; then
      printf '%s\\n' 'fixture compositor rejected the candidate'
    fi
    ;;
  *) exit 1 ;;
esac
''')
        hyprctl.chmod(0o700)
        return {"HOME": str(self.root / "home"), "XDG_CONFIG_HOME": str(self.root / "home/.config"),
                "XDG_STATE_HOME": str(self.root / "state"), "XDG_DATA_HOME": str(self.root / "data"),
                "XDG_RUNTIME_DIR": str(self.root / "runtime"), "TMPDIR": str(self.root / "tmp"),
                "PATH": str(self.root / "bin") + ":/usr/bin:/bin", "LC_ALL": "C.UTF-8",
                "OMACHORD_RUNNER_PATH": str(RUNNER), "FIXTURE_ROOT": str(self.root),
                "OMACHORD_SKIP_HYPR_RELOAD": "1"}

    def test_skip_flag_does_not_skip_reload_or_error_queries(self):
        result = subprocess.run([str(RUNNER), "connect"], capture_output=True, text=True, timeout=10,
                                env=self.runner_environment())
        self.assertEqual(result.returncode, 0, result)
        calls = (self.root / "calls").read_text().splitlines() if (self.root / "calls").exists() else []
        self.assertIn("reload", calls)
        self.assertGreaterEqual(calls.count("configerrors"), 2)

    def test_skip_flag_cannot_hide_compositor_rejection(self):
        result = subprocess.run([str(RUNNER), "connect"], capture_output=True, text=True, timeout=10,
                                env=self.runner_environment() | {"REJECT_RELOAD": "1"})
        self.assertNotEqual(result.returncode, 0, result)
        self.assertFalse(json.loads(result.stdout)["ok"], result)
        self.assertFalse((self.root / "state/omarchy/omachord/config.commit.json").exists())

    def test_production_has_no_instrumentation_entry_points(self):
        for path in (HELPER, RUNNER):
            with self.subTest(path=path.name):
                source = path.read_text()
                self.assertFalse("OMACHORD_FS_TEST_" in source, f"{path.name} still admits filesystem test hooks")
                self.assertFalse("OMACHORD_SKIP_HYPR_RELOAD" in source, f"{path.name} still admits reload bypass")


if __name__ == "__main__":
    unittest.main(verbosity=2)
