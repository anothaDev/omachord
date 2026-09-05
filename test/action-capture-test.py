#!/usr/bin/env python3
"""Exercise the real capture supervisor with disposable processes and files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SUPERVISOR = ROOT / "bin/omachord-action-supervisor"


def start_time(pid):
    return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]


with tempfile.TemporaryDirectory(prefix="omachord-capture-test-") as temporary:
    fixture = Path(temporary)
    # Observe actual production kill/wait ordering. No PID reuse is forced and
    # no test signal is directed at a process outside the supervisor's children.
    (fixture / "CaptureAudit.pm").write_text(r'''
package CaptureAudit;
use strict;
use warnings;
BEGIN {
  *CORE::GLOBAL::kill = sub {
    my ($signal, @pids) = @_;
    if (open my $trace, ">>", $ENV{CAPTURE_AUDIT}) {
      for my $pid (@pids) {
        my $leader = abs($pid);
        my $present = -e "/proc/$leader/stat" ? 1 : 0;
        print {$trace} "kill $$ $leader $present\n";
      }
      close $trace;
    }
    return CORE::kill($signal, @pids);
  };
  *CORE::GLOBAL::waitpid = sub {
    my ($pid, $flags) = @_;
    my $result = CORE::waitpid($pid, $flags);
    my $status = $?;
    if (open my $trace, ">>", $ENV{CAPTURE_AUDIT}) {
      print {$trace} "wait $$ $result\n" if $result > 0;
      close $trace;
    }
    $? = $status;
    return $result;
  };
}
1;
''')
    env = os.environ.copy()
    env.update(PERL5OPT="-MCaptureAudit", PERL5LIB=str(fixture),
               CAPTURE_AUDIT=str(fixture / "audit"))
    count = 0

    def launch(mode, limit, command, duration="2s"):
        global count
        count += 1
        control = fixture / f"control-{count}"
        control.mkdir(mode=0o700)
        output = fixture / f"output-{count}"
        process = subprocess.Popen(
            [str(SUPERVISOR), str(os.getpid()), start_time(os.getpid()),
             str(control), duration, "--capture", mode, str(limit), str(output),
             "--", *command], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, env=env)
        return process, control, output

    def finish(process):
        # Keep stdin open until normal completion; EOF is cancellation.
        status = process.wait(timeout=5)
        process.stdin.close()
        errors = process.stderr.read().decode()
        process.stderr.close()
        return status, errors

    p, control, output = launch("tail", 4, ["/usr/bin/printf", "abcdefgh"])
    status, errors = finish(p)
    assert status == 0, (status, errors)
    assert output.read_bytes() == b"efgh"

    p, control, output = launch("head", 4, ["/usr/bin/bash", "-c",
        "printf abcdefgh; exec >/dev/null 2>&1; sleep 30"])
    started = time.monotonic()
    status, errors = finish(p)
    assert status == 125, (status, errors)
    assert time.monotonic() - started < 1.5
    assert output.read_bytes() == b"abcde"

    # Cancellation remains reliable when marker creation is impossible.
    ready = fixture / "ready"
    p, control, output = launch("tail", 64, ["/usr/bin/bash", "-c",
        'printf ready >"$1"; exec >/dev/null 2>&1; sleep 30', "bash", str(ready)])
    deadline = time.monotonic() + 3
    while not ready.exists() and time.monotonic() < deadline:
        time.sleep(0.005)
    assert ready.exists()
    for marker in control.iterdir():
        marker.unlink()
    control.rmdir()
    p.stdin.close()
    status = p.wait(timeout=2)
    p.stderr.close()
    assert status != 0

    # An exited command whose descendant retains output must not hang capture.
    p, control, output = launch("tail", 32, ["/usr/bin/bash", "-c",
        'printf finished; sleep 30 &'])
    started = time.monotonic()
    status, errors = finish(p)
    assert status == 0, (status, errors)
    assert output.read_bytes() == b"finished"
    assert time.monotonic() - started < 1.5

    p, control, output = launch("tail", 32, ["/usr/bin/sleep", "30"], "0.1s")
    status, errors = finish(p)
    assert status == 124, (status, errors)

    # Direct argv cannot be interpreted as options to Bash's exec builtin.
    p, control, output = launch("tail", 256, ["--", "/usr/bin/printf", "WRONG"])
    status, errors = finish(p)
    assert status != 0 and b"WRONG" not in output.read_bytes(), (status, errors)

    reaped = set()
    signals = 0
    for entry in (fixture / "audit").read_text().splitlines():
        fields = entry.split()
        identity = tuple(fields[1:3])
        if fields[0] == "wait":
            reaped.add(identity)
        else:
            signals += 1
            assert identity not in reaped, f"signal after reap: {entry}"
            assert fields[3] == "1", f"signal without retained leader: {entry}"
    assert signals > 0
    print(f"Action capture tests passed: {count} scenarios; {signals} signals retained child identity.")
