#!/usr/bin/env python3
"""Publish a reviewed source snapshot; never push the private development history."""
import argparse
import io
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import struct
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PUBLIC = ['Package.swift', 'README.md', 'AGENTS.md', '.gitignore', 'Sources', 'Tests', 'Resources', 'scripts']

def git_environment():
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k != "EMAIL"}

def run(*args, cwd=ROOT, capture=False):
    return subprocess.run(args, cwd=cwd, env=git_environment(), check=True, text=True, stdout=subprocess.PIPE if capture else None).stdout

def strip_image_metadata(path):
    original = path.read_bytes()
    if original[:8] != b"\x89PNG\r\n\x1a\n": raise SystemExit('Invalid PNG icon')
    result = bytearray(original[:8]); offset = 8
    while offset < len(original):
        size = struct.unpack('>I', original[offset:offset + 4])[0]
        end = offset + size + 12
        if end > len(original): raise SystemExit('Truncated PNG icon')
        kind = original[offset + 4:offset + 8]
        # Retain pixels and rendering metadata only, excluding provenance/text metadata.
        if kind in [b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'gAMA', b'cHRM', b'sRGB']:
            result.extend(original[offset:end])
        offset = end
    path.write_bytes(result)

def scan(directory, scanner):
    # Source-only publication: data files, signing material and machine paths are forbidden.
    forbidden = re.compile(r'(?:^|/)(?:\.env(?:\..*)?|memories\.json|call-history.*|test-records.*|credentials.*|.*\.(?:p12|pfx|key|pem|log|jsonl|zip|dmg))$', re.I)
    private_text = re.compile(r'/Users/[A-Za-z0-9_.-]+/|[A-Z0-9._%+-]+@(?!users\.noreply\.github\.com)[A-Z0-9.-]+\.[A-Z]{2,}', re.I)
    for path in directory.rglob('*'):
        if '.git' in path.relative_to(directory).parts or not path.is_file():
            continue
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink() or forbidden.search(relative):
            raise SystemExit('Publication blocked: disallowed file ' + relative)
        if path.suffix == '.png':
            if relative != 'Resources/AppIcon.png':
                raise SystemExit('Publication blocked: unreviewed image ' + relative)
            continue
        text = path.read_text(encoding='utf-8')
        if private_text.search(text):
            raise SystemExit('Publication blocked: private path/email in ' + relative)
    run(str(scanner), 'dir', str(directory), '--redact', '--no-banner')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='HuiAnnn/her-his')
    parser.add_argument('--publish', action='store_true', help='Push main, version tag and GitHub Release after scanning')
    args = parser.parse_args()
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', args.repo):
        raise SystemExit('Invalid repository name')
    if run('git', 'status', '--porcelain', capture=True).strip():
        raise SystemExit('Commit reviewed changes before publishing; working tree must be clean.')
    scanner = Path(os.environ.get('GITLEAKS_BIN') or shutil.which('gitleaks') or ROOT / 'build/privacy-tools/gitleaks').resolve()
    if not scanner.is_file():
        raise SystemExit('Gitleaks required: install the official scanner or set GITLEAKS_BIN.')
    (ROOT / 'build').mkdir(exist_ok=True)
    archive = subprocess.check_output(['git', 'archive', 'HEAD', '--', *PUBLIC], cwd=ROOT, env=git_environment())
    with tempfile.TemporaryDirectory(prefix='public-source-', dir=ROOT / 'build') as temporary:
        snapshot = Path(temporary) / 'snapshot'; snapshot.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for member in tar.getmembers():
                dest = snapshot / member.name
                if not dest.resolve().is_relative_to(snapshot.resolve()) or not (member.isdir() or member.isfile()):
                    raise SystemExit('Unsafe archive member')
                if member.isdir(): dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(tar.extractfile(member).read())
                    dest.chmod(member.mode & 0o777)
        strip_image_metadata(snapshot / "Resources/AppIcon.png")
        scan(snapshot, scanner)
        with (snapshot / 'Resources/Info.plist').open('rb') as f:
            version = plistlib.load(f)['CFBundleShortVersionString']
        if not re.fullmatch(r'\d+\.\d+\.\d+', version): raise SystemExit('Invalid version')
        tag = 'v' + version
        print('Privacy scan passed for source snapshot ' + tag, flush=True)
        if not args.publish: return
        if run('gh', 'repo', 'view', args.repo, '--json', 'visibility', '--jq', '.visibility', capture=True).strip() != 'PUBLIC':
            raise SystemExit('Expected a public repository; visibility was not changed automatically.')
        # GitHub already contains only reviewed public snapshots; local development Git is never a remote source.
        checkout = Path(temporary) / 'git'
        run('git', 'clone', '--quiet', 'https://github.com/' + args.repo + '.git', str(checkout))
        run('git', 'checkout', '-B', 'main', cwd=checkout)
        for entry in checkout.iterdir():
            if entry.name == '.git': continue
            if entry.is_dir() and not entry.is_symlink(): shutil.rmtree(entry)
            else: entry.unlink()
        shutil.copytree(snapshot, checkout, dirs_exist_ok=True)
        account = run('gh', 'api', 'user', '--jq', '.login + " " + (.id|tostring)', capture=True).strip().split()
        for key, value in [('commit.gpgsign', 'false'), ('tag.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
            run('git', 'config', key, value, cwd=checkout)
        run('git', 'config', 'user.name', account[0], cwd=checkout)
        run('git', 'config', 'user.email', account[1] + '+' + account[0] + '@users.noreply.github.com', cwd=checkout)
        run('git', 'add', '--all', cwd=checkout)
        changed = subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=checkout, env=git_environment()).returncode
        existing = subprocess.run(['git', 'rev-parse', '--verify', 'refs/tags/' + tag], cwd=checkout, env=git_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if existing and changed: raise SystemExit('This version already exists; increment version before publishing changes.')
        if changed: run('git', 'commit', '-m', 'Release ' + tag, cwd=checkout)
        expected_email = account[1] + '+' + account[0] + '@users.noreply.github.com'
        metadata = run('git', 'log', '-1', '--format=%an%n%ae%n%cn%n%ce%n%G?', cwd=checkout, capture=True).splitlines()
        if metadata != [account[0], expected_email, account[0], expected_email, 'N']:
            raise SystemExit('Publication blocked: unexpected commit identity or signature')
        if not existing: run('git', 'tag', tag, cwd=checkout)
        run(str(scanner), 'git', str(checkout), '--redact', '--no-banner')
        run('git', 'push', '--atomic', 'origin', 'main', 'refs/tags/' + tag, cwd=checkout)
        released = subprocess.run(['gh', 'release', 'view', tag, '--repo', args.repo], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not released:
            notes = Path(temporary) / 'release.md'
            notes.write_text('Reviewed source release. Includes source code, synthetic tests and build scripts. Personal memories, recordings, credentials, local diagnostics and signing material are excluded. Build locally with your own signing identity; no personally signed app binary is attached.\n')
            run('gh', 'release', 'create', tag, '--repo', args.repo, '--verify-tag', '--title', '在场 ' + version, '--notes-file', str(notes))
        print('Published https://github.com/' + args.repo + '/releases/tag/' + tag)

if __name__ == '__main__': main()
