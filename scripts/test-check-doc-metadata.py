#!/usr/bin/env python3
"""Exercise the production checker with complete isolated document fixtures."""
import pathlib
import subprocess
import tempfile
import unittest

CHECKER = pathlib.Path(__file__).with_name("check-doc-metadata.py")
SHA = "f6abef8ee77677c48b32563aac2efaa82100b132"


class MetadataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="innorouter-doc-metadata-")
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.english = (
            "- Document status: Draft; approval not recorded\n"
            "- Implementation state: Implemented\n- Publication status: Published\n"
            f"- Published version: 6.0.0\n- Published commit: {SHA}\n- Published date: 2026-09-16\n"
        )
        self.korean = (
            "| 문서 상태 | Draft |\n| 구현 상태 | 구현 완료 |\n| 배포 상태 | 배포 완료 |\n"
            f"| 배포 버전 | 6.0.0 |\n| 배포 커밋 | {SHA} |\n| 배포일 | 2026-09-16 |\n"
        )
        self.write("Docs/v6-functional-strategy.md", self.english)
        self.write("Docs/functional-expansion-spec.md", self.english)
        self.write("Docs/6.0.0-next-capabilities-spec.ko.md", self.korean)
        self.write("Docs/v6-public-api-boundary.md", "| `InnoRouter` | 1,156 |\n")
        self.write("Baselines/PublicAPI/symbol-budgets.tsv", "InnoRouter\t1156\n")

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def check(self, accepted):
        result = subprocess.run(["python3", str(CHECKER), str(self.root)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_valid_published_lifecycle_and_versions(self):
        for version in ("6.0.1", "6.1.0", "6.1.0-rc.1", "6.1.0+build.2"):
            with self.subTest(version=version):
                self.write("Docs/v6-functional-strategy.md", self.english.replace("6.0.0", version))
                self.check(True)

    def test_negations_and_future_claims_are_not_status_values(self):
        for value in ("not published in 6.0.0", "will be published in 6.1.0", "unpublished",
                      "Published soon", "Published; Unpublished", ""):
            with self.subTest(value=value):
                self.write("Docs/v6-functional-strategy.md", self.english.replace(
                    "Publication status: Published", "Publication status: " + value))
                self.check(False)

    def test_korean_negations_are_not_status_values(self):
        for value in ("배포 완료 아님", "배포 예정", "아직 배포 완료하지 않음"):
            with self.subTest(value=value):
                self.write("Docs/6.0.0-next-capabilities-spec.ko.md", self.korean.replace(
                    "배포 상태 | 배포 완료", "배포 상태 | " + value))
                self.check(False)

    def test_unpublished_is_valid_without_release_metadata(self):
        for implementation in ("Implemented", "Partial", "Not started"):
            self.write("Docs/v6-functional-strategy.md",
                       f"- Document status: Draft\n- Implementation state: {implementation}\n"
                       "- Publication status: Unpublished\n")
            self.check(True)
        self.write("Docs/6.0.0-next-capabilities-spec.ko.md",
                   "| 문서 상태 | Reviewed |\n| 구현 상태 | 부분 구현 |\n| 배포 상태 | 미배포 |\n")
        self.check(True)

    def test_contradictory_or_missing_fields_are_rejected(self):
        fixtures = [
            self.english + "- Document status: Invalid\n",
            self.english + "- Implementation status: Partial\n",
            self.english + "- Publication status: Unpublished\n",
            self.english.replace("Publication status: Published", "Publication status: Unpublished"),
            self.english.replace("Implementation state: Implemented", "Implementation state: Partial"),
        ]
        fixtures += ["\n".join(line for line in self.english.splitlines() if not line.startswith(prefix))
                     for prefix in ("- Publication status:", "- Published version:",
                                    "- Published commit:", "- Published date:")]
        for text in fixtures:
            with self.subTest(text=text):
                self.write("Docs/v6-functional-strategy.md", text)
                self.check(False)

    def test_invalid_release_values(self):
        for original, invalid in (("6.0.0", "6.1.0-.."), ("6.0.0", "6.01.0"),
                                  ("6.0.0", "6.1.0-01"), ("2026-09-16", "2026-02-30"),
                                  (SHA, "short-sha")):
            with self.subTest(invalid=invalid):
                self.write("Docs/v6-functional-strategy.md", self.english.replace(original, invalid))
                self.check(False)

    def test_budget_drift_and_duplicates(self):
        for text in ("InnoRouter\t933\n", "InnoRouter\t1156\nInnoRouter\t1156\n"):
            self.write("Baselines/PublicAPI/symbol-budgets.tsv", text)
            self.check(False)


if __name__ == "__main__":
    unittest.main()
