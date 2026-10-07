"""Consumer-helper timeout evidence and real process-tree cleanup regressions."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("flow_consumer", ROOT / "skills/innoflow/scripts/validate_consumer.py")
CONSUMER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONSUMER)


class ConsumerTimeoutTests(unittest.TestCase):
    def test_success_and_failure_preserve_exit_status(self):
        with tempfile.TemporaryFile(mode="w+") as output:
            self.assertEqual(CONSUMER.run_bounded_command([sys.executable, "-c", "print('ok')"], output, 5), (0, False))
            output.seek(0)
            self.assertIn("ok", output.read())
            self.assertEqual(CONSUMER.run_bounded_command([sys.executable, "-c", "raise SystemExit(7)"], output, 5), (7, False))

    @unittest.skipUnless(os.name == "posix", "Apple/Linux process-group contract")
    def test_timeout_kills_leader_and_child(self):
        script = "import subprocess,sys,os,json,time; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print(json.dumps([os.getpid(),child.pid]),flush=True); time.sleep(60)"
        with tempfile.TemporaryFile(mode="w+") as output:
            result = CONSUMER.run_bounded_command([sys.executable, "-c", script], output, 2)
            output.seek(0)
            leader, child = json.loads(output.readline())
        try:
            self.assertEqual(result, (-signal.SIGKILL, True))
            with self.assertRaises(ChildProcessError):
                os.waitpid(leader, os.WNOHANG)  # Direct child was already reaped.
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(child)], capture_output=True, text=True, timeout=5)
            self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith("Z"), state.stdout)
        finally:
            try:
                os.killpg(leader, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_timeout_is_failed_evidence_with_diagnostics(self):
        with tempfile.TemporaryDirectory() as scratch, \
             mock.patch.object(sys, "platform", "darwin"), \
             mock.patch.object(sys, "argv", ["validate_consumer.py", "--scratch-path", scratch, "--command-timeout", "17"]), \
             mock.patch.object(CONSUMER, "run_bounded_command", return_value=(-9, True)) as run:
            self.assertEqual(CONSUMER.main(), 1)
            evidence_path, = Path(scratch).glob("skill-runs/run-*/evidence.json")
            evidence = json.loads(evidence_path.read_text())
            self.assertEqual(evidence["status"], "failed")
            self.assertIn("timed out after 17s", evidence["error"])
            command, = evidence["commands"]
            self.assertEqual(command["timeout_seconds"], 17)
            self.assertEqual(command["exit_code"], -9)
            self.assertTrue(command["timed_out"])
            self.assertIn("process group killed", Path(command["log"]).read_text())
            self.assertEqual(run.call_args.args[2], 17)

    def test_nonpositive_timeout_is_rejected(self):
        for value in ("0", "-1"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                CONSUMER.positive_timeout(value)


if __name__ == "__main__":
    unittest.main()
