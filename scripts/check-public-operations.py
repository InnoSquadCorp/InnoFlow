#!/usr/bin/env python3
"""Repository-local dependency coherence and privileged workflow boundaries (offline)."""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = 'Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage'
LOCKS = ['Package.resolved', SAMPLE + '/Package.resolved',
         'Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
         'Tools/docc-package.resolved']
PERMISSIONS = {
    'inspect': {'contents': 'read', 'actions': 'read', 'checks': 'read', 'pull-requests': 'read'},
    'manual-ready': {'contents': 'read', 'actions': 'read', 'checks': 'write', 'pull-requests': 'read'},
    'bot-ready': {'contents': 'write', 'actions': 'read', 'checks': 'write', 'pull-requests': 'write'},
    'post-merge': {'contents': 'read', 'actions': 'write', 'pull-requests': 'read'},
}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def dependabot(root):
    config = json.loads((root / '.github/dependabot.yml').read_text())
    require(config.get('version') == 2, 'Dependabot schema version changed')
    updates = config.get('updates', [])
    require(len(updates) == 2, 'exact Actions and Swift update inventory required')
    by_kind = {u.get('package-ecosystem'): u for u in updates}
    require(set(by_kind) == {'github-actions', 'swift'}, 'wrong Dependabot ecosystem inventory')
    for ecosystem, minute, limit, prefix, group, label in [
        ('github-actions', '09:00', 5, 'chore(ci)', 'actions-minor-patch', 'github-actions'),
        ('swift', '09:30', 3, 'chore(deps)', 'swift-minor-patch', 'swift')]:
        item = by_kind[ecosystem]
        require(item.get('schedule') == {'interval': 'weekly', 'day': 'monday', 'time': minute, 'timezone': 'Asia/Seoul'}, 'weekly schedule drift')
        require(item.get('open-pull-requests-limit') == limit, 'version PR limit drift')
        require(item.get('commit-message') == {'prefix': prefix}, 'commit prefix drift')
        require(item.get('labels') == ['dependencies', label, 'release-validation'], 'dependency labels drift')
        groups = item.get('groups', {})
        require(set(groups) == {group}, 'low-risk group inventory drift')
        expected = {'patterns': ['*'], 'update-types': ['minor', 'patch']}
        if ecosystem == 'swift':
            expected['exclude-patterns'] = ['github.com/swiftlang/swift-syntax']
            require(item.get('directories') == ['/', '/' + SAMPLE] and 'directory' not in item, 'live Swift manifest inventory drift')
            live = sorted(str(p.parent.relative_to(root)) for p in (root / 'Examples').rglob('Package.swift'))
            require(live == [SAMPLE], 'new live example manifest needs explicit policy review')
        else:
            require(item.get('directory') == '/' and 'directories' not in item, 'Actions directory drift')
        require(groups[group] == expected, 'major/toolchain updates must remain individual, not ignored')
        require(not item.get('ignore') and not item.get('allow') and not item.get('exclude-paths'), 'dependency updates must not be silently excluded')


def syntax_pin(root, path):
    document = json.loads((root / path).read_text())
    matches = [p for p in document['pins'] if p['identity'] == 'swift-syntax']
    require(len(matches) == 1, f'{path}: missing/duplicate SwiftSyntax pin')
    pin = matches[0]
    require(pin.get('kind') == 'remoteSourceControl' and pin.get('location') == 'https://github.com/swiftlang/swift-syntax.git', f'{path}: foreign SwiftSyntax source')
    state = pin['state']
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', state.get('version', '')) and re.fullmatch(r'[0-9a-f]{40}', state.get('revision', '')), f'{path}: immutable version/revision required')
    return state['version'], state['revision']


