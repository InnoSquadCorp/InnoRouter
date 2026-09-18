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

echo "[test-doc-metadata] Metadata consistency scenarios passed"
