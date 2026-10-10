#!/usr/bin/env python3
"""Static README contract/parity checks; this does not typecheck Swift or render DocC."""
from pathlib import Path
import argparse
import re
import sys

LANGUAGES = ('en', 'ko', 'es', 'de', 'zh-Hans', 'ja', 'ru')
FILES = tuple('README.md' if language == 'en' else f'README.{language}.md' for language in LANGUAGES)
SYMBOLS = (
    'RouterFeatureHost', 'FeatureRoute',
    'RouterStateDraft', 'RouterPlan', 'RouterAction', 'RouterStore', 'RouterScope',
    'EnvironmentRouterState', 'RouterOutcome', 'RouterRequestKey', 'RouterRejectionReason',
    'RouterTabHost', 'RouterSplitHost', 'RouterThreeColumnSplitHost', 'RouterTabCatalog',
    'RouterLinkPipeline', 'RouterPendingLinkSlot', 'RouterPendingLinkPersistenceDriver',
    'RouterRestorationDriver', 'RouterSnapshotCodec', 'RouterTabRestorationTopology',
    'RouterHistory', 'RouterSceneDriver', 'RouterImmersiveSpaceScene',
    'RouterPlatformCapabilities', 'RouterUIKitBridge', 'RouterAppKitBridge',
    'RouterOpenURLIntentBuilder', 'RouterShortcutCatalog', 'RouterTestStore',
    'RouterActionSequence', 'RouterInspectorRecorder', 'RouterObservability',
    'RouterScenarioRecorder', 'RouterScenarioRunner', 'RouterScenarioSourceGenerator',
)
FENCES = re.compile(r'^```swift ([^\n]+)\n(.*?)^```\s*$', re.M | re.S)
LINKS = re.compile(r'\]\(([^\s)]+)\)')


def check(root: Path) -> list[str]:
    errors: list[str] = []
    source = '\n'.join(path.read_text() for path in (root / 'Sources').rglob('*.swift'))
    version_source = (root / 'Sources/InnoRouterCore/InnoRouterVersion.swift').read_text()
    version = re.search(r'public static let current = "([^"]+)"', version_source).group(1)
    fixture_source = (root / 'Sources/InnoRouterTesting/RouterScenarioFixture.swift').read_text()
    fixture = re.search(r'currentFormatVersion: Int \{ (\d+) \}', fixture_source).group(1)
    expected_blocks = None
    for filename in FILES:
        path = root / filename
        if not path.is_file():
            errors.append(f'{filename}: missing current translation')
            continue
        text = path.read_text()
        if len(re.findall(r'^## ', text, re.M)) != 13:
            errors.append(f'{filename}: expected 13 aligned sections')
        blocks = FENCES.findall(text)
        if len(blocks) != 6 or sum(mode == 'compile' for mode, _ in blocks) != 2:
            errors.append(f'{filename}: expected six annotated Swift blocks, two standalone')
        if expected_blocks is None:
            expected_blocks = blocks
        elif blocks != expected_blocks:
            errors.append(f'{filename}: Swift snippets differ from English')
        required = (
            f'from: "{version}"', f'exact: "{version}"', 'Swift 6.3+',
            '.product(name: "InnoRouter", package: "InnoRouter")',
            'iOS / iPadOS / Mac Catalyst 18+', 'macOS 15+', 'tvOS 18+', 'watchOS 11+', 'visionOS 2+',
            f'/releases/tag/{version}', f'v{fixture}', 'Docs/Archive/README-translations.md',
            'Docs/inspector-localization.md', '--no-parallel',
            'Migrating-To-InnoRouter-7.md', 'Migrating-To-InnoRouter-6.md',
            'Docs/Navigation-Guide.md', 'Docs/Navigation-Guide.ko.md',
            'validationFailure', 'replaceHost(with:descriptor:context:)',
            'keepFirst', 'replacePending', 'deferRequest', 'reset(sessionKey:)',
            '8 MiB', '.preserveDormant', 'routerStateRestoration(_:)',
        ) + FILES + SYMBOLS
        for literal in required:
            if literal not in text:
                errors.append(f'{filename}: missing contract {literal}')
        for mode, _ in blocks:
            if mode != 'compile' and not mode.startswith('skip '):
                errors.append(f'{filename}: invalid Swift fence annotation {mode}')
    for symbol in SYMBOLS:
        if not re.search(r'\b' + re.escape(symbol) + r'\b', source):
            errors.append(f'No source evidence for {symbol}')
    archive = root / 'Docs/Archive/README-translations.md'
    if not archive.is_file():
        errors.append('Missing historical translation index')
    else:
        archive_text = archive.read_text()
        for filename in FILES:
            if f'/blob/5.2.1/{filename}' not in archive_text:
                errors.append(f'Historical translation link missing: {filename}')
    paths = [root / name for name in FILES] + [archive] + list((root / 'Docs').glob('Navigation-Guide*.md'))
    for path in paths:
        if not path.is_file():
            continue
        for target in LINKS.findall(path.read_text()):
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target) or target.startswith('#'):
                continue
            target = target.split('#', 1)[0]
            if target and not (path.parent / target).exists():
                errors.append(f'{path.relative_to(root)}: broken local link {target}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    errors = check(args.root)
    if errors:
        for error in errors:
            print(f'[readme-translations] {error}', file=sys.stderr)
        return 1
    print('[readme-translations] seven languages, six shared Swift blocks, 13 sections, source symbols and local links pass (static only)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
