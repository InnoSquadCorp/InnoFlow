#!/usr/bin/env python3
"""Fixed paired public-consumer benchmark; failed/incomplete cohorts are never PASS."""
import argparse, hashlib, json, math, os, platform, random, statistics, subprocess, time
from pathlib import Path
COUNTS = {"S1": 100_000, "S2": 20_000, "S3": 2_000, "S4": 30_000, "S5": 100_000, "S6": 2_000, "diagnostics": 30_000, "output": 2_000, "cancel": 5_000}
p = argparse.ArgumentParser()
p.add_argument('--reference', required=True, type=Path); p.add_argument('--candidate', required=True, type=Path)
p.add_argument('--output', required=True, type=Path); p.add_argument('--pairs', type=int, default=30)
p.add_argument('--build-admission', required=True, type=Path)
p.add_argument('--purpose', choices=['improvement', 'non-regression'], default='improvement')
p.add_argument('--scenarios', nargs='+', default=list(COUNTS)); p.add_argument('--label', required=True)
a = p.parse_args()
if a.pairs != 30 or any(x not in COUNTS for x in a.scenarios) or len(set(a.scenarios)) != len(a.scenarios): p.error('Exactly 30 fixed pairs and unique known scenarios are required')
required_scenarios = set(COUNTS) - ({'S5'} if platform.system() == 'Linux' else set())
if set(a.scenarios) != required_scenarios: p.error('The adoption cohort requires every supported scenario; Linux alone omits Apple-only S5')
if a.output.exists(): p.error('Output must be a fresh directory')
a.output.mkdir(parents=True)
reference, candidate = a.reference.resolve(strict=True), a.candidate.resolve(strict=True)
admission_bytes = a.build_admission.read_bytes()
admission = json.loads(admission_bytes)
initial_hashes = {'reference': hashlib.sha256(reference.read_bytes()).hexdigest(), 'candidate': hashlib.sha256(candidate.read_bytes()).hexdigest()}
if type(admission.get('schemaVersion')) is not int or admission.get('schemaVersion') != 1 or admission.get('admitted') is not True:
    p.error('A successful actual-invocation build admission is required')
for side in initial_hashes:
    if admission.get(side + '_binary_sha256') != initial_hashes[side]:
        p.error('Build admission does not identify the measured ' + side + ' binary')
meta = {'label': a.label, 'purpose': a.purpose, 'build_admission_sha256': hashlib.sha256(admission_bytes).hexdigest(), 'pairs': a.pairs, 'warmups': 2, 'scenarios': a.scenarios,
        'omitted_scenarios': sorted(set(COUNTS)-set(a.scenarios)), 'counts': COUNTS,
        'platform': platform.platform(), 'machine': platform.machine(),
        'reference_sha256': hashlib.sha256(reference.read_bytes()).hexdigest(),
        'candidate_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(),
        'started_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'status': 'running', 'required_supported_scenarios': sorted(required_scenarios)}
(a.output/'manifest.json').write_text(json.dumps(meta, indent=2)+'\n')
rows=[]

def run(exe, scenario, side, pair, warmup=False):
    start=time.time()
    completed=subprocess.run([str(exe), scenario, str(COUNTS[scenario])], capture_output=True, text=True, timeout=180)
    name=f'{scenario}-{pair:02d}-{side}'+('-warmup' if warmup else '')
    (a.output/(name+'.stdout')).write_text(completed.stdout)
    (a.output/(name+'.stderr')).write_text(completed.stderr)
    if completed.returncode != 0: raise RuntimeError(f'{name}: exit {completed.returncode}')
    data=json.loads(completed.stdout.strip().splitlines()[-1])
    expected_checksum = COUNTS[scenario] * (11 if scenario == 'S2' else 2 if scenario == 'S6' else 1) + (6650 if scenario == 'S4' else -1 if scenario == 'S5' else 0)
    ns = data.get('ns', 0)
    if data.get('status')!='measured' or data.get('scenario')!=scenario or data.get('iterations')!=COUNTS[scenario] or type(ns) not in (int, float) or not math.isfinite(ns) or ns <= 0 or type(data.get('checksum')) is not int or data['checksum'] != expected_checksum:
        raise RuntimeError(f'{name}: invalid result')
    row={**data,'side':side,'pair':pair,'warmup':warmup,'started_unix':start}
    with (a.output/'samples.jsonl').open('a') as stream: stream.write(json.dumps(row)+'\n')
    if not warmup: rows.append(row)
    return row

try:
    for scenario in a.scenarios:
        for i in range(2):
            run(reference, scenario, 'reference', i, True); run(candidate, scenario, 'candidate', i, True)
        for pair in range(a.pairs):
            order=[('reference',reference),('candidate',candidate)]
            if pair%2: order.reverse()
            values={side:run(exe,scenario,side,pair) for side,exe in order}
            if values['reference']['checksum']!=values['candidate']['checksum']: raise RuntimeError(f'{scenario}: correctness mismatch')
    final_hashes = {'reference': hashlib.sha256(reference.read_bytes()).hexdigest(), 'candidate': hashlib.sha256(candidate.read_bytes()).hexdigest()}
    meta['final_binary_sha256'] = final_hashes
    if final_hashes != initial_hashes:
        raise RuntimeError('Measured binary changed during the cohort')
    if hashlib.sha256(a.build_admission.read_bytes()).hexdigest() != meta['build_admission_sha256']:
        raise RuntimeError('Build admission changed during the cohort')
    results={}
    for scenario in a.scenarios:
        lhs=[x for x in rows if x['scenario']==scenario and x['side']=='reference']
        rhs=[x for x in rows if x['scenario']==scenario and x['side']=='candidate']
        left={x['pair']:x['ns'] for x in lhs}; right={x['pair']:x['ns'] for x in rhs}
        if len(left)!=a.pairs or set(left)!=set(right): raise RuntimeError('Incomplete fixed cohort')
        ratios=[right[i]/left[i] for i in range(a.pairs)]
        rng=random.Random(0); boot=sorted(statistics.median(rng.choices(ratios,k=a.pairs)) for _ in range(10_000))
        results[scenario]={'reference_ns_per_operation':statistics.median(left.values())/COUNTS[scenario],
                           'candidate_ns_per_operation':statistics.median(right.values())/COUNTS[scenario],
                           'paired_median_ratio':statistics.median(ratios),
                           'paired_bootstrap_95': [boot[249],boot[9749]]}
    primary=all(k in results and results[k]['paired_median_ratio']<=.95 and results[k]['paired_bootstrap_95'][1]<=.95 for k in ['S1','S2'])
    secondary=all(v['paired_median_ratio']<=1.05 for v in results.values())
    non_regression = all(v['paired_median_ratio'] <= 1.05 and v['paired_bootstrap_95'][1] <= 1.05 for v in results.values())
    gate = primary and secondary if a.purpose == 'improvement' else non_regression
    (a.output/'summary.json').write_text(json.dumps({'results':results, 'purpose':a.purpose, 'linux_relative_performance_gate':gate,
        'decision': 'pass' if gate else 'not-established',
        'non_regression_rule': 'all supported scenarios paired median and bootstrap 95% upper <= 1.05' if a.purpose == 'non-regression' else None, 'adoption_requires_separate_correctness_and_api_evidence':True,
        'apple_absolute_targets':'not evaluated by this comparator','status':'complete'},indent=2)+'\n')
    meta['status']='complete'
except BaseException as error:
    meta['status']='incomplete'; meta['error']=str(error)
    raise
finally:
    meta['finished_at']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    (a.output/'manifest.json').write_text(json.dumps(meta,indent=2)+'\n')
