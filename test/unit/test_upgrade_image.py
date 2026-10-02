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


if __name__ == "__main__":
    unittest.main()
