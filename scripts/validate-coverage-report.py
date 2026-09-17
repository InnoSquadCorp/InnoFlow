#!/usr/bin/env python3
"""InnoRouter-style fail-closed LCOV validation and per-module visibility.

InnoFlow keeps all production modules in one report. The policy also requires
each executable module, so dropping a low-coverage module cannot improve a pass.
"""

import argparse
import json
import math
from pathlib import Path
import re
import sys


def nonnegative(value):
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(f"expected a non-negative integer, got {value!r}")
    return int(value)


def parse_report(text, root):
    records = {}
    source = None
    hits = {}
    summaries = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("TN:"):
            continue
        if line.startswith("SF:"):
            if source is not None:
                raise ValueError("missing end_of_record")
            path = Path(line[3:])
            if not path.is_absolute():
                path = root / path
            path = path.resolve()
            relative = path.relative_to(root / "Sources")
            if len(relative.parts) < 2 or path.suffix != ".swift" or not path.is_file():
                raise ValueError(f"not a production Swift source: {path}")
            source = str(relative)
            if source in records:
                raise ValueError(f"duplicate source: {source}")
            hits, summaries = {}, {}
        elif source is None:
            raise ValueError(f"line {number}: data outside a source record")
        elif line.startswith("DA:"):
            fields = line[3:].split(",")
            if len(fields) not in (2, 3):
                raise ValueError("DA requires line and hit count")
            lineno, count = map(nonnegative, fields[:2])
            if lineno == 0 or lineno in hits:
                raise ValueError("zero or duplicate DA line")
            hits[lineno] = count
        elif line.startswith(("LF:", "LH:")):
            key = line[:2]
            if key in summaries:
                raise ValueError(f"duplicate {key}")
            summaries[key] = nonnegative(line[3:])
        elif line == "end_of_record":
            if set(summaries) != {"LF", "LH"}:
                raise ValueError("missing LF or LH")
            found, hit = summaries["LF"], summaries["LH"]
            listed_hit = sum(value > 0 for value in hits.values())
            # LLVM may include macro-generated line regions in LF/LH without
            # corresponding DA rows. Preserve that upstream contract, but never
            # accept impossible counts or a positive summary with no DA rows.
            unlisted_found, unlisted_hit = found - len(hits), hit - listed_hit
            if (hit > found or unlisted_found < 0 or unlisted_hit < 0
                    or unlisted_hit > unlisted_found or (found > 0 and not hits)):
                raise ValueError(f"inconsistent line summary: {source}")
            records[source] = {"foundLines": found, "hitLines": hit}
            source = None
        elif not line.startswith(("FN:", "FNDA:", "FNF:", "FNH:", "BRDA:", "BRF:", "BRH:")):
            raise ValueError(f"unknown LCOV field on line {number}")
    if source is not None:
        raise ValueError("missing end_of_record")
    if not records or sum(record["foundLines"] for record in records.values()) == 0:
        raise ValueError("report contains no instrumented production lines")
    return records


def summarize(records):
    def aggregate(items):
        values = list(items)
        found = sum(value["foundLines"] for value in values)
        hit = sum(value["hitLines"] for value in values)
        return {"files": len(values), "foundLines": found, "hitLines": hit,
                "lineCoveragePercent": hit / found * 100 if found else 0.0}

    modules = sorted({Path(source).parts[0] for source in records})
    return {
        "schemaVersion": 1,
        "totals": aggregate(records.values()),
        "modules": {module: aggregate(value for source, value in records.items()
                                      if Path(source).parts[0] == module) for module in modules},
    }


def check_policy(report, policy):
    if set(policy) != {"schemaVersion", "minimumLineCoverage", "requiredModules"} or policy["schemaVersion"] != 1:
        raise ValueError("invalid coverage policy schema")
    minimum = policy["minimumLineCoverage"]
    if isinstance(minimum, bool) or not isinstance(minimum, (float, int)) or not math.isfinite(minimum) or not 0 < minimum <= 100:
        raise ValueError("coverage floor must be finite and greater than 0, at most 100")
    required = policy["requiredModules"]
    if not isinstance(required, list) or not required or any(not isinstance(value, str) or not value for value in required):
        raise ValueError("requiredModules must be a nonempty list of module names")
    if len(set(required)) != len(required):
        raise ValueError("duplicate required module")
    missing = [module for module in required
               if report["modules"].get(module, {}).get("foundLines", 0) == 0]
    if missing:
        raise ValueError(f"missing instrumented modules: {', '.join(missing)}")
    if report["totals"]["lineCoveragePercent"] + 1e-9 < minimum:
        raise ValueError(f"coverage below required {minimum}% floor")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = summarize(parse_report(args.report.read_text(), args.root.resolve()))
        # Keep valid numerical evidence even when the policy floor fails.
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        for name, values in [("TOTAL", report["totals"]), *report["modules"].items()]:
            print(f"[coverage] {name}: {values['lineCoveragePercent']:.2f}% "
                  f"({values['hitLines']}/{values['foundLines']})")
        check_policy(report, json.loads(args.policy.read_text()))
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"[coverage] Failed: {error}", file=sys.stderr)
        return 1
    print("[coverage] Report structure, module inventory and coverage floor passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
