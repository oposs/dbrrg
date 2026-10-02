#!/usr/bin/env python3
"""Offline tests for upgrade-image.

upgrade-image has no .py extension and is executed, not imported, so these
tests load it through importlib. It guards its entry point with
`if __name__ == "__main__"`, so importing it runs no UI.

Everything here runs unprivileged. mount, umount and dbrrg-save-home are
replaced with fakes; tar is real, because archiving a temporary directory
needs no privileges and the archive's contents are the assertion.
"""

import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "overlay" / "usr" / "bin" / "upgrade-image"


def load_upgrade_image():
    spec = importlib.util.spec_from_loader(
        "upgrade_image",
        importlib.machinery.SourceFileLoader("upgrade_image", str(SCRIPT)),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ui = load_upgrade_image()


class TestSaveHomeBeforeFinish(unittest.TestCase):
    """The save before a reboot must not be killed or silently discarded."""

    def test_timeout_exceeds_the_scripts_own_ping_bound(self):
        # dbrrg-save-home pings the boot server for up to 60s BEFORE it starts
        # the tar and the upload. A 60s timeout here killed it mid-upload.
        with mock.patch.object(ui.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                ui.save_home_before_finish()
        timeout = run.call_args.kwargs["timeout"]
        self.assertGreater(
            timeout, 60,
            "timeout must exceed dbrrg-save-home's own 60s ping bound",
        )

    def test_a_refusal_is_reported_not_swallowed(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 3, b"", b"boot server unreachable\n"
            )
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                rc = ui.save_home_before_finish()
        self.assertEqual(rc, 3)
        self.assertIn(
            "WARNING: your home directory was NOT saved",
            stdout.getvalue(),
            "warning message not logged",
        )
        self.assertIn(
            "the boot server could not be reached",
            stdout.getvalue(),
            "exit code reason not logged",
        )
        self.assertIn(
            "boot server unreachable",
            stderr.getvalue(),
            "stderr from dbrrg-save-home not echoed",
        )

    def test_a_timeout_is_reported_not_swallowed(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.side_effect = subprocess.TimeoutExpired(["dbrrg-save-home"], 600)
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = ui.save_home_before_finish()
        self.assertNotEqual(rc, 0)
        self.assertIn(
            "WARNING: saving the home directory timed out after 600s",
            stdout.getvalue(),
            "timeout warning not logged",
        )

    def test_a_missing_script_is_reported_not_swallowed(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.side_effect = FileNotFoundError()
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = ui.save_home_before_finish()
        self.assertEqual(rc, -1)
        self.assertIn(
            "WARNING: could not run dbrrg-save-home",
            stdout.getvalue(),
            "missing script warning not logged",
        )

    def test_success_returns_zero(self):
        with mock.patch.object(ui.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = ui.save_home_before_finish()
        self.assertEqual(rc, 0)
        # Success should print no warnings
        self.assertNotIn(
            "WARNING",
            stdout.getvalue(),
            "success case should not print warnings",
        )


class TestHomeArchiveArgv(unittest.TestCase):
    """The tar command line that writes a new stick's home.tar.gz."""

    def setUp(self):
        patcher = mock.patch.object(ui, "SAVE_HOME_EXCLUDE_DEFAULT", "/nonexistent")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_excludes_the_ssh_host_keys(self):
        argv = ui.home_archive_argv("/home/tluser", "/mnt/home.tar.gz")
        self.assertIn("--exclude=./.dbrrg-ssh-host-keys", argv)

    def test_archives_relative_to_the_home_directory(self):
        # restore_home() unpacks into the home directory itself, so members
        # must be relative: the archive is built with -C <home> and a bare ".".
        argv = ui.home_archive_argv("/home/tluser", "/mnt/home.tar.gz")
        self.assertIn("-C", argv)
        self.assertEqual(argv[argv.index("-C") + 1], "/home/tluser")
        self.assertEqual(argv[-1], ".")

    def test_writes_to_the_given_destination(self):
        argv = ui.home_archive_argv("/home/tluser", "/mnt/home.tar.gz")
        self.assertIn("/mnt/home.tar.gz", argv)


class TestHomeArchiveContents(unittest.TestCase):
    """Run the real tar and look inside the result."""

    def setUp(self):
        patcher = mock.patch.object(ui, "SAVE_HOME_EXCLUDE_DEFAULT", "/nonexistent")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.work = tempfile.TemporaryDirectory()
        self.home = Path(self.work.name) / "home"
        (self.home / ".dbrrg-ssh-host-keys").mkdir(parents=True)
        (self.home / ".dbrrg-ssh-host-keys" / "ssh_host_ed25519_key").write_text(
            "PRIVATE KEY"
        )
        (self.home / ".dbrrg-sessionrc").write_text("wlr-randr --output DP-1\n")
        (self.home / ".config" / "dbrrg" / "menu").mkdir(parents=True)
        (self.home / ".config" / "dbrrg" / "menu" / "15-mine.desktop").write_text(
            "[Desktop Entry]\nName=Mine\n"
        )
        self.dest = Path(self.work.name) / "home.tar.gz"

    def tearDown(self):
        self.work.cleanup()

    def _members(self):
        with tarfile.open(self.dest, "r:gz") as tf:
            return tf.getnames()

    def test_the_ssh_identity_is_not_in_the_archive(self):
        # Copying it gives two machines the same SSH host key. The new stick
        # must generate its own on first boot.
        subprocess.run(
            ui.home_archive_argv(str(self.home), str(self.dest)), check=True
        )
        joined = "\n".join(self._members())
        self.assertNotIn(".dbrrg-ssh-host-keys", joined)

    def test_the_users_own_settings_are_in_the_archive(self):
        subprocess.run(
            ui.home_archive_argv(str(self.home), str(self.dest)), check=True
        )
        members = self._members()
        self.assertIn("./.dbrrg-sessionrc", members)
        self.assertIn("./.config/dbrrg/menu/15-mine.desktop", members)




class TestHomeArchiveExcludes(unittest.TestCase):
    """The exclude list is the one dbrrg-save-home uses, plus machine identity."""

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        root = Path(self.work.name)
        self.home = root / "home"
        self.home.mkdir()
        self.dest = root / "home.tar.gz"
        self.default = root / "default-exclude"
        patcher = mock.patch.object(ui, "SAVE_HOME_EXCLUDE_DEFAULT", str(self.default))
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in (".cache", ".other-cache", ".keep"):
            (self.home / name).mkdir()
            (self.home / name / "f").write_text("x")
        (self.home / ".dbrrg-ssh-host-keys").mkdir()
        (self.home / ".dbrrg-ssh-host-keys" / "k").write_text("PRIVATE")
        (self.home / "wg0.conf").write_text("PrivateKey = secret\n")
        (self.home / ".dbrrg-password").write_text("hash\n")

    def _members(self):
        subprocess.run(
            ui.home_archive_argv(str(self.home), str(self.dest)), check=True
        )
        with tarfile.open(self.dest, "r:gz") as tf:
            return tf.getnames()

    def test_the_default_list_is_applied(self):
        self.default.write_text("./.cache\n")
        members = self._members()
        self.assertNotIn("./.cache/f", members)
        self.assertIn("./.other-cache/f", members)

    def test_a_user_file_replaces_the_default(self):
        self.default.write_text("./.cache\n")
        (self.home / ".save-home-exclude").write_text("./.other-cache\n")
        members = self._members()
        self.assertIn("./.cache/f", members)
        self.assertNotIn("./.other-cache/f", members)

    def test_blank_lines_and_comments_are_skipped(self):
        self.default.write_text("# a comment\n\n./.cache\n\n")
        argv = ui.home_archive_argv(str(self.home), str(self.dest))
        patterns = [a for a in argv if a.startswith("--exclude=")]
        self.assertNotIn("--exclude=", patterns)
        self.assertNotIn("--exclude=# a comment", patterns)
        self.assertIn("--exclude=./.cache", patterns)

    def test_identity_is_excluded_even_when_a_user_file_ignores_it(self):
        (self.home / ".save-home-exclude").write_text("./.cache\n")
        joined = "\n".join(self._members())
        self.assertNotIn(".dbrrg-ssh-host-keys", joined)
        self.assertNotIn("wg0.conf", joined)

    def test_the_remote_access_password_is_in_the_archive(self):
        self.default.write_text("./.cache\n")
        self.assertIn("./.dbrrg-password", self._members())

    def test_no_exclude_file_at_all_still_archives(self):
        self.assertIn("./.keep/f", self._members())

class TestCopyHomeToDrive(unittest.TestCase):
    """The wrapper that mounts, archives and unmounts.

    Every test patches time.sleep. copy_home_to_drive retries the EFI lookup
    for EFI_RETRY_SECONDS, so a test that leaves the real sleep in place takes
    that many seconds to assert one boolean.
    """

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.home = Path(self.work.name) / "home"
        self.home.mkdir()
        (self.home / ".dbrrg-sessionrc").write_text("x\n")

        out = contextlib.redirect_stdout(io.StringIO())
        out.__enter__()
        self.addCleanup(out.__exit__, None, None, None)

        sleep = mock.patch.object(ui.time, "sleep")
        self.sleep = sleep.start()
        self.addCleanup(sleep.stop)

    def _as_tluser(self):
        """Make getpwnam("tluser") resolve to this test's temp home."""
        return mock.patch.object(
            ui.pwd, "getpwnam", return_value=mock.Mock(pw_dir=str(self.home))
        )

    def test_a_missing_tluser_account_is_reported_not_crashed(self):
        # On an image where the account was renamed, getpwnam raises KeyError.
        # A traceback AFTER the image is written reads as a failed install.
        with mock.patch.object(ui.pwd, "getpwnam", side_effect=KeyError("tluser")):
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()

    def test_no_efi_partition_retries_then_reports(self):
        with self._as_tluser():
            with mock.patch.object(
                ui, "find_efi_partition", return_value=None
            ) as find:
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        # udev may not have re-read the new partition table yet, right after
        # partprobe on a drive written byte for byte. One look is not enough.
        self.assertGreater(ui.EFI_RETRY_SECONDS, 0)
        self.assertEqual(self.sleep.call_count, ui.EFI_RETRY_SECONDS)
        self.assertEqual(find.call_count, ui.EFI_RETRY_SECONDS + 1)
        run_cmd.assert_not_called()

    def test_an_efi_partition_appearing_late_is_used(self):
        # Returns None twice, then the device: the retry must take it.
        results = [None, None, "/dev/sdb1"]

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition",
                                   side_effect=results):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))
        self.assertIn(
            "mount", [c.args[0][0] for c in run_cmd.call_args_list]
        )

    def test_a_failed_archive_removes_the_partial_file(self):
        # A truncated home.tar.gz on the new stick is worse than none: the
        # next boot's restore may accept it and replace a good home. The fake
        # tar writes a partial file and then fails, the way a real tar does
        # when the partition fills up, so the real os.unlink is exercised.
        # The check has to happen AT unmount time, not after the call
        # returns: copy_home_to_drive removes its temporary mount point on
        # the way out, so a check afterwards finds the file gone whether the
        # code unlinked it or not, and passes vacuously. (It uses os.rmdir,
        # deliberately: rmtree of a still-mounted directory would wipe the
        # new stick. See test_a_failed_umount_leaves_the_mount_dir_intact.)
        calls = []
        dest_seen = []
        existed_at_umount = []

        def fake_run_cmd(cmd, **kwargs):
            calls.append(cmd[0])
            if cmd[0] == "tar":
                dest = cmd[cmd.index("-czf") + 1]
                dest_seen.append(dest)
                Path(dest).write_text("truncated archive")
                raise subprocess.CalledProcessError(2, cmd)
            if cmd[0] == "umount" and dest_seen:
                existed_at_umount.append(os.path.exists(dest_seen[0]))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))

        self.assertTrue(dest_seen, "tar was never called")
        self.assertIn("umount", calls, "a failed archive must still unmount")
        self.assertEqual(
            existed_at_umount, [False],
            "the truncated archive was still on the drive when it was unmounted",
        )

    def test_tar_exit_1_keeps_the_archive(self):
        # GNU tar exits 1 for "file changed as we read it" - a socket or a
        # file being written - while producing a usable archive. Exit 2 is a
        # real error. Treating 1 as failure throws away a good copy.
        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "tar":
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))

    def test_a_failed_umount_is_a_failed_copy(self):
        # The archive is still in the page cache. Reporting success here means
        # the user pulls the stick out with an empty file on it.
        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "umount":
                raise subprocess.CalledProcessError(32, cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))

    def test_a_home_that_is_not_a_directory_is_refused(self):
        missing = str(Path(self.work.name) / "no-such-home")
        with mock.patch.object(
            ui.pwd, "getpwnam", return_value=mock.Mock(pw_dir=missing)
        ):
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()

    def test_the_happy_path_mounts_archives_syncs_and_unmounts_in_order(self):
        calls = []

        def fake_run_cmd(cmd, **kwargs):
            calls.append(cmd[0])
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))
        self.assertEqual(
            [c for c in calls if c in ("mount", "tar", "sync", "umount")],
            ["mount", "tar", "sync", "umount"],
        )

    def test_a_corrupt_archive_is_discarded_and_reported(self):
        # tar can exit 0 on a stick that is failing; gzip -t is the check.
        existed_at_umount = []
        dest_seen = []

        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "tar":
                dest = cmd[cmd.index("-czf") + 1]
                dest_seen.append(dest)
                Path(dest).write_text("not gzip")
            if cmd[0] == "gzip":
                raise subprocess.CalledProcessError(1, cmd)
            if cmd[0] == "umount":
                existed_at_umount.append(os.path.exists(dest_seen[0]))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(out):
                        self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        self.assertEqual(existed_at_umount, [False])
        self.assertIn("WARNING", out.getvalue())

    def test_the_archive_is_verified_before_success(self):
        calls = []

        def fake_run_cmd(cmd, **kwargs):
            calls.append(cmd[0])
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))
        self.assertLess(calls.index("tar"), calls.index("gzip"))
        self.assertLess(calls.index("gzip"), calls.index("umount"))

    def test_a_failed_mount_is_a_failed_copy_without_an_umount(self):
        calls = []

        def fake_run_cmd(cmd, **kwargs):
            calls.append(cmd[0])
            if cmd[0] == "mount":
                raise subprocess.CalledProcessError(32, cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(out):
                        self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        self.assertNotIn("umount", calls)
        self.assertNotIn("tar", calls)
        self.assertIn("could not copy", out.getvalue())
        self.assertNotIn("unmount", out.getvalue())


    def _partial_then_raise(self, exc):
        existed_at_umount = []
        dest_seen = []

        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "tar":
                dest = cmd[cmd.index("-czf") + 1]
                dest_seen.append(dest)
                Path(dest).write_text("partial")
                raise exc
            if cmd[0] == "umount":
                existed_at_umount.append(os.path.exists(dest_seen[0]))
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(out):
                        result = ui.copy_home_to_drive("/dev/sdb")
        self.assertFalse(result)
        self.assertEqual(existed_at_umount, [False],
                         "partial archive still on the drive at unmount")
        self.assertIn("WARNING", out.getvalue())

    def test_ctrl_c_during_tar_removes_the_partial_and_does_not_raise(self):
        self._partial_then_raise(KeyboardInterrupt())

    def test_an_oserror_after_a_partial_write_removes_the_partial(self):
        self._partial_then_raise(OSError(28, "No space left on device"))

    # ---- failed umount must never delete what is under the mount point ----

    def test_a_failed_umount_leaves_the_mount_dir_intact(self):
        # If umount fails, the temporary directory still IS the new stick. A
        # recursive delete there wipes the stick's firmware. The fake mount
        # drops a sentinel into the directory the way a real mount would show
        # the stick's files; it must survive a failed umount.
        sentinel = []

        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "mount":
                p = Path(cmd[2]) / "stick-file"
                p.write_text("firmware")
                sentinel.append(p)
            if cmd[0] == "umount":
                raise subprocess.CalledProcessError(32, cmd)
            return subprocess.CompletedProcess(cmd, 0, b"", b"")

        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(out):
                        result = ui.copy_home_to_drive("/dev/sdb")
        self.assertTrue(sentinel, "mount was never called")
        self.addCleanup(shutil.rmtree, sentinel[0].parent, True)
        self.assertFalse(result)
        self.assertTrue(
            sentinel[0].exists(),
            "a failed umount must not delete files under the mount directory",
        )
        self.assertIn("could not unmount", out.getvalue())

    # ---- this boot's restore state ----

    def _state(self, content):
        state = Path(self.work.name) / "state"
        state.mkdir(exist_ok=True)
        if content is not None:
            (state / "home-restore").write_text(content)
        return mock.patch.object(ui, "STATE_DIR", str(state))

    def test_a_failed_restore_refuses_the_copy_with_a_named_reason(self):
        out = io.StringIO()
        with self._as_tluser(), self._state("failed\n"):
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    with contextlib.redirect_stdout(out):
                        self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()
        self.assertIn("this boot's home restore failed", out.getvalue())
        self.assertIn("default one", out.getvalue())

    def test_a_missing_or_other_restore_state_proceeds(self):
        for content in (None, "ok\n", "absent\n"):
            with self.subTest(content=content):
                with self._as_tluser(), self._state(content):
                    with mock.patch.object(ui, "find_efi_partition",
                                           return_value="/dev/sdb1"):
                        with mock.patch.object(ui, "run_cmd"):
                            self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))

    def test_an_unreadable_state_file_proceeds(self):
        with self._as_tluser(), self._state("failed\n"):
            with mock.patch("builtins.open", side_effect=PermissionError("no")):
                self.assertFalse(ui.home_restore_failed())

    # ---- tar's own error is shown ----

    def test_a_tar_failure_shows_tars_stderr_not_the_command_line(self):
        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "tar":
                raise subprocess.CalledProcessError(
                    2, cmd, stderr="tar: ./x: Wrote only 0 of 10: No space left on device\n"
                )
            return subprocess.CompletedProcess(cmd, 0, "", "")

        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(out):
                        self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        self.assertIn("No space left on device", out.getvalue())
        self.assertNotIn("--exclude", out.getvalue())

    def test_tar_exit_1_note_includes_stderr(self):
        def fake_run_cmd(cmd, **kwargs):
            if cmd[0] == "tar":
                raise subprocess.CalledProcessError(
                    1, cmd, stderr="tar: ./sock: socket ignored\n"
                )
            return subprocess.CompletedProcess(cmd, 0, "", "")

        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui, "run_cmd", side_effect=fake_run_cmd):
                    with contextlib.redirect_stdout(out):
                        self.assertTrue(ui.copy_home_to_drive("/dev/sdb"))
        self.assertIn("socket ignored", out.getvalue())

    # ---- "never raises" ----

    def test_a_mkdtemp_failure_is_reported_not_raised(self):
        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value="/dev/sdb1"):
                with mock.patch.object(ui.tempfile, "mkdtemp",
                                       side_effect=OSError(28, "No space left")):
                    with mock.patch.object(ui, "run_cmd") as run_cmd:
                        with contextlib.redirect_stdout(out):
                            self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()
        self.assertIn("WARNING", out.getvalue())
        self.assertIn("temporary mount point", out.getvalue())

    def test_ctrl_c_during_the_efi_retry_wait_is_reported_not_raised(self):
        self.sleep.side_effect = KeyboardInterrupt()
        out = io.StringIO()
        with self._as_tluser():
            with mock.patch.object(ui, "find_efi_partition", return_value=None):
                with mock.patch.object(ui, "run_cmd") as run_cmd:
                    with contextlib.redirect_stdout(out):
                        self.assertFalse(ui.copy_home_to_drive("/dev/sdb"))
        run_cmd.assert_not_called()
        self.assertIn("WARNING: home copy interrupted", out.getvalue())


