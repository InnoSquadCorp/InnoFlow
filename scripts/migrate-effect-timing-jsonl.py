#!/usr/bin/env python3
"""Convert one archived UUID-correlated timing file; never replace the original."""
import argparse
import json
from pathlib import Path
import uuid

MAX_UINT64 = (1 << 64) - 1
PHASES = {'runStarted', 'runFinished', 'runFailed', 'actionEmitted', 'actionDropped', 'outputDelivered', 'effectsCancelled'}

def convert(text):
    rows = []
    originals = set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict) or type(row.get('schemaVersion', 1)) is not int or row.get('schemaVersion', 1) not in (1, 2):
            raise ValueError(f'line {number}: unsupported timing schema')
        if row.get('phase') not in PHASES:
            raise ValueError(f'line {number}: unknown phase')
        for key in ('sequence', 'timestampNanos'):
            value = row.get(key)
            if type(value) is not int or not 0 <= value <= MAX_UINT64:
                raise ValueError(f'line {number}: invalid {key}')
        for key in ('effectID', 'actionLabel'):
            if row.get(key) is not None and not isinstance(row[key], str):
                raise ValueError(f'line {number}: invalid {key}')
        value = row.get('dispatchID')
        if isinstance(value, str):
            if row.get('schemaVersion', 1) != 1:
                raise ValueError(f'line {number}: UUID identity in numeric schema')
            value = str(uuid.UUID(value))
            row['dispatchID'] = value
        elif value is not None:
            if type(value) is not int or not 0 <= value <= MAX_UINT64:
                raise ValueError(f'line {number}: invalid dispatchID')
            originals.add(value)
        rows.append(row)
    # A mixed-format archive must not alias an existing numeric correlation.
    next_id = 1
    identities = {}
    for row in rows:
        value = row.get('dispatchID')
        if isinstance(value, str):
            if value not in identities:
                while next_id in originals:
                    next_id += 1
                if next_id > MAX_UINT64:
                    raise ValueError('No representable UInt64 correlation remains')
                identities[value] = next_id
                originals.add(next_id)
                next_id += 1
            row['legacyDispatchID'] = value
            row['dispatchID'] = identities[value]
        row['schemaVersion'] = 2
    return ''.join(json.dumps(row, sort_keys=True, separators=(',', ':')) + '\n' for row in rows)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = convert(args.input.read_text())
        with args.output.open('x') as stream:
            stream.write(result)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(2, f'{error}\n')

if __name__ == '__main__':
    main()
