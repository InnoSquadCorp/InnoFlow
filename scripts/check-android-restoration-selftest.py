#!/usr/bin/env python3
"""Device-free positive/negative controls for the process-death probe's kill guards."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("restoration", Path(__file__).with_name("check-android-restoration.py"))
restoration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restoration)
PACKAGE = restoration.PACKAGE


def activity(package=PACKAGE, state="STOPPED", stopped="true", saved="true", modern=False):
    state_key = "state"
    stopped_key = "mAppStopped" if modern else "stopped"
    saved_key = "mHaveState" if modern else "haveState"
    return (f"  * Hist #0: ActivityRecord{{abc u0 {package}/.MainActivity t1}}\n"
            f"    {state_key}={state} {stopped_key}={stopped}\n    {saved_key}={saved} icicle=Bundle[...]\n")


class FakeProbe(restoration.RestorationProbe):
    def __init__(self, evidence):
        super().__init__(["fake-adb"], evidence)
        self.pid = "1234"
        self.native = False
        self.survives = False
        self.cmdline = PACKAGE + "\0"
        self.activities = activity()
        self.calls = []
        self.time = 0

    def read_pid(self):
        return self.pid

    def sleep(self, seconds):
        self.time += seconds

    def command(self, *args):
        self.calls.append(args)
        if args == ("shell", "dumpsys", "activity", "activities"):
            return self.activities
        if args == ("shell", "am", "kill", PACKAGE):
            if self.native:
                self.pid = None
            return ""
        if args == ("shell", "run-as", PACKAGE, "cat", "/proc/1234/cmdline"):
            return self.cmdline
        if args == ("shell", "run-as", PACKAGE, "kill", "-9", "1234"):
            if not self.survives:
                self.pid = None
            return ""
        raise AssertionError(f"Unexpected command: {args}")


class RestorationSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="innoflow-restoration-selftest-")
        self.addCleanup(self.temp.cleanup)
        self.probe = FakeProbe(Path(self.temp.name))
        self.clock = patch.object(restoration.time, "monotonic", lambda: self.probe.time)
        self.sleep = patch.object(restoration.time, "sleep", lambda seconds: self.probe.sleep(seconds))
        self.clock.start()
        self.sleep.start()
        self.addCleanup(self.clock.stop)
        self.addCleanup(self.sleep.stop)

    def assert_no_pid_kill(self):
        self.assertFalse(any("run-as" in call and "kill" in call for call in self.probe.calls))

    def test_api26_and_modern_stopped_saved_records(self):
        self.assertTrue(restoration.saved_and_stopped(activity()))
        self.assertTrue(restoration.saved_and_stopped(activity(modern=True)))
        self.assertTrue(restoration.saved_and_stopped(activity() + activity(package="other.app")))

    def test_api34_hist_header_padding_and_record_isolation(self):
        saved = activity(modern=True).replace("Hist #", "Hist  #")
        unsaved = activity(saved="false", modern=True).replace("Hist #", "Hist  #")
        foreign = activity(package="other.app", modern=True).replace("Hist #", "Hist  #")
        self.assertTrue(restoration.saved_and_stopped(saved))
        self.assertFalse(restoration.saved_and_stopped(unsaved + foreign))

    def test_missing_foreground_unsaved_and_foreign_records_rejected(self):
        for dump in ("", activity(state="RESUMED"), activity(stopped="false"),
                     activity(saved="false"), activity(package=PACKAGE + ".other"),
                     activity(saved="false") + activity(package="other.app"),
                     activity() + activity(state="RESUMED")):
            with self.subTest(dump=dump):
                self.assertFalse(restoration.saved_and_stopped(dump))

    def test_pid_is_one_positive_decimal_number(self):
        self.assertEqual(restoration.checked_pid("1234"), "1234")
        for value in ("", "0", "-1", "123 456", "123\n456", "123;kill", " 123", "1.5"):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                restoration.checked_pid(value)

    def test_native_kill_needs_no_run_as(self):
        self.probe.native = True
        self.assertEqual(self.probe.terminate_saved_process("1234"), "am-kill")
        self.assertFalse(any("run-as" in call for call in self.probe.calls))

    def test_api26_fallback_uses_only_verified_same_uid_pid(self):
        self.assertEqual(self.probe.terminate_saved_process("1234"), "same-uid-pid-kill")
        self.assertIn(("shell", "run-as", PACKAGE, "cat", "/proc/1234/cmdline"), self.probe.calls)
        self.assertIn(("shell", "run-as", PACKAGE, "kill", "-9", "1234"), self.probe.calls)
        self.assertFalse(any("force-stop" in call for call in self.probe.calls))

    def test_unsaved_state_refuses_even_native_kill(self):
        self.probe.activities = activity(saved="false")
        with self.assertRaisesRegex(RuntimeError, "not STOPPED with saved state"):
            self.probe.terminate_saved_process("1234")
        self.assertFalse(any("kill" in call for call in self.probe.calls))

    def test_changed_pid_before_kill_is_rejected(self):
        self.probe.pid = "5678"
        with self.assertRaisesRegex(RuntimeError, "PID changed before"):
            self.probe.terminate_saved_process("1234")
        self.assertFalse(any("kill" in call for call in self.probe.calls))

    def test_replacement_pid_after_native_kill_is_never_killed(self):
        original = self.probe.command
        def command(*args):
            result = original(*args)
            if args == ("shell", "am", "kill", PACKAGE):
                self.probe.pid = "5678"
            return result
        self.probe.command = command
        with self.assertRaisesRegex(RuntimeError, "refusing replacement PID"):
            self.probe.terminate_saved_process("1234")
        self.assert_no_pid_kill()

    def test_foreign_or_multi_argument_cmdline_is_rejected(self):
        for cmdline in ("other.app\0", PACKAGE + ":worker\0", PACKAGE + "\0extra\0"):
            self.probe.cmdline = cmdline
            with self.subTest(cmdline=cmdline), self.assertRaisesRegex(RuntimeError, "unexpected cmdline"):
                self.probe.terminate_saved_process("1234")
            self.assert_no_pid_kill()

    def test_run_as_denial_is_not_bypassed(self):
        original = self.probe.command
        def command(*args):
            if "run-as" in args:
                raise subprocess.CalledProcessError(1, args, output=b"not debuggable")
            return original(*args)
        self.probe.command = command
        with self.assertRaises(subprocess.CalledProcessError):
            self.probe.terminate_saved_process("1234")
        self.assert_no_pid_kill()

    def test_pid_change_while_reading_cmdline_is_rejected(self):
        original = self.probe.command
        def command(*args):
            result = original(*args)
            if "cat" in args:
                self.probe.pid = "5678"
            return result
        self.probe.command = command
        with self.assertRaisesRegex(RuntimeError, "PID changed before"):
            self.probe.terminate_saved_process("1234")
        self.assert_no_pid_kill()

    def test_foreground_transition_before_fallback_is_rejected(self):
        original = self.probe.command
        def command(*args):
            result = original(*args)
            if args == ("shell", "am", "kill", PACKAGE):
                self.probe.activities = activity(state="RESUMED", stopped="false")
            return result
        self.probe.command = command
        with self.assertRaisesRegex(RuntimeError, "not STOPPED with saved state"):
            self.probe.terminate_saved_process("1234")
        self.assert_no_pid_kill()

    def test_pidof_error_is_not_treated_as_a_dead_process(self):
        with patch.object(restoration.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 127, stdout=b"", stderr=b"pidof: inaccessible")):
            with self.assertRaisesRegex(RuntimeError, "pidof failed"):
                restoration.RestorationProbe(["fake-adb"], Path(self.temp.name)).read_pid()

    def test_zero_exit_status_is_not_process_death(self):
        self.probe.survives = True
        with self.assertRaisesRegex(RuntimeError, "process did not terminate"):
            self.probe.terminate_saved_process("1234")

    def test_malformed_pid_refuses_all_commands(self):
        with self.assertRaisesRegex(RuntimeError, "invalid sample PID"):
            self.probe.terminate_saved_process("-1")
        self.assertEqual(self.probe.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
