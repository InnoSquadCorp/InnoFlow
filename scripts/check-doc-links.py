#!/usr/bin/env python3
"""Validate local Markdown link destinations and heading anchors; no network."""
import argparse
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

LINK = re.compile(r'\[[^\]\n]*\]\((<[^>]+>|(?:[^()\s]|\([^()]*\))+)(?:\s+"[^"]*")?\)')


def anchors(source):
    result = set(re.findall(r'<a\s+(?:name|id)=[\"\']([^\"\']+)', source))
    duplicates = {}
    for heading in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', source, re.M):
        heading = re.sub(r'<[^>]+>', '', heading)
        heading = re.sub(r'\[([^]]+)\]\([^)]*\)', r'\1', heading)
        slug = re.sub(r'[^\w\-\s]', '', heading.lower()).replace(' ', '-')
        count = duplicates.get(slug, 0)
        duplicates[slug] = count + 1
        result.add(slug if count == 0 else f'{slug}-{count}')
    return result


def errors_for(root, files):
    failures = []
    checked = 0
    for file in files:
        path = root / file
        source = path.read_text()
        # Code examples and literal Markdown examples are not document navigation.
        source = re.sub(r'^```[^\n]*\n.*?^```\s*$', '', source, flags=re.M | re.S)
        for match in LINK.finditer(source):
            url = match[1].strip('<>')
            parsed = urlsplit(url)
            if parsed.scheme or parsed.netloc:
                continue
            checked += 1
            target = (path.parent / unquote(parsed.path)).resolve() if parsed.path else path.resolve()
            if not target.is_relative_to(root.resolve()) or not target.exists():
                failures.append(f'{file}: unavailable local target {url}')
            elif parsed.fragment and target.suffix in ('.md', '.mdx'):
                if unquote(parsed.fragment) not in anchors(target.read_text()):
                    failures.append(f'{file}: missing heading anchor {url}')
    return checked, failures


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    files = subprocess.check_output(['git', '-C', str(args.root), 'ls-files', '-z',
        '--cached', '--others', '--exclude-standard', '--', '*.md', '*.mdx'], text=True).split('\0')
    checked, failures = errors_for(args.root, sorted(set(file for file in files if file)))
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'[doc-links] {checked} local destinations/anchors verified; external URLs not fetched')
