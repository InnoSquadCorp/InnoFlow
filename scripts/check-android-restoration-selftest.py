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
        probe = restoration.RestorationProbe(["fake-adb"], Path(self.temp.name))
        probe.sdk = "35"
        with patch.object(restoration.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 127, stdout=b"", stderr=b"pidof: inaccessible")):
            with self.assertRaisesRegex(RuntimeError, "pidof failed"):
                probe.read_pid()

    def test_zero_exit_status_is_not_process_death(self):
        self.probe.survives = True
        with self.assertRaisesRegex(RuntimeError, "process did not terminate"):
            self.probe.terminate_saved_process("1234")

    def test_malformed_pid_refuses_all_commands(self):
        with self.assertRaisesRegex(RuntimeError, "invalid sample PID"):
            self.probe.terminate_saved_process("-1")
        self.assertEqual(self.probe.calls, [])

    def test_tty_hierarchy_uses_exact_xml_without_fallback(self):
        xml = '<?xml version="1.0"?><hierarchy><node text="Count: 2"/></hierarchy>'
        with patch.object(self.probe, "command", return_value=xml + "UI hierarchy dumped to: /dev/tty") as command:
            self.assertEqual(self.probe.hierarchy().find("node").get("text"), "Count: 2")
            command.assert_called_once_with("exec-out", "uiautomator", "dump", "/dev/tty")

    def test_legacy_tty_fallback_reads_only_a_fresh_file_and_cleans_it(self):
        xml = '<?xml version="1.0"?><hierarchy><node text="Count: 2"/></hierarchy>'
        path = self.probe.ui_dump_path
        with patch.object(self.probe, "command", side_effect=["no tty XML", "",
                f"UI hierchary dumped to: {path}", xml, ""]) as command:
            self.assertEqual(self.probe.hierarchy().find("node").get("text"), "Count: 2")
            self.assertEqual([call.args for call in command.call_args_list], [
                ("exec-out", "uiautomator", "dump", "/dev/tty"),
                ("shell", "rm", "-f", path), ("shell", "uiautomator", "dump", path),
                ("exec-out", "cat", path), ("shell", "rm", "-f", path)])

    def test_failed_dump_never_reads_a_stale_hierarchy(self):
        path = self.probe.ui_dump_path
        with patch.object(self.probe, "command", side_effect=["", "", "ERROR: could not get idle state.", ""]) as command:
            with self.assertRaisesRegex(RuntimeError, "UI hierarchy file dump failed"):
                self.probe.hierarchy()
            self.assertFalse(any("cat" in call.args for call in command.call_args_list))
            self.assertEqual(command.call_args.args, ("shell", "rm", "-f", path))

    def test_missing_or_invalid_file_hierarchy_is_not_success(self):
        path = self.probe.ui_dump_path
        for result in ("not XML", subprocess.CalledProcessError(1, ["cat", path])):
            with self.subTest(result=result), patch.object(self.probe, "command", side_effect=["", "",
                    f"UI hierarchy dumped to: {path}", result, ""]) as command:
                with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    self.probe.hierarchy()
                self.assertEqual(command.call_args.args, ("shell", "rm", "-f", path))


class LegacyPidTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="innoflow-legacy-pid-selftest-")
        self.addCleanup(self.temp.cleanup)
        self.probe = restoration.RestorationProbe(["fake-adb"], Path(self.temp.name))
        self.probe.sdk = "23"
        self.header = "USER PID PPID VSIZE RSS WCHAN PC NAME\n"

    def ps(self, name=PACKAGE, pid="1234"):
        return f"u0_a64 {pid} 317 123456 1234 ffffffff 00000000 S {name}\n"

    def test_sdk_lookup_is_cached_and_selects_the_legacy_path(self):
        self.probe.sdk = None
        with patch.object(self.probe, "command", side_effect=[
                "23\r\n", self.header + self.ps(), PACKAGE + "\0", self.header + self.ps(), PACKAGE + "\0"]) as command:
            self.assertEqual(self.probe.read_pid(), "1234")
            self.assertEqual(self.probe.read_pid(), "1234")
            self.assertEqual(sum(call.args == ("shell", "getprop", "ro.build.version.sdk")
                                 for call in command.call_args_list), 1)

    def test_invalid_sdk_is_not_process_death(self):
        for sdk in ("", "23 35", "denied"):
            self.probe.sdk = None
            with self.subTest(sdk=sdk), patch.object(self.probe, "command", return_value=sdk):
                with self.assertRaisesRegex(RuntimeError, "Invalid device SDK"):
                    self.probe.read_pid()

    def test_api23_all_pidof_output_is_not_used_as_a_pid(self):
        # The hosted API23 pidof returned every process, including PID 1.
        all_pids = subprocess.CompletedProcess([], 0, stdout=b"1 2 317 1234\n", stderr=b"")
        with patch.object(restoration.subprocess, "run", return_value=all_pids) as pidof:
            with patch.object(self.probe, "command", side_effect=[
                    self.header + self.ps("other.app", "2") + self.ps(), PACKAGE + "\0"]) as command:
                self.assertEqual(self.probe.read_pid(), "1234")
                self.assertEqual(command.call_args.args,
                                 ("shell", "run-as", PACKAGE, "cat", "/proc/1234/cmdline"))
            pidof.assert_not_called()

    def test_absent_exact_sample_is_process_death(self):
        with patch.object(self.probe, "command", return_value=self.header + self.ps("other.app")) as command:
            self.assertIsNone(self.probe.read_pid())
            command.assert_called_once_with("shell", "ps")

    def test_prefix_and_worker_names_are_not_the_sample(self):
        for name in (PACKAGE + ".other", PACKAGE + ":worker", PACKAGE[:15]):
            with self.subTest(name=name), patch.object(self.probe, "command", return_value=self.header + self.ps(name)):
                self.assertIsNone(self.probe.read_pid())

    def test_multiple_exact_processes_are_rejected(self):
        with patch.object(self.probe, "command", return_value=self.header + self.ps() + self.ps(pid="5678")):
            with self.assertRaisesRegex(RuntimeError, "multiple exact sample"):
                self.probe.read_pid()

    def test_invalid_pid_is_rejected_before_proc_read(self):
        for pid in ("0", "-1", "123;kill"):
            with self.subTest(pid=pid), patch.object(self.probe, "command", return_value=self.header + self.ps(pid=pid)) as command:
                with self.assertRaisesRegex(RuntimeError, "invalid sample PID"):
                    self.probe.read_pid()
                command.assert_called_once_with("shell", "ps")

    def test_exact_ps_name_still_requires_exact_cmdline(self):
        for cmdline in ("other.app\0", PACKAGE + ":worker\0", PACKAGE + "\0extra\0"):
            with self.subTest(cmdline=cmdline), patch.object(self.probe, "command", side_effect=[self.header + self.ps(), cmdline]):
                with self.assertRaisesRegex(RuntimeError, "unexpected cmdline"):
                    self.probe.read_pid()

    def test_unrecognized_ps_format_is_not_process_death(self):
        for text in ("", "ps: permission denied", "USER PID NAME EXTRA\n", "USER NAME\n"):
            with self.subTest(text=text), patch.object(self.probe, "command", return_value=text):
                with self.assertRaisesRegex(RuntimeError, "Unrecognized legacy ps"):
                    self.probe.read_pid()

    def test_malformed_exact_sample_row_is_not_accepted(self):
        for row in ("u0_a64 1234 " + PACKAGE, self.ps().replace(" S ", " unexpected-state ")):
            with self.subTest(row=row), patch.object(self.probe, "command", return_value=self.header + row):
                with self.assertRaisesRegex(RuntimeError, "Unrecognized legacy ps sample row"):
                    self.probe.read_pid()

    def test_proc_read_failure_is_not_process_death(self):
        with patch.object(self.probe, "command", side_effect=[self.header + self.ps(),
                subprocess.CalledProcessError(1, ["cat"], output=b"permission denied")]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.probe.read_pid()

    def test_modern_multiple_pidof_output_remains_rejected(self):
        self.probe.sdk = "35"
        with patch.object(restoration.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout=b"1234 5678\n", stderr=b"")):
            with self.assertRaisesRegex(RuntimeError, "invalid sample PID"):
                self.probe.read_pid()


if __name__ == "__main__":
    unittest.main(verbosity=2)
