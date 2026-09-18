#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOC_METADATA_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-doc-metadata.XXXXXX")"
trap 'rm -rf "$DOC_METADATA_FIXTURE_DIR"' EXIT

mkdir -p "$DOC_METADATA_FIXTURE_DIR/Docs" "$DOC_METADATA_FIXTURE_DIR/Baselines/PublicAPI"

write_valid_fixture() {
  cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-functional-strategy.md" <<'EOF'
- Document status: Draft; approval missing
- Implementation state: published in 6.0.0
EOF
  cat >"$DOC_METADATA_FIXTURE_DIR/Docs/functional-expansion-spec.md" <<'EOF'
- Document status: Reviewed
- Implementation status: published in 6.0.0
EOF
  cat >"$DOC_METADATA_FIXTURE_DIR/Docs/6.0.0-next-capabilities-spec.ko.md" <<'EOF'
| 문서 상태 | Approved |
| 구현 상태 | 6.0.0 배포 완료 |
EOF
  cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-public-api-boundary.md" <<'EOF'
| Product | Maximum symbols |
| --- | ---: |
| `InnoRouter` | 1,156 |
| `InnoRouterInspector` | 207 |
| `InnoRouterTesting` | 250 |
EOF
  cat >"$DOC_METADATA_FIXTURE_DIR/Baselines/PublicAPI/symbol-budgets.tsv" <<'EOF'
# product<TAB>maximum public symbols
InnoRouter	1156
InnoRouterInspector	207
InnoRouterTesting	250
EOF
}

write_valid_fixture
python3 "$ROOT_DIR/scripts/check-doc-metadata.py" "$DOC_METADATA_FIXTURE_DIR" >/dev/null

cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-public-api-boundary.md" <<'EOF'
| Product | Maximum symbols |
| --- | ---: |
| `InnoRouter` | 933 |
| `InnoRouterInspector` | 207 |
| `InnoRouterTesting` | 250 |
EOF
if python3 "$ROOT_DIR/scripts/check-doc-metadata.py" "$DOC_METADATA_FIXTURE_DIR" >/dev/null 2>&1; then
  echo "[test-doc-metadata] Failed: API budget drift was accepted" >&2
  exit 1
fi

write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-functional-strategy.md" <<'EOF'
- Status: Draft
- Implementation state: published in 6.0.0
EOF
if python3 "$ROOT_DIR/scripts/check-doc-metadata.py" "$DOC_METADATA_FIXTURE_DIR" >/dev/null 2>&1; then
  echo "[test-doc-metadata] Failed: ambiguous lifecycle metadata was accepted" >&2
  exit 1
fi

expect_rejected() {
  if python3 "$ROOT_DIR/scripts/check-doc-metadata.py" "$DOC_METADATA_FIXTURE_DIR" >/dev/null 2>&1; then
    echo "[test-doc-metadata] Failed: $1" >&2
    exit 1
  fi
}

expect_accepted() {
  if ! python3 "$ROOT_DIR/scripts/check-doc-metadata.py" "$DOC_METADATA_FIXTURE_DIR" >/dev/null 2>&1; then
    echo "[test-doc-metadata] Failed: $1" >&2
    exit 1
  fi
}

# An unpublished implementation must not satisfy a publication check. A
# substring test accepted it, because "unpublished" contains "published".
write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-functional-strategy.md" <<'EOF'
- Document status: Draft
- Implementation state: unpublished as of 6.0.0
EOF
expect_rejected "an unpublished implementation was accepted as published"

# The same word inside a longer claim is still a negation.
write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/functional-expansion-spec.md" <<'EOF'
- Document status: Reviewed
- Implementation status: FR6-001-053 unpublished
EOF
expect_rejected "a negated publication claim was accepted"

# Publication must name the version it happened in.
write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-functional-strategy.md" <<'EOF'
- Document status: Draft
- Implementation state: published
EOF
expect_rejected "a versionless publication claim was accepted"

# Contradictory duplicate fields are ambiguous, not permissive.
write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-functional-strategy.md" <<'EOF'
- Document status: Draft
- Implementation state: published in 6.0.0
- Implementation status: unpublished
EOF
expect_rejected "contradictory duplicate implementation states were accepted"

write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/functional-expansion-spec.md" <<'EOF'
- Document status: Reviewed
- Document status: Draft
- Implementation status: published in 6.0.0
EOF
expect_rejected "duplicate document statuses were accepted"

# The Korean capability row has the same negation and version requirements.
write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/6.0.0-next-capabilities-spec.ko.md" <<'EOF'
| 문서 상태 | Approved |
| 구현 상태 | 6.1.0 미배포 |
EOF
expect_rejected "an undeployed capability implementation was accepted as deployed"

write_valid_fixture
cat >"$DOC_METADATA_FIXTURE_DIR/Docs/6.0.0-next-capabilities-spec.ko.md" <<'EOF'
| 문서 상태 | Approved |
| 구현 상태 | 배포 완료 |
EOF
expect_rejected "a versionless deployment claim was accepted"

# Valid lifecycle combinations must keep passing, including a patch, a minor,
# and a prerelease candidate.
for version in 6.0.1 6.1.0 6.1.0-rc.1; do
  write_valid_fixture
  cat >"$DOC_METADATA_FIXTURE_DIR/Docs/v6-functional-strategy.md" <<EOF
- Document status: Draft; approval missing
- Implementation state: published in $version
EOF
  cat >"$DOC_METADATA_FIXTURE_DIR/Docs/6.0.0-next-capabilities-spec.ko.md" <<EOF
| 문서 상태 | Approved |
| 구현 상태 | $version 배포 완료 |
EOF
  expect_accepted "a valid $version lifecycle was rejected"
done

write_valid_fixture
expect_accepted "the valid baseline fixture was rejected"

echo "[test-doc-metadata] Metadata consistency scenarios passed"
