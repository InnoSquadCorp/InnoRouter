#!/usr/bin/env bash
set -euo pipefail

# Diagnostic replay only: the original sanitizer step must remain failed.
# Run after a completed failing test, never instead of the sanitizer gate.
kind="${1:?Usage: diagnose-sanitizer-failure.sh address}"
[[ "$kind" == address ]] || exit 2
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
log_dir=".build/sanitizer-logs"
mkdir -p "$log_dir"
swift_bin="$(xcrun --find swift)"
helper="$(dirname "$swift_bin")/../libexec/swift/pm/swiftpm-testing-helper"
asan_runtime="$(xcrun clang -print-file-name=libclang_rt.asan_osx_dynamic.dylib)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
frameworks="$platform/Developer/Library/Frameworks"
libraries="$platform/Developer/usr/lib:$(dirname "$swift_bin")/../lib/swift/macosx"
test_binary="$(find .build/sanitizers/address -type f \
  -path '*/InnoRouterPackageTests.xctest/Contents/MacOS/InnoRouterPackageTests' -print -quit)"
if [[ -z "$test_binary" ]]; then
  # Xcode 27's per-target runner is useful for validating this diagnostic locally.
  test_binary="$(find .build/sanitizers/address -type f \
    -path '*/InnoRouterTests.xctest/Contents/MacOS/InnoRouterTests' -print -quit)"
fi
[[ -n "$test_binary" && -x "$helper" && -f "$asan_runtime" ]]
filter="$(sed -n 's/^\[sanitizer-smoke\] Running address sanitizer with filter: //p' "$log_dir/address.log" | head -1)"
[[ -n "$filter" ]]

python3 - "$helper" "$test_binary" "$asan_runtime" "$filter" "$log_dir/address-lldb.log" "$frameworks" "$libraries" <<'PY'
import shlex
import subprocess
import sys

helper, binary, runtime, test_filter, log, frameworks, libraries = sys.argv[1:]
environment = " ".join(shlex.quote(value) for value in [
    "DYLD_INSERT_LIBRARIES=" + runtime,
    "DYLD_FRAMEWORK_PATH=" + frameworks,
    "DYLD_LIBRARY_PATH=" + libraries,
])
command = [
    "xcrun", "lldb", "--batch",
    "--one-line", "settings set target.env-vars " + environment,
    "--one-line", "run",
    "--one-line-on-crash", "thread backtrace all",
    "--one-line-on-crash", "image list -o -f",
    "--", helper, "--test-bundle-path", binary,
    "--no-parallel", "--filter", test_filter,
    "--testing-library", "swift-testing",
]
with open(log, "w", encoding="utf-8") as output:
    try:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=180)
        output.write(f"\n[diagnostic] lldb exit={result.returncode}\n")
    except subprocess.TimeoutExpired:
        output.write("\n[diagnostic] lldb replay timed out after 180 seconds\n")
        raise
PY
