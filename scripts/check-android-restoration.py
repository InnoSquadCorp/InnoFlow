#!/usr/bin/env python3
"""Verify explicit SavedStateHandle restoration after real, non-force-stop process death."""
import argparse
import json
from pathlib import Path
import os
import re
import subprocess
import tempfile
import time
import uuid
import xml.etree.ElementTree as XML

PACKAGE = "com.innosquad.innoflow.sample.android"


def checked_pid(value):
    # Never allow shell syntax, process groups, or multiple process IDs.
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise RuntimeError(f"Refusing invalid sample PID: {value!r}")
    return value


def saved_and_stopped(activities):
    """Inspect only this package's ActivityRecord, not another activity's flags."""
    records = re.split(r"(?m)(?=^[ \t]*\* Hist[ \t]+#\d+: ActivityRecord\{)", activities)
    target_records = []
    for record in records:
        header = record.split("\n", 1)[0]
        if re.search(r"\b" + re.escape(PACKAGE) + r"/", header):
            target_records.append(record)
    return bool(target_records) and all(
        re.search(r"\b(?:mState|state)=STOPPED\b", record)
        and re.search(r"\b(?:mAppStopped|mStopped|stopped)=true\b", record)
        and re.search(r"\b(?:mHaveState|haveState)=true\b", record)
        for record in target_records
    )