def coherence(root):
    states = [syntax_pin(root, path) for path in LOCKS]
    require(len(set(states)) == 1, 'root, sample, Xcode and DocC SwiftSyntax locks must agree')
    version, revision = states[0]
    manifest = (root / 'Package.swift').read_text()
    spans = re.findall(r'\.package\(url: "https://github.com/swiftlang/swift-syntax.git", "([0-9]+)\.0\.0"\.\.<"([0-9]+)\.0\.0"\)', manifest)
    require(len(spans) == 1, 'root manifest must retain one reviewed SwiftSyntax range')
    low, high = map(int, spans[0])
    require((low, high) == (603, 605), 'manifest must retain reviewed 603.0.0..<605.0.0 range')
    require(low <= int(version.split('.')[0]) < high, 'resolved SwiftSyntax is outside manifest toolchain range')
    require(manifest.startswith('// swift-tools-version: 6.3'), 'minimum Swift 6.3 contract changed')
    generator = (root / 'Tools/generate-docc.sh').read_text()
    for key, value in [('DOCC_SWIFT_SYNTAX_VERSION', version), ('DOCC_SWIFT_SYNTAX_REVISION', revision)]:
        require(re.findall(r'^' + key + r'="([^"]+)"$', generator, re.M) == [value], 'DocC generator/lock mismatch: ' + key)
    require('--disable-automatic-resolution' in generator and 'cp "$DOCC_LOCKFILE" "$DOCS_PACKAGE_DIR/Package.resolved"' in generator, 'frozen DocC resolution required')


def workflow_boundaries(root):
    source = (root / '.github/workflows/dependabot-auto-merge.yml').read_text()
    jobs_text = source.split('\njobs:\n', 1)[1]
    jobs = {m[1]: m[2] for m in re.finditer(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', jobs_text, re.M | re.S)}
    require(set(jobs) == set(PERMISSIONS), 'unexpected coordinator job')
    for name, expected in PERMISSIONS.items():
        job = jobs[name]
        if name in {'manual-ready', 'bot-ready'}:
            require(re.search(r'^    strategy:\n      fail-fast: false\n      matrix:', job, re.M),
                    name + ': independent PR matrix must not fail fast')
        block = re.search(r'^    permissions:\n((?:^      [\w-]+: (?:read|write|none)\n)+)', job, re.M)
        require(block is not None, name + ': missing explicit dedicated permissions')
        found = dict(re.findall(r'^      ([\w-]+): (read|write|none)$', block[1], re.M))
        require(found == expected, name + ': permissions expanded or missing')
        require(job.count('ref: refs/heads/main') == 1 and job.count('persist-credentials: false') == 1 and job.count('sparse-checkout: scripts') == 1, name + ': trusted checkout contract missing')
        require("github.ref == 'refs/heads/main'" in job and "github.workflow_ref == 'InnoSquadCorp/InnoFlow/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'" in job, name + ': trusted execution guard missing')
    for unsafe in ['pull_request.head', 'secrets.', 'download-artifact', 'cache@', 'gh pr merge', 'pip install', 'npm install', 'continue-on-error']:
        require(unsafe not in source, 'unsafe privileged coordinator input: ' + unsafe)
    notice = (root / '.github/workflows/dependabot-review-notice.yml').read_text()
    require('permissions: {}' in notice and 'uses:' not in notice and 'secrets.' not in notice and 'GH_TOKEN' not in notice, 'review notice must be inert and zero-permission')
    for path in ['ci.yml', 'coverage.yml', 'docs.yml', 'asan.yml']:
        workflow = (root / '.github/workflows' / path).read_text()
        require(not re.search(r'^\s+(?:contents|actions|checks|pull-requests|pages|id-token):\s*write', workflow, re.M), path + ': validation token must remain read-only')
        require('secrets: inherit' not in workflow and 'persist-credentials: true' not in workflow, path + ': credential inheritance forbidden')


def validate(root):
    dependabot(root)
    coherence(root)
    workflow_boundaries(root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        validate(args.root)
    except (ValueError, KeyError, OSError, TypeError) as error:
        print('[public-operations] ' + str(error), file=sys.stderr)
        sys.exit(1)
    print('[public-operations] Dependency grouping, lock coherence and token boundaries passed')