def _drive(is_boot=False):
    return ui.DriveInfo(
        device="/dev/sdb", size="16G", model="Stick", label="", is_dbrrg=False,
        efi_partition=None, part_size_mb=0, is_boot=is_boot,
        has_tl_old=False, has_tl_new=False,
    )


class TestHomeCopyQuestion(unittest.TestCase):
    """The question is asked on a fresh install only, after the write."""

    def _fresh_install(self, answers):
        """Run do_fresh_install with scripted input() answers."""
        events = []
        prompts = []

        def fake_input(prompt=""):
            prompts.append(prompt)
            a = answers.pop(0)
            if isinstance(a, BaseException):
                raise a
            return a

        with mock.patch("builtins.input", side_effect=fake_input), \
             mock.patch.object(ui, "download_and_write_image",
                               side_effect=lambda *a: events.append("write")), \
             mock.patch.object(ui, "run_cmd"), \
             mock.patch.object(
                 ui, "copy_home_to_drive",
                 side_effect=lambda d: events.append("copy") or True) as copy, \
             contextlib.redirect_stdout(io.StringIO()):
            result = ui.do_fresh_install(_drive(), "http://x")
        return result, copy, events, prompts

    def test_yes_copies_after_the_image_is_written(self):
        result, copy, events, prompts = self._fresh_install(["y", "y"])
        self.assertEqual(events, ["write", "copy"])
        copy.assert_called_once_with("/dev/sdb")
        self.assertTrue(result)
        self.assertIn("Copy this machine's home", prompts[1])

    def test_no_skips_the_copy(self):
        result, copy, events, prompts = self._fresh_install(["y", "n"])
        copy.assert_not_called()
        self.assertEqual(events, ["write"])
        self.assertIsNone(result)
        self.assertEqual(len(prompts), 2, "the question was never asked")

    def test_eof_skips_the_copy(self):
        result, copy, events, prompts = self._fresh_install(["y", EOFError()])
        copy.assert_not_called()
        self.assertIsNone(result)

    def test_a_failed_copy_is_returned_not_hidden(self):
        with mock.patch("builtins.input", side_effect=["y", "y"]), \
             mock.patch.object(ui, "download_and_write_image"), \
             mock.patch.object(ui, "run_cmd"), \
             mock.patch.object(ui, "copy_home_to_drive", return_value=False), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertIs(ui.do_fresh_install(_drive(), "http://x"), False)

    def test_the_ab_upgrade_never_asks(self):
        with tempfile.TemporaryDirectory() as tmp:
            fw = os.path.join(tmp, "firmware")
            with mock.patch("builtins.input",
                            side_effect=AssertionError("asked a question")), \
                 mock.patch.object(ui.os.path, "ismount", return_value=True), \
                 mock.patch.object(ui, "download_firmware", return_value=fw), \
                 mock.patch.object(ui, "run_cmd"), \
                 mock.patch.object(ui, "copy_home_to_drive") as copy, \
                 contextlib.redirect_stdout(io.StringIO()):
                ui.do_ab_upgrade(_drive(is_boot=True), "http://x")
        copy.assert_not_called()


