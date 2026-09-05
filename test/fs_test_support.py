"""Explicitly build disposable filesystem fault-injection fixtures.

Production executables never import this module or select it through an
environment variable. Normal test calls still execute the shipped files;
only the individual race/failure calls select the generated fixture path.
Every substitution asserts its cardinality so source drift cannot silently
turn an adversarial test into an ordinary successful operation.
"""
import argparse
from pathlib import Path
import shutil


FIXTURE_HOOKS = r'''
# Fixture-only hooks, inserted explicitly by test/fs_test_support.py.
use Fcntl qw(LOCK_EX);
our $ACTIVE_SYNC_PATH = "";
our $SYNC_COUNT = 0;
our $FINGERPRINT_COUNT = 0;

sub fixture_sync {
  my ($label) = @_;
  if (defined($ENV{OMACHORD_FS_TEST_MATCH})
      && $ENV{OMACHORD_FS_TEST_MATCH} eq $ACTIVE_SYNC_PATH
      && defined($ENV{OMACHORD_FS_TEST_FAIL_SYNC})) {
    $SYNC_COUNT++;
    abort_operation("durability-error", "Forced filesystem test sync failure: $label")
      if $SYNC_COUNT == $ENV{OMACHORD_FS_TEST_FAIL_SYNC};
  }
}

sub fixture_fingerprint {
  my ($path) = @_;
  if (defined($ENV{OMACHORD_FS_TEST_MATCH})
      && $ENV{OMACHORD_FS_TEST_MATCH} eq $ACTIVE_SYNC_PATH
      && defined($ENV{OMACHORD_FS_TEST_FAIL_FINGERPRINT})) {
    $FINGERPRINT_COUNT++;
    abort_operation("compare-mismatch", "Forced unstable filesystem test fingerprint: $path")
      if $FINGERPRINT_COUNT == $ENV{OMACHORD_FS_TEST_FAIL_FINGERPRINT};
  }
}

sub fixture_remove {
  my ($destination) = @_;
  if (defined($ENV{OMACHORD_FS_TEST_MATCH})
      && $ENV{OMACHORD_FS_TEST_MATCH} eq $destination
      && $ENV{OMACHORD_FS_TEST_FAIL_REMOVE}) {
    abort_operation("io-error", "Forced filesystem test removal failure: $destination");
  }
}

sub pause_for_test {
  my ($destination, $phase) = @_;
  return unless defined($ENV{OMACHORD_FS_TEST_MATCH})
    && $ENV{OMACHORD_FS_TEST_MATCH} eq $destination
    && defined($ENV{OMACHORD_FS_TEST_PAUSE})
    && $ENV{OMACHORD_FS_TEST_PAUSE} eq $phase;
  my $ready = $ENV{OMACHORD_FS_TEST_READY} // "";
  my $release = $ENV{OMACHORD_FS_TEST_RELEASE} // "";
  abort_operation("io-error", "Incomplete filesystem test synchronization")
    unless $ready =~ m{^/} && $release =~ m{^/};
  my $ordinal = $ENV{OMACHORD_FS_TEST_ORDINAL} // 1;
  abort_operation("io-error", "Invalid filesystem test ordinal")
    unless $ordinal =~ /\A[1-9][0-9]*\z/;
  if (defined $ENV{OMACHORD_FS_TEST_COUNT_FILE}) {
    my $count_path = $ENV{OMACHORD_FS_TEST_COUNT_FILE};
    abort_operation("io-error", "Invalid filesystem test count path")
      unless $count_path =~ m{^/};
    sysopen(my $count_file, $count_path, O_RDWR | O_CREAT, 0600)
      or abort_operation("io-error", "Could not open filesystem test count: $!");
    flock($count_file, LOCK_EX)
      or abort_operation("io-error", "Could not lock filesystem test count: $!");
    seek($count_file, 0, 0);
    my $count = <$count_file> // 0;
    $count = 0 unless $count =~ /\A[0-9]+\s*\z/;
    $count++;
    seek($count_file, 0, 0);
    truncate($count_file, 0);
    print {$count_file} "$count\n";
    sync_handle($count_file, "filesystem test count");
    return if $count != $ordinal;
  } else {
    return if -e $ready;
  }
  sysopen(my $marker, $ready, O_WRONLY | O_CREAT | O_EXCL, 0600)
    or abort_operation("io-error", "Could not publish filesystem test phase: $!");
  close $marker;
  select undef, undef, undef, 0.005 until -e $release;
}
'''


def replace_once(source, anchor, replacement):
    count = source.count(anchor)
    if count != 1:
        raise AssertionError(f"Fixture anchor must occur once (found {count}): {anchor!r}")
    return source.replace(anchor, replacement, 1)


