#!/usr/bin/env python3
"""Check current README language coverage, navigation, code and critical contracts.

This checks reviewable structure and identifiers, not natural-language quality.
"""
import argparse
import json
from pathlib import Path
import re

READMES = ('README.md', 'README.ko.md', 'README.es.md', 'README.de.md',
           'README.zh-Hans.md', 'README.ja.md', 'README.ru.md')
SWITCHER = ('[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | '
            '[Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | '
            '[日本語](README.ja.md) | [Русский](README.ru.md)')
CRITICAL = ('InnoFlowCore', 'InnoFlowSwiftUI', 'InnoFlowInspector', 'InnoFlowTesting',
            '@InnoFlow', '@InnoFlowCasePathIgnored', '@BindableField', 'ForEachIdentifiedReducer', 'FlowTask',
            'withFlowScope', 'EffectContext', 'ManualTestClock', 'TestStore.exhaustivity',
            'receiveOutput', '@testable import YourSwiftUIApp', 'finish()', 'cancel()', 'capturingOutputs:', 'mapOutput(_:)',
            'promoteOutput(to:)', 'select(dependingOn:)', 'select(dependingOnAll:)',
            'select(memoize: true)', 'always-refresh fallback', 'optionalState',
            'optionalValue', 'requireAlive()', 'PhaseTransitionGraph', 'strictPhaseTotality:',
            'requireComplete(...)', 'innoFlowTask', 'StoreDiagnostics', 'payload',
            'VoiceOver', 'Dynamic Type', 'accessibilityIdentifier', 'STABLE_VERSION',
            '6.3+', '18+', '15+', '11+', '2+', '603.0.0', '605.0.0', '604.0.0', '28',
            '18.5', '11.5', '2.5', 'OS 27')


def verify(root):
    contract = json.loads((root / 'docs/contracts/doc-parity.json').read_text())
    if tuple(contract['readmeLanguages']) != READMES:
        raise ValueError('README language contract must match InnoDI order')
    english = (root / READMES[0]).read_text()
    fences = re.findall(r'^```swift\n(.*?)^```', english, re.M | re.S)
    links = re.findall(r'\]\(([^)]+)\)', english)
    stable = (root / 'STABLE_VERSION').read_text().strip()
    for file in READMES:
        source = (root / file).read_text()
        if '\n\n' + SWITCHER + '\n\n' not in source:
            raise ValueError(file + ': missing canonical switcher')
        before = source.split(SWITCHER)[0].rstrip().splitlines()[-1]
        if not before.startswith('[![Release]'):
            raise ValueError(file + ': switcher must immediately follow badges')
        if len(re.findall(r'^## ', source, re.M)) != 10:
            raise ValueError(file + ': entry section coverage changed')
        if f'## InnoFlow {stable}\n' not in source or f'from: "{stable}"' not in source:
            raise ValueError(file + ': stable installation/version drift')
        if re.findall(r'^```swift\n(.*?)^```', source, re.M | re.S) != fences:
            raise ValueError(file + ': Swift examples differ from compiled English source')
        if re.findall(r'\]\(([^)]+)\)', source) != links:
            raise ValueError(file + ': link targets/order differ from English')
        for identifier in CRITICAL:
            if identifier not in source:
                raise ValueError(file + ': missing contract identifier ' + identifier)
        for value in ('2026-10-08', '1176de1e4783b638c03a9334f43cc49378957148'):
            if value not in source:
                raise ValueError(file + ': published baseline provenance drift')
    for old, new in [('kr', 'ko'), ('jp', 'ja'), ('cn', 'zh-Hans')]:
        source = (root / f'README.{old}.md').read_text()
        if f'(README.{new}.md)' not in source or '```swift' in source:
            raise ValueError('Legacy README must redirect without stale install examples')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        verify(args.root)
    except (ValueError, KeyError, FileNotFoundError) as error:
        raise SystemExit('[readme-parity] ' + str(error))
    print('[readme-parity] seven languages: matching sections, examples, links and critical contracts')