class TestClosingSummary(unittest.TestCase):
    """The Success screen must say what did not happen."""

    def _main(self, operation, home_copied, save_rc):
        out = io.StringIO()
        with mock.patch.object(ui, "ensure_root"), \
             mock.patch.object(ui, "select_source", return_value="http://x"), \
             mock.patch.object(ui, "enumerate_drives", return_value=[_drive()]), \
             mock.patch.object(ui, "show_drives_with_operations",
                               return_value=(_drive(), operation)), \
             mock.patch.object(ui, "confirm", return_value=True), \
             mock.patch.object(ui, "do_fresh_install", return_value=home_copied), \
             mock.patch.object(ui, "do_ab_upgrade"), \
             mock.patch.object(ui, "save_home_before_finish", return_value=save_rc), \
             contextlib.redirect_stdout(out):
            rc = ui.main()
        self.assertEqual(rc, 0, "the install itself still counts as succeeded")
        return out.getvalue()

    def test_copied_and_saved(self):
        text = self._main("fresh", True, 0)
        self.assertIn("Home directory copied to the new drive.", text)
        self.assertIn("Home directory saved.", text)
        self.assertNotIn("NOT", text)

    def test_a_failed_copy_is_named_on_the_success_screen(self):
        text = self._main("fresh", False, 0)
        self.assertIn("Home directory NOT copied", text)
        self.assertIn("Operation completed successfully!", text)

    def test_a_failed_save_is_named_on_the_success_screen(self):
        text = self._main("fresh", None, 3)
        self.assertIn("Home directory NOT saved - see the warning above.", text)
        self.assertNotIn("Home directory saved.", text)

    def test_no_copy_line_when_the_copy_was_not_asked_for(self):
        text = self._main("upgrade", None, 0)
        self.assertNotIn("copied", text)
        self.assertIn("Home directory saved.", text)


