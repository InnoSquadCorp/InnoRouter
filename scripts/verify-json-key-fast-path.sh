#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Sources/InnoRouterCore/RouterJSONKeyDecoder.swift"
EVIDENCE="$ROOT_DIR/.build/json-key-fast-path"
mkdir -p "$EVIDENCE"
BACKUP="$(mktemp)"
cp "$SOURCE" "$BACKUP"
restore() { cp "$BACKUP" "$SOURCE"; rm -f "$BACKUP"; }
trap restore EXIT
# Recreate the prior Foundation-only algorithm behind the same helper signature.
# The regression must compile and fail for its intended cost, not a missing API.
cat > "$SOURCE" <<'SWIFT'
import Foundation
package enum RouterJSONKeyDecoder {
    package static func decode(
        _ bytes: ArraySlice<UInt8>, fallback: (Data) throws -> String
    ) rethrows -> String {
        return try fallback(Data(bytes))
    }
}
SWIFT
set +e
swift test --package-path "$ROOT_DIR" --jobs 2 --no-parallel \
  --filter RouterJSONKeyDecoderTests/plainASCIIKeysAvoidFoundation > "$EVIDENCE/reference.log" 2>&1
STATUS=$?
set -e
if [[ "$STATUS" -eq 0 ]] || ! grep -Fq 'ASCII key fast path invoked Foundation' "$EVIDENCE/reference.log"; then
  cat "$EVIDENCE/reference.log"
  echo 'Reference implementation did not fail at the intended key-decoding regression' >&2
  exit 1
fi
restore
trap - EXIT
swift test --package-path "$ROOT_DIR" --jobs 2 --no-parallel \
  --filter 'RouterJSONKeyDecoderTests|RouterJSONWorkContractTests|RouterLegacyRouteBytesPortableContractTests|RouterTransientPresentationPersistenceContractTests|RouterPersistenceWorkBudgetPortableContractTests' \
  2>&1 | tee "$EVIDENCE/optimized.log"
echo '[json-key-fast-path] Foundation-only regression failed as expected; optimized contracts passed'
