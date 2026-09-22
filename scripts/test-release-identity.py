#!/usr/bin/env python3
"""Exercise release identity failures without changing the checkout."""

import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/InnoSquadCorp/InnoRouter.git"


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write_candidate("6.1.0", "ga")

    def write_candidate(self, version, channel):
        runtime = self.root / "Sources/InnoRouterCore/InnoRouterVersion.swift"
        runtime.parent.mkdir(parents=True, exist_ok=True)
        runtime.write_text(f'public enum InnoRouterVersion {{\n    public static let current = "{version}"\n}}\n')
        for name in ("README.md", "README.ko.md"):
            (self.root / name).write_text(f'.package(url: "{REPOSITORY}", from: "{version}")\n')
        notes = "## Unreleased\n\n"
        if channel == "ga":
            notes += f"## {version} - 2026-09-22\n\n"
        notes += "### Fixed\n\n- Preserves snapshots.\n\n## 6.0.0 - 2026-09-16\n\n### Added\n\n- Initial release.\n"
        (self.root / "CHANGELOG.md").write_text(notes)

    def check(self, version="6.1.0", channel="ga"):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/check-release-identity.sh"), version, channel, str(self.root)],
            capture_output=True, text=True, check=False,
        )

    def test_ga_and_prerelease_use_their_own_changelog_contract(self):
        for version, channel in (("6.1.0", "ga"), ("6.1.0-rc.1", "prerelease")):
            with self.subTest(channel=channel):
                self.write_candidate(version, channel)
                result = self.check(version, channel)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_runtime_mismatch_is_rejected_even_with_a_valid_release_cut(self):
        path = self.root / "Sources/InnoRouterCore/InnoRouterVersion.swift"
        path.write_text(path.read_text().replace("6.1.0", "6.0.0"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime", result.stdout + result.stderr)

    def test_each_installation_readme_must_match(self):
        for name in ("README.md", "README.ko.md"):
            with self.subTest(readme=name):
                self.write_candidate("6.1.0", "ga")
                (self.root / name).write_text('from: "6.0.0"\n')
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stdout + result.stderr)

    def test_missing_or_ambiguous_runtime_is_rejected(self):
        path = self.root / "Sources/InnoRouterCore/InnoRouterVersion.swift"
        for source in ("", 'public static let current = "6.1.0"\n' * 2):
            with self.subTest(source=source):
                path.write_text(source)
                self.assertNotEqual(self.check().returncode, 0)

    def test_installation_version_cannot_be_borrowed_or_conflicted(self):
        current = f'.package(url: "{REPOSITORY}", from: "6.1.0")\n'
        stale = f'.package(url: "{REPOSITORY}", from: "6.0.0")\n'
        unrelated = '.package(url: "https://example.test/other", from: "6.1.0")\n'
        branch = f'.package(url: "{REPOSITORY}", branch: "main")\n'
        for name in ("README.md", "README.ko.md"):
            for declarations in (stale + unrelated, current + stale, current * 2, current + branch, unrelated):
                with self.subTest(readme=name, declarations=declarations):
                    self.write_candidate("6.1.0", "ga")
                    (self.root / name).write_text(declarations)
                    result = self.check()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stdout + result.stderr)

    def test_multiline_installation_and_optional_git_suffix(self):
        for name in ("README.md", "README.ko.md"):
            (self.root / name).write_text(
                '.package(\n    url: "https://github.com/InnoSquadCorp/InnoRouter",\n'
                '    from: "6.1.0"\n)\n'
            )
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ga_rejects_uncut_notes(self):
        self.write_candidate("6.1.0", "prerelease")
        self.assertNotEqual(self.check().returncode, 0)

    def test_prerelease_rejects_a_published_ga_section(self):
        self.write_candidate("6.1.0-rc.1", "prerelease")
        with (self.root / "CHANGELOG.md").open("a") as file:
            file.write("\n## 6.1.0 - 2026-09-22\n\n- Already cut.\n")
        self.assertNotEqual(self.check("6.1.0-rc.1", "prerelease").returncode, 0)

    def test_invalid_version_and_channel_fail_closed(self):
        for version, channel in (("v6.1.0", "ga"), ("6.1.0", "unknown"), ("6.1.0-rc.1", "ga")):
            with self.subTest(version=version, channel=channel):
                self.assertNotEqual(self.check(version, channel).returncode, 0)

    def test_publishing_gate_receives_candidate_identity(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = re.search(r"      - name: Run Principle Gates\n(.*?)(?=\n      - name:)", workflow, re.S)
        self.assertIsNotNone(step)
        self.assertIn("RELEASE_VERSION: ${{ needs.preflight.outputs.version }}", step[1])
        self.assertIn("RELEASE_CHANNEL:", step[1])
        self.assertIn("needs.preflight.outputs.prerelease", step[1])

    def test_exact_consumer_revision(self):
        path = self.root / "Package.resolved"
        for pins, expected in (
            ([{"identity": "innorouter", "state": {"version": "6.1.0", "revision": "abc"}}], 0),
            ([{"identity": "innorouter", "state": {"version": "6.0.0", "revision": "abc"}}], 1),
            ([{"identity": "innorouter", "state": {"version": "6.1.0", "revision": "def"}}], 1),
            ([], 1),
        ):
            with self.subTest(pins=pins):
                for pin in pins:
                    pin["location"] = REPOSITORY
                path.write_text(json.dumps({"pins": pins}))
                result = subprocess.run(
                    ["python3", str(ROOT / "scripts/check-consumer-resolution.py"), str(path), "6.1.0", "abc", REPOSITORY],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_consumer_repository_identity_with_and_without_expected_revision(self):
        path = self.root / "Package.resolved"
        for location, accepted in (
            (REPOSITORY, True),
            (REPOSITORY.removesuffix(".git"), True),
            (REPOSITORY + "/", True),
            ("https://example.test/foreign/innorouter.git", False),
            ("https://github.com/Other/InnoRouter.git", False),
            (REPOSITORY + "?redirect=other", False),
            (None, False),
        ):
            for revision in ("", "abc"):
                with self.subTest(location=location, revision=revision):
                    pin = {"identity": "innorouter", "location": location,
                           "state": {"version": "6.1.0", "revision": "abc"}}
                    path.write_text(json.dumps({"pins": [pin]}))
                    result = subprocess.run(
                        ["python3", str(ROOT / "scripts/check-consumer-resolution.py"), str(path), "6.1.0", revision, REPOSITORY],
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_ga_publishing_checks_the_resolved_commit(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = re.search(r"      - name: Verify exact GA package dependency\n(.*?)(?=\n      - name:)", workflow, re.S)
        self.assertIsNotNone(step)
        self.assertIn("INNOROUTER_CONSUMER_REVISION: ${{ needs.preflight.outputs.commit_sha }}", step[1])
        self.assertIn('./scripts/external-consumer-smoke.sh "$RELEASE_VERSION"', step[1])


if __name__ == "__main__":
    unittest.main()
