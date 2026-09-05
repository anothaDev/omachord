#!/usr/bin/python3
"""Exercise real CAS recovery with fault injection confined to disposable helpers."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "bin/omachord-fs").read_text()
SYNC = "sub sync_handle {\n  my ($handle, $label) = @_;\n"
EXCHANGE = '  pause_for_test($destination, "after-exchange");\n'
assert SOURCE.count(SYNC) == 1, "sync injection anchor changed"
assert SOURCE.count(EXCHANGE) == 2, "CAS injection anchors changed"


def perl_literal(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def run_case(fixture, parent_root, cross_mount, operation, failure):
    case = fixture / f"{cross_mount}-{operation}-{failure}"
    case.mkdir(mode=0o700)
    parent = parent_root / case.name
    parent.mkdir(mode=0o700)
    archive = case / "archive"
    archive.mkdir(mode=0o700)
    (archive / "conflicts").mkdir(mode=0o700)
    (archive / "retired").mkdir(mode=0o700)
    for name in (".omachord-conflicts", ".omachord-retired"):
        (parent / name).mkdir(mode=0o700)
    destination = parent / "value"
    destination.write_bytes(b"baseline")
    destination.chmod(0o600)
    concurrent = parent / "concurrent"
    concurrent.write_bytes(b"concurrent")
    concurrent.chmod(0o600)
    held = os.open(destination, os.O_WRONLY | os.O_APPEND)
    identity = os.fstat(held)
    expected = "file:600:" + hashlib.sha256(b"baseline").hexdigest()

    # These exact-source substitutions are only in a fresh private fixture.
    # No production environment variable enables the injected operation.
    injected = SYNC + """
  our ($test_archiving, $test_failed);
  $test_archiving = 1 if $label =~ /\\Aarchived file /;
  if ($test_archiving && !$test_failed && (CONDITION)) {
    $test_failed = 1;
    abort_operation("durability-error", "Injected archive sync failure: $label");
  }
"""
    conditions = {
        "file": "$label =~ /\\Aarchived file /",
        "archive": "$label =~ /\\Aarchive directory /",
        "source": "$label eq " + perl_literal(f"directory containing {destination}"),
        "none": "0",
    }
    instrumented = SOURCE.replace(SYNC, injected.replace("CONDITION", conditions[failure]))
    if operation.startswith("conflict"):
        instrumented = instrumented.replace(EXCHANGE, EXCHANGE
            + "  rename(" + perl_literal(concurrent) + ", component_path($directory, $name))"
            + " or die \"fixture replacement failed: $!\";\n")
    if operation == "conflict-multiple":
        move = "sub move_noreplace {\n  my ($from_directory, $from, $to_directory, $to) = @_;\n"
        assert instrumented.count(move) == 1, "rollback move injection anchor changed"
        instrumented = instrumented.replace(move, move
            + "  return 0 if $from =~ /\\A\\.omachord-rollback\\./;\n")
    helper = case / "helper"
    helper.write_text(instrumented)
    helper.chmod(0o700)
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "HOME": str(case),
           "TMPDIR": str(case), "XDG_CONFIG_HOME": str(case / "config"),
           "XDG_STATE_HOME": str(case / "state"), "XDG_DATA_HOME": str(case / "data"),
           "XDG_CACHE_HOME": str(case / "cache"), "XDG_RUNTIME_DIR": str(case / "runtime")}
    try:
        completed = subprocess.run([str(helper), "cas-write", str(destination), "600", expected,
                                    "private", str(archive)], input=b"candidate", env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        result = json.loads(completed.stdout)
        os.write(held, b"-late")
        if operation.startswith("conflict"):
            expected_code = "rollback-failed" if operation == "conflict-multiple" else "compare-mismatch"
            assert completed.returncode == 1 and result["code"] == expected_code, result
            if operation == "conflict-multiple":
                assert not destination.exists(), result
                assert len(result["recovery"]) == 2, result
                assert {Path(item["path"]).read_bytes() for item in result["recovery"]} == {
                    b"baseline-late", b"concurrent"}, result
            else:
                assert destination.read_bytes() == b"concurrent", result
            preserved = Path(result["preserved"])
            assert preserved.exists(), f"{case.name}: nonexistent recovery locator: {result}"
            actual = preserved.stat()
            assert (actual.st_dev, actual.st_ino) == (identity.st_dev, identity.st_ino), result
            assert preserved.read_bytes() == b"baseline-late", result
            for entry in result["recovery"]:
                retained = Path(entry["path"]).stat()
                assert (str(retained.st_dev), str(retained.st_ino)) == (entry["device"], entry["inode"]), entry
                if failure == "source":
                    assert entry["archiveFileSynced"] and entry["archiveDirectorySynced"] and entry["sourceRemoved"], entry
                    # The injected failure affects just the first archived version.
                    assert entry["sourceDirectorySynced"] or "warning" in entry, entry
        else:
            assert completed.returncode == 0 and result["ok"], result
            assert destination.read_bytes() == b"candidate", result
        survivors = [p for base in (parent, archive) for p in base.rglob("*")
                     if p.is_file() and (p.stat().st_dev, p.stat().st_ino)
                     == (identity.st_dev, identity.st_ino)]
        assert survivors, f"{case.name}: held original inode has no recovery name"
        assert all(p.read_bytes() == b"baseline-late" for p in survivors), survivors
        if failure == "source" or failure == "none":
            assert all(p.parent.name in ("conflicts", "retired", ".omachord-conflicts",
                                         ".omachord-retired") for p in survivors), survivors
        print(f"PASS: {case.name}: surviving original inode and late writes")
    finally:
        os.close(held)


def main():
    temp_parent = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else "/tmp"
    with tempfile.TemporaryDirectory(prefix="omachord-recovery-test.", dir=temp_parent) as local:
        fixture = Path(local)
        same = fixture / "parents"
        same.mkdir(mode=0o700)
        for operation in ("conflict", "conflict-multiple", "retired"):
            for failure in ("source", "file", "archive", "none"):
                run_case(fixture, same, False, operation, failure)
        if not Path("/dev/shm").is_dir() or os.stat("/dev/shm").st_dev == fixture.stat().st_dev:
            raise AssertionError("cross-mount regression requires a separate /dev/shm mount")
        with tempfile.TemporaryDirectory(prefix="omachord-recovery-test.", dir="/dev/shm") as other:
            for operation in ("conflict", "conflict-multiple", "retired"):
                for failure in ("source", "file", "archive", "none"):
                    run_case(fixture, Path(other), True, operation, failure)
    print("Filesystem recovery locator tests passed.")


if __name__ == "__main__":
    main()
