#!/usr/bin/env python3
"""Inspect exactly the staged/committed files, or a release bundle, before upload.

This is a conservative local check, not a guarantee of secret detection. It never
prints matching values; findings identify only a path, line and rule.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_FILES = {'.gitignore', '.gitattributes', 'README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md', 'LICENSE', 'Package.swift'}
PUBLIC_DIRS = {'.github', '.githooks', 'Examples', 'Prompts', 'Resources', 'Sources', 'Tests', 'cloud', 'docs', 'mcp', 'plugins', 'scripts'}
PRIVATE_NAMES = {'ledger.json', 'notification-history.json', 'cloud-settings.json', 'cloud-checkpoint.json', 'cloud-project.json', 'MoraCloud.json', 'client-config.json', 'runtime.sh', 'mcp-http-token', '.DS_Store'}
PRIVATE_PARTS = {'outputs', 'build', '.build', '.venv', '.swiftpm', 'node_modules', '__pycache__', 'private-notes', '.env'}
PRIVATE_DOCS = {'cloud/VERIFICATION.md', 'docs/localization-and-navigation.md', 'docs/scrolling-regression.md'}
RULES = {
    'absolute user home': re.compile(rb'/' + rb'Users/[^/\s\x00]+/'),
    'private temporary path': re.compile(rb'/(?:private/)?var/folders/'),
    'live cloud project': re.compile(rb'https://[a-z]{20}\.supabase\.co'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub credential': re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'cloud credential': re.compile(rb'sb_(?:secret|publishable)_[A-Za-z0-9_-]{20,}'),
    'JWT credential': re.compile(rb'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}'),
    'API credential': re.compile(rb'(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16}|AIza[0-9A-Za-z_-]{30,})'),
}
EMAIL = re.compile(rb'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')
# The developer explicitly publishes this app support contact. Keep the exception
# scoped to its UI source and the assembled executable, not arbitrary documents.
PUBLIC_SUPPORT_EMAIL = 'yar.thedeveloper' + '@' + 'proton.me'


def git(*args: str) -> bytes:
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def tracked(tree: str | None, seen: set | None = None):
    if tree:
        rows = git('ls-tree', '-rz', tree).split(b'\0')
    else:
        rows = git('ls-files', '--stage', '-z').split(b'\0')
    for row in rows:
        if not row:
            continue
        metadata, name = row.split(b'\t', 1)
        parts = metadata.decode().split()
        mode, oid = parts[0], parts[2] if tree else parts[1]
        if not tree and parts[2] != '0':
            raise ValueError('Resolve merge conflicts before publication.')
        identity = (name, mode, oid)
        if seen is not None:
            if identity in seen:
                continue
            seen.add(identity)
        yield name.decode(), mode, git('cat-file', 'blob', oid)


def path_issue(name: str, bundle: bool) -> str | None:
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts:
        return 'unsafe path'
    if path.name in PRIVATE_NAMES or path.name.startswith(('mcp-app-', 'Mora-backup-', '.env')) or path.suffix in {'.backup', '.pem', '.p12', '.p8', '.shortcut', '.log', '.pyc'}:
        return 'private/generated file'
    if any(part in PRIVATE_PARTS for part in path.parts) or name in PRIVATE_DOCS:
        return 'private/generated directory'
    if not bundle and path.parts[0] not in PUBLIC_DIRS and name not in PUBLIC_FILES:
        return 'outside public source allowlist'
    return None


def inspect(files, bundle: bool = False) -> list[str]:
    issues = []
    local_list = ROOT / '.build/publication-denylist.json'
    denied = json.loads(local_list.read_text()) if local_list.exists() else []
    count = 0
    for name, mode, data in files:
        count += 1
        if reason := path_issue(name, bundle):
            issues.append(f'{name}: {reason}')
        if mode == '120000':
            issues.append(f'{name}: symbolic links are not allowed')
        for rule, pattern in RULES.items():
            if match := pattern.search(data):
                line = data[:match.start()].count(b'\n') + 1
                issues.append(f'{name}:{line}: {rule}')
        for match in EMAIL.finditer(data):
            address = match.group().decode().lower()
            if re.fullmatch(r'icon_[0-9]+x[0-9]+@2x\.png', address):
                continue
            if address == PUBLIC_SUPPORT_EMAIL and name == ('Contents/MacOS/Mora' if bundle else 'Sources/Mora/Support.swift'):
                continue
            if not address.endswith(('@example.test', '@example.com', '@example-project.supabase.co', '@users.noreply.github.com', '@noreply.github.com')) and address != 'git@github.com':
                issues.append(f'{name}: non-example email address')
                break
        for value in denied:
            if value.encode().lower() in data.lower():
                issues.append(f'{name}: local private-data denylist match')
                break
    if count == 0:
        issues.append('No files selected for publication.')
    print(f'Inspected {count} files; {len(issues)} findings.')
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', help='Git ref to inspect; defaults to the exact Git index')
    parser.add_argument('--history', help='Inspect every reachable commit, deduplicating unchanged blobs')
    parser.add_argument('--bundle', type=Path, help='Inspect the files of an assembled .app')
    args = parser.parse_args()
    if args.bundle:
        base = args.bundle.resolve()
        if not base.is_dir():
            parser.error('Bundle directory does not exist.')
        files = ((p.relative_to(base).as_posix(), '120000' if p.is_symlink() else '100644', p.read_bytes()) for p in sorted(base.rglob('*')) if p.is_file())
    elif args.history:
        seen: set = set()
        commits = git('rev-list', args.history).decode().splitlines()
        files = (file for commit in commits for file in tracked(commit, seen))
    else:
        files = tracked(args.tree)
    findings = inspect(files, bundle=args.bundle is not None)
    for finding in findings:
        print(finding, file=sys.stderr)
    return 1 if findings else 0


if __name__ == '__main__':
    raise SystemExit(main())