class TestSavingAnnounced(unittest.TestCase):
    def test_a_line_is_printed_before_the_save_runs(self):
        order = []
        with mock.patch.object(ui, "log", side_effect=lambda m: order.append("log")), \
             mock.patch.object(
                 ui.subprocess, "run",
                 side_effect=lambda *a, **k: order.append("run")
                 or subprocess.CompletedProcess([], 0, b"", b"")):
            ui.save_home_before_finish()
        self.assertEqual(order[:2], ["log", "run"])


class TestCleanupNeverWipesAMount(unittest.TestCase):
    """_do_cleanup must not rmtree a directory that is still a mount point."""

    def setUp(self):
        self._saved = list(ui._cleanup_items)
        ui._cleanup_items[:] = []
        self.tmp = tempfile.mkdtemp(prefix="cleanup-test-",
                                    dir=os.environ.get("TMPDIR"))
        self.sentinel = os.path.join(self.tmp, "home.tar.gz")
        with open(self.sentinel, "w") as f:
            f.write("saved home")

    def tearDown(self):
        ui._cleanup_items[:] = self._saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _cleanup(self, umount_rc, still_mounted):
        ui._register_cleanup("dir", self.tmp)
        ui._register_cleanup("mount", self.tmp)
        out, err = io.StringIO(), io.StringIO()
        fake = subprocess.CompletedProcess([], umount_rc, "", "busy")
        with mock.patch.object(ui, "run_cmd", return_value=fake), \
             mock.patch.object(ui.os.path, "ismount",
                               return_value=still_mounted), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            ui._do_cleanup()
        return out.getvalue() + err.getvalue()

    def test_a_directory_whose_umount_failed_is_left_alone(self):
        text = self._cleanup(1, True)
        self.assertTrue(os.path.exists(self.sentinel))
        self.assertIn("WARNING", text)
        self.assertIn(self.tmp, text)

    def test_a_cleanly_unmounted_directory_is_removed(self):
        text = self._cleanup(0, False)
        self.assertFalse(os.path.exists(self.tmp))
        self.assertEqual(text, "")


if __name__ == "__main__":
    unittest.main()
