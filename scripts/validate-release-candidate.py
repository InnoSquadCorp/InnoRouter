#!/usr/bin/env python3
"""Network-free version + exact-SHA candidate identity; never creates a tag."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def validate(root, version, sha):
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('commit-sha must be a full lowercase SHA')
    subprocess.run(['python3', str(root / 'scripts/release-version-policy.py'), 'classify', version], check=True, stdout=subprocess.DEVNULL)
    resolved = subprocess.check_output(['git', '-C', str(root), 'rev-parse', sha + '^{commit}'], text=True).strip()
    if resolved != sha:
        raise ValueError('candidate must identify an exact commit')
    with tempfile.TemporaryDirectory(prefix='innorouter-candidate-') as temp:
        candidate = Path(temp)
        for name in ('CHANGELOG.md', 'README.md', 'README.ko.md', 'Sources/InnoRouterCore/InnoRouterVersion.swift'):
            target = candidate / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(subprocess.check_output(['git', '-C', str(root), 'show', sha + ':' + name]))
        channel = 'prerelease' if '-' in version else 'ga'
        subprocess.run(['bash', str(root / 'scripts/check-release-identity.sh'), version, channel, temp], check=True, stdout=subprocess.DEVNULL)
    return {'version': version, 'commit_sha': sha, 'prerelease': str('-' in version).lower()}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--version', required=True)
    p.add_argument('--commit-sha', required=True)
    args = p.parse_args()
    try:
        for name, value in validate(Path(__file__).resolve().parent.parent, args.version, args.commit_sha).items():
            print(name + '=' + value)
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit('Candidate rejected: ' + str(error))


if __name__ == '__main__':
    main()
