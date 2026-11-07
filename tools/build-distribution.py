"""Build and verify a demo-only distribution from a clean public checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_rows(path):
    return [json.loads(line) for line in path.read_text('utf-8-sig').splitlines() if line.strip()]


def verify_demo(root):
    rows = read_rows(root / 'data/seen.jsonl')
    projects = read_rows(root / 'data/projects.jsonl')
    if len(rows) != 15 or len(projects) != 15:
        raise ValueError('Release source must contain the reviewed 15-project demo, not a personal library')
    if any(p.get('note') or p.get('user_notes') or p.get('origin') == 'user' for p in projects):
        raise ValueError('Personal notes or user-origin projects cannot be released')
    for name in ('user-notes.jsonl', 'workspaces.jsonl', 'status-log.jsonl'):
        if (root / 'data' / name).read_text('utf-8-sig').strip():
            raise ValueError('Personal runtime file is not empty: ' + name)


def privacy_scan(root, paths):
    patterns = {
        'user-directory': re.compile(r'(?i)[A-Z]:[\\/]+Users[\\/]+(?!Public|Default|<)[^\\/\s\"<>]+'),
        'personal-workspace': re.compile(r'[A-Z]:[\\/]+(?:Codex工作区|工作区)'),
        'credential': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{30,})'),
        'session-constant': re.compile(r'(?m)^const\s+(?:SESSION_ID|WS_ID)\s*='),
    }
    hits = []
    for rel in paths:
        p = root / rel
        try:
            text = p.read_text('utf-8-sig')
        except UnicodeError:
            continue
        for kind, pattern in patterns.items():
            if pattern.search(text):
                hits.append({'file': rel, 'kind': kind})
    if hits:
        raise ValueError('Privacy scan failed (values redacted): ' + json.dumps(hits))


def command(root, output, name, args, expect_success=True):
    with (output / (name + '.log')).open('w', encoding='utf-8') as log:
        result = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', *args],
                                cwd=root, stdout=log, stderr=subprocess.STDOUT)
    text = (output / (name + '.log')).read_text('utf-8-sig')
    if expect_success and result.returncode != 0:
        raise ValueError(name + ' failed; inspect its log')
    if not expect_success:
        gate_log = root / 'data/_tmp/check-all/release-readiness.log'
        verdict = gate_log.read_text('utf-8-sig') if gate_log.exists() else text
        if result.returncode == 0 or 'BLOCKED' not in verdict:
            raise ValueError('Missing daily evidence did not block publication')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        raise ValueError('Invalid version')
    source = args.source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    config = json.loads((source / 'release/distribution-files.json').read_text('utf-8-sig'))
    paths = config['files']
    if len(set(p.lower() for p in paths)) != len(paths):
        raise ValueError('Duplicate release paths')
    for rel in paths:
        p = PurePosixPath(rel)
        if p.is_absolute() or '..' in p.parts or '\\' in rel or ':' in rel:
            raise ValueError('Invalid release path')
        if any(part in ('_backup', '_tmp', '.git', '.codex', '.aws', '.devtools') for part in p.parts) or p.name == 'relink-session.js':
            raise ValueError('Private/runtime file on release allowlist')
        real = (source / rel).resolve(strict=True)
        if not real.is_relative_to(source) or not real.is_file():
            raise ValueError('Release input must be a real file inside the source checkout')
    verify_demo(source)
    privacy_scan(source, paths)
    stage = Path(tempfile.mkdtemp(prefix='verified-stage-', dir=output))
    for rel in paths:
        target = stage / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / rel, target)
    command(stage, output, 'build-pages', ['tools/rebuild-page.ps1', '-Quiet'])
    # Match Git's LF policy, while preserving the locked glossary byte-for-byte.
    for rel in paths:
        if rel == 'GLOSSARY.md':
            continue
        file = stage / rel
        data = file.read_bytes()
        try:
            data.decode('utf-8-sig')
        except UnicodeError:
            continue
        if b'\r\n' in data:
            while b'\r\n' in data:
                data = data.replace(b'\r\n', b'\n')
            file.write_bytes(data)
    verify_demo(stage)
    privacy_scan(stage, paths)
    manifest = {'schema_version': 1, 'profile': 'demo', 'version': args.version,
                'files': [{'path': rel, 'sha256': digest(stage / rel)} for rel in sorted(paths)]}
    (stage / 'distribution.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    command(stage, output, 'pristine', ['tools/check-distribution.ps1', '-Pristine'])
    command(stage, output, 'check-all', ['tools/check-all.ps1'])
    command(stage, output, 'publish-must-block', ['tools/check-all.ps1', '-Publish', '-Date', '2026-10-19'], False)
    # Only manifest-declared inputs and generated views enter the ZIP; build/test output stays out.
    package = output / ('repodossier-v' + args.version + '.zip')
    with zipfile.ZipFile(package, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for rel in sorted(paths + ['distribution.json']):
            archive.write(stage / rel, rel)
    (output / (package.name + '.sha256')).write_text(digest(package) + '  ' + package.name + '\n', 'ascii')
    # Independently extract the actual ZIP, preserving ZIP timestamps for freshness checks.
    extracted = Path(tempfile.mkdtemp(prefix='clean-extract-', dir=output))
    import time
    with zipfile.ZipFile(package) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP integrity failed')
        archive.extractall(extracted)
        for info in archive.infolist():
            if not info.is_dir():
                timestamp = time.mktime(info.date_time + (0, 0, -1))
                os.utime(extracted / info.filename, (timestamp, timestamp))
    privacy_scan(extracted, paths)
    command(extracted, output, 'extracted-pristine', ['tools/check-distribution.ps1', '-Pristine'])
    command(extracted, output, 'extracted-check-all', ['tools/check-all.ps1'])
    report = {'version': args.version, 'package': str(package), 'sha256': digest(package),
              'files': len(paths) + 1, 'stage': str(stage), 'extracted': str(extracted),
              'privacy_hits': 0, 'package_checks': 'pass', 'fresh_daily_publication': 'blocked as required'}
    (output / 'build-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), 'utf-8')
    print(json.dumps(report, ensure_ascii=True))


if __name__ == '__main__':
    main()