def instrument_fs(source):
    if "OMACHORD_FS_TEST_" in source or "pause_for_test" in source:
        raise AssertionError("Expected an uninstrumented production helper")
    source = replace_once(source, "our @RECOVERY_ENTRIES;\n", "our @RECOVERY_ENTRIES;\n" + FIXTURE_HOOKS)
    for header, call in (
        ("sub sync_handle {\n  my ($handle, $label) = @_;\n", "  fixture_sync($label);\n"),
        ("sub stable_fingerprint_handle {\n  my ($file, $path, $require_private) = @_;\n", "  fixture_fingerprint($path);\n"),
    ):
        source = replace_once(source, header, header + call)
    source = replace_once(source, "  return -1 if !@paths;\n",
                          "  return -1 if !@paths || $ENV{OMACHORD_FS_TEST_FAIL_FUSER};\n")
    for header, destination, fingerprint in (
        ("sub atomic_write {\n  my ($destination, $mode_text, $policy, $archive_root, $expected) = @_;\n", "$destination", True),
        ("sub cas_remove {\n  my ($destination, $expected, $policy, $archive_root) = @_;\n", "$destination", True),
        ("sub unique_write {\n  my ($directory_path, $prefix, $mode_text) = @_;\n", "$directory_path", False),
    ):
        reset = f"  local $ACTIVE_SYNC_PATH = {destination};\n  local $SYNC_COUNT = 0;\n"
        if fingerprint:
            reset += "  local $FINGERPRINT_COUNT = 0;\n"
        source = replace_once(source, header, header + reset)

    # These are real production operation boundaries, not dormant hooks in
    # the shipped executable. Keep the insertion point and scope explicit.
    anchors = (
        ('    stage_from_stdin($directory, $destination, $mode, ".omachord.");\n',
         '  pause_for_test($destination, "before-publish");\n', False),
        ('  if (!exchange_entries($directory, $temporary, $directory, $name, $destination)) {\n',
         '  pause_for_test($destination, "before-exchange");\n', True),
        ('  my $observed;\n  my $observed_ok = eval {\n',
         '  pause_for_test($destination, "after-exchange");\n', True),
        ('  if ($expected eq "missing") {\n    abort_operation("parent-changed", "The parent directory changed while checking $destination")\n',
         '    pause_for_test($destination, "before-publish");\n', False),
        ('  my ($placeholder, $file) = create_file($directory, ".omachord-remove.", 0600);\n',
         '  fixture_remove($destination);\n', True),
        ('  if (!parent_is_current($parent, $policy, $identity)) {\n    unlink_entry($directory, $placeholder, $destination);\n',
         '  pause_for_test($destination, "before-publish");\n', True),
        ('  if (!exchange_entries($directory, $placeholder, $directory, $name, $destination)) {\n',
         '  pause_for_test($destination, "before-exchange");\n', True),
        ('  my $observed = eval { fingerprint_entry($directory, $placeholder, $destination, 0) };\n',
         '  pause_for_test($destination, "after-exchange");\n', True),
        ('  my $directory_identity = "$opened_stat[0]:$opened_stat[1]";\n',
         '  pause_for_test($path, "before-scan");\n', False),
    )
    for anchor, insertion, before in anchors:
        if "while checking" in anchor:
            replacement = anchor.replace('    abort_operation', insertion + '    abort_operation', 1)
        else:
            replacement = insertion + anchor if before else anchor + insertion
        source = replace_once(source, anchor, replacement)
    return source


def prepare_fixture(source, destination):
    source = Path(source).resolve(strict=True)
    destination = Path(destination)
    # Never mutate an installation, reuse a stale copy, or silently follow a
    # destination symlink. The test's TemporaryDirectory owns this new tree.
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Fixture destination must be new: {destination}")
    destination.mkdir(mode=0o700)
    (destination / "bin").mkdir(mode=0o700)
    instrumented = instrument_fs((source / "bin/omachord-fs").read_text())
    for path in (source / "bin").iterdir():
        if path.is_file():
            shutil.copy2(path, destination / "bin" / path.name)
    helper = destination / "bin/omachord-fs"
    helper.write_text(instrumented)
    helper.chmod(0o700)
    (destination / "assets").symlink_to(source / "assets", target_is_directory=True)
    if (destination / "bin/omachord").read_bytes() != (source / "bin/omachord").read_bytes():
        raise AssertionError("The fixture runner must remain byte-identical to production")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    print(prepare_fixture(arguments.source, arguments.destination))