class RestorationProbe:
    def __init__(self, adb, evidence):
        self.adb = adb
        self.evidence = evidence
        self.sdk = None
        self.ui_dump_path = f"/data/local/tmp/innoflow-restoration-ui-{uuid.uuid4().hex}.xml"

    def command(self, *arguments):
        return subprocess.check_output(self.adb + list(arguments), timeout=30).decode()

    def read_pid(self):
        if self.sdk is None:
            self.sdk = self.command("shell", "getprop", "ro.build.version.sdk").strip()
            if not re.fullmatch(r"[1-9][0-9]*", self.sdk):
                raise RuntimeError(f"Invalid device SDK: {self.sdk!r}")
        if self.sdk == "23":
            return self.read_legacy_pid()
        result = subprocess.run(self.adb + ["shell", "pidof", PACKAGE],
                                capture_output=True, timeout=10, check=False)
        value = result.stdout.decode().strip()
        if result.returncode == 1 and not value:
            return None
        if result.returncode != 0:
            raise RuntimeError(f"pidof failed: {result.stderr.decode()}")
        return checked_pid(value)

    def read_legacy_pid(self):
        # The API23 image's pidof returns all PIDs instead of filtering by name.
        # Its toolbox ps exposes the full app NAME. Match that field exactly,
        # then independently verify /proc under the debug sample's own UID.
        raw = self.command("shell", "ps")
        (self.evidence / "legacy-ps.txt").write_text(raw, encoding="utf-8")
        lines = raw.splitlines()
        header = lines[0].split() if lines else []
        if "PID" not in header or not header or header[-1] != "NAME":
            raise RuntimeError("Unrecognized legacy ps format; refusing PID lookup")
        pids = []
        for line in lines[1:]:
            fields = line.split()
            if fields and fields[-1] == PACKAGE:
                # Android 6 toolbox prints an unlabelled state before NAME.
                extra_state = len(fields) == len(header) + 1 and re.fullmatch(r"[RSDZTtXxKWPI]", fields[-2])
                if len(fields) != len(header) and not extra_state:
                    raise RuntimeError("Unrecognized legacy ps sample row")
                pids.append(checked_pid(fields[header.index("PID")]))
        if len(pids) > 1:
            raise RuntimeError("Refusing multiple exact sample processes")
        if not pids:
            return None
        pid = pids[0]
        cmdline = self.command("shell", "run-as", PACKAGE, "cat", f"/proc/{pid}/cmdline")
        if cmdline.rstrip("\0") != PACKAGE:
            raise RuntimeError(f"Refusing unexpected cmdline: {cmdline!r}")
        with (self.evidence / "legacy-pids.jsonl").open("a", encoding="utf-8") as output:
            output.write(json.dumps(dict(pid=pid, cmdline=cmdline)) + "\n")
        return pid

    def require_same_pid(self, expected):
        if self.read_pid() != expected:
            raise RuntimeError("Sample PID changed before termination; refusing to kill")

    def wait_saved_state(self):
        deadline = time.monotonic() + 20
        while True:
            activities = self.command("shell", "dumpsys", "activity", "activities")
            (self.evidence / "stopped-activities.txt").write_text(activities, encoding="utf-8")
            if saved_and_stopped(activities):
                return
            if time.monotonic() >= deadline:
                raise RuntimeError("Sample activity not STOPPED with saved state; refusing kill")
            time.sleep(0.2)

    def await_exit(self, before, timeout):
        deadline = time.monotonic() + timeout
        while True:
            current = self.read_pid()
            if current is None:
                return True
            if current != before:
                raise RuntimeError("Sample PID changed during termination; refusing replacement PID")
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.2)

    def terminate_saved_process(self, before):
        checked_pid(before)
        self.wait_saved_state()
        self.require_same_pid(before)
        self.command("shell", "am", "kill", PACKAGE)
        if self.await_exit(before, 1):
            return "am-kill"
        # API26 may retain a saved STOPPED activity at a protected OOM priority.
        # Only the debuggable sample's own UID may kill its exact, unchanged PID.
        # A force-stop would discard the task's restoration semantics.
        self.wait_saved_state()
        self.require_same_pid(before)
        cmdline = self.command("shell", "run-as", PACKAGE, "cat", f"/proc/{before}/cmdline")
        if cmdline.rstrip("\0") != PACKAGE:
            raise RuntimeError(f"Refusing kill of unexpected cmdline: {cmdline!r}")
        self.require_same_pid(before)
        self.command("shell", "run-as", PACKAGE, "kill", "-9", before)
        if not self.await_exit(before, 10):
            raise RuntimeError("The verified sample process did not terminate")
        return "same-uid-pid-kill"

    def launch(self):
        result = self.command("shell", "am", "start", "-W", "-n", PACKAGE + "/.MainActivity")
        if re.search(r"^Error", result, re.M):
            raise RuntimeError(result)

    def hierarchy(self):
        raw = self.command("exec-out", "uiautomator", "dump", "/dev/tty")
        (self.evidence / "ui-tty-output.txt").write_text(raw, encoding="utf-8")
        match = re.search(r"(<\?xml.*</hierarchy>)", raw, re.S)
        if not match:
            # Older adb/uiautomator combinations may not expose XML via /dev/tty.
            # A unique owned file, removed before and after every dump, prevents
            # an unsuccessful command from returning a previous UI snapshot.
            self.command("shell", "rm", "-f", self.ui_dump_path)
            try:
                status = self.command("shell", "uiautomator", "dump", self.ui_dump_path)
                (self.evidence / "ui-file-status.txt").write_text(status, encoding="utf-8")
                if "ERROR:" in status or f"dumped to: {self.ui_dump_path}" not in status:
                    raise RuntimeError(f"UI hierarchy file dump failed: {status}")
                raw = self.command("exec-out", "cat", self.ui_dump_path)
                (self.evidence / "ui-file-output.txt").write_text(raw, encoding="utf-8")
                match = re.search(r"(<\?xml.*</hierarchy>)", raw, re.S)
            finally:
                self.command("shell", "rm", "-f", self.ui_dump_path)
        if not match:
            raise RuntimeError("UI hierarchy is unavailable")
        (self.evidence / "latest-ui.xml").write_text(match.group(1), encoding="utf-8")
        return XML.fromstring(match.group(1))

    def count(self, expected=None):
        deadline = time.monotonic() + 15
        while True:
            for node in self.hierarchy().iter("node"):
                label = node.get("text", "")
                if "isn't responding" in label:
                    raise RuntimeError(f"Android ANR dialog blocks the probe: {label}")
                match = re.fullmatch(r"Count: (-?\d+)", label)
                if match and (expected is None or int(match[1]) == expected):
                    return int(match[1])
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Expected visible Count: {expected}")
            time.sleep(0.2)

    def click(self, label):
        for node in self.hierarchy().iter("node"):
            if node.get("text") == label:
                bounds = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
                if len(bounds) == 4:
                    x1, y1, x2, y2 = bounds
                    self.command("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
                    return
        raise RuntimeError(f"Missing UI control: {label}")

    def screenshot(self, name):
        with (self.evidence / name).open("wb") as output:
            subprocess.run(self.adb + ["exec-out", "screencap", "-p"],
                           stdout=output, check=True, timeout=10)

    def run(self, apk):
        # Instrumentation uninstalls its tested APK; never rely on that fixture.
        if not apk.is_file():
            raise RuntimeError(f"Build the sample debug APK first: {apk}")
        self.command("install", "-r", str(apk))
        self.launch()
        initial = self.count()
        target = initial + 2
        for expected in range(initial + 1, target + 1):
            self.click("Increase")
            self.count(expected)
        before = self.read_pid()
        if before is None:
            raise RuntimeError("Sample process missing before restoration")
        self.command("shell", "input", "keyevent", "3")
        method = self.terminate_saved_process(before)
        self.launch()
        after = self.read_pid()
        if after is None or before == after:
            raise RuntimeError("Restoration must run in a new process")
        self.count(target)
        self.screenshot("restored.png")
        result = dict(before=before, after=after, initial=initial, restored=target, method=method)
        (self.evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"Android process {before} -> {after}, Count {target} restored ({method}); {self.evidence}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=Path, default=Path(__file__).resolve().parents[1] /
                        "kotlin/android-sample/build/outputs/apk/debug/android-sample-debug.apk")
    args = parser.parse_args()
    evidence = Path(tempfile.mkdtemp(prefix="innoflow-android-restoration-"))
    print(f"Android restoration evidence: {evidence}", flush=True)
    adb = [str(Path(os.environ["ANDROID_HOME"]) / "platform-tools/adb"), "-s", args.serial]
    probe = RestorationProbe(adb, evidence)
    try:
        probe.run(args.apk)
    except Exception:
        try:
            probe.screenshot("failed.png")
        except (OSError, subprocess.SubprocessError):
            pass
        raise


if __name__ == "__main__":
    main()
