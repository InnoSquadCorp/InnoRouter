#!/usr/bin/env python3
"""Build/test a clean remote macro consumer at an exact SHA, without a tag."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit


def validate_identity(repository, sha):
    url = urlsplit(repository)
    if (url.scheme != 'https' or url.netloc != 'github.com' or url.username or url.password
            or url.query or url.fragment or not re.fullmatch(r'/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?', url.path)
            or not re.fullmatch(r'[0-9a-f]{40}', sha)):
        raise ValueError('expected public GitHub HTTPS URL and full lowercase SHA')
    return url.path.rstrip('/').removesuffix('.git').rsplit('/', 1)[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repository', default='https://github.com/InnoSquadCorp/InnoRouter.git')
    p.add_argument('--commit-sha', required=True)
    args = p.parse_args()
    identity = validate_identity(args.repository, args.commit_sha)
    root = Path(__file__).resolve().parent.parent
    (root / '.build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='exact-sha-consumer-', dir=root / '.build') as temp:
        consumer = Path(temp) / 'Consumer'
        shutil.copytree(root / 'ConsumerSmoke', consumer, ignore=shutil.ignore_patterns('.build', 'Package.resolved'))
        manifest = consumer / 'Package.swift'
        source = manifest.read_text()
        start = source.index('if let version =')
        end = source.index('\nlet package =', start)
        source = source[:start] + ('innoRouterDependency = .package(url: ' + json.dumps(args.repository)
                                   + ', revision: ' + json.dumps(args.commit_sha) + ')\n'
                                   + 'innoRouterPackage = ' + json.dumps(identity) + '\n') + source[end:]
        manifest.write_text(source)
        command = ['swift', 'package', '--package-path', str(consumer), 'resolve']
        subprocess.run(command, check=True)
        pins = json.loads((consumer / 'Package.resolved').read_text())['pins']
        matches = [pin for pin in pins if pin['identity'].casefold() == identity.casefold()]
        if len(matches) != 1 or matches[0]['state'].get('revision') != args.commit_sha:
            raise ValueError('consumer did not resolve the requested SHA')
        if matches[0].get('location', '').rstrip('/').removesuffix('.git').casefold() != args.repository.removesuffix('.git').casefold():
            raise ValueError('consumer resolved an unexpected repository')
        for command in (
                ['swift', 'build', '--target', 'InnoRouterMacroFirstExternalConsumer'],
                ['swift', 'test', '--no-parallel', '--filter', 'InnoRouterDeveloperToolsExternalConsumerTests']):
            subprocess.run(command + ['--package-path', str(consumer), '--jobs', '2'], check=True)
        print('Exact remote macro/three-product consumer passed at ' + args.commit_sha)


if __name__ == '__main__':
    main()
