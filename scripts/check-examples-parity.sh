#!/usr/bin/env bash
# scripts/check-examples-parity.sh
#
# Examples↔ExamplesSmoke parity gate.
#
# - Every `Examples/<Name>Example.swift` MUST have a matching
#   `ExamplesSmoke/<Name>Smoke.swift`. The smoke is the
#   compiler-stable mirror of the human-facing example, so a
#   missing pair means a feature has documentation without a CI
#   build gate.
#
# - Smoke files that are not mirrors of an example are allowed
#   (e.g. `ModalSmoke.swift`, `MacrosSmoke.swift` exercise
#   surface that has no narrative example yet). They live in the
#   allowlist below; anything else without a matching example
#   fails the gate.
#
# - `Package.swift` MUST declare a target for every example file
#   and every solo smoke. `scripts/principle-gates.sh` MUST build
#   every human-facing example target. Hand-edits to `Examples/` or
#   `ExamplesSmoke/` that forget the manifest / gate update get
#   caught here, before they reach release CI.
#
# Exits non-zero on any drift; prints every violation it finds
# (does not stop on the first one) so a single run reports the
# full delta.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

EXAMPLES_DIR="Examples"
SMOKE_DIR="ExamplesSmoke"
MANIFEST="Package.swift"
PRINCIPLE_GATES="scripts/principle-gates.sh"

# Smoke files that intentionally have no Examples/ counterpart.
# Keep this list short — the default expectation is one-to-one.
SMOKE_ONLY_ALLOWLIST=(
    "MacrosSmoke.swift"
    "ModalSmoke.swift"
)

errors=0
missing_required_file=0

report() {
    echo "❌ $*" >&2
    errors=$((errors + 1))
}

contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

require_readable_file() {
    local path="$1"
    local description="$2"
    if [[ ! -r "$path" ]]; then
        report "$description is required at $path and must be readable"
        missing_required_file=1
    fi
}

# Collect Example basenames: "Standalone", "Coordinator", ...
example_bases=()
for path in "$EXAMPLES_DIR"/*Example.swift; do
    [[ -e "$path" ]] || continue
    file="$(basename "$path")"
    base="${file%Example.swift}"
    example_bases+=("$base")
done

# Collect Smoke basenames: "Standalone", "Coordinator", ...
smoke_bases=()
smoke_files=()
for path in "$SMOKE_DIR"/*Smoke.swift; do
    [[ -e "$path" ]] || continue
    file="$(basename "$path")"
    smoke_files+=("$file")
    base="${file%Smoke.swift}"
    smoke_bases+=("$base")
done

# 1) Every Example must have a matching Smoke.
for base in "${example_bases[@]}"; do
    if ! contains "$base" "${smoke_bases[@]}"; then
        report "$EXAMPLES_DIR/${base}Example.swift has no matching $SMOKE_DIR/${base}Smoke.swift"
    fi
done

# 2) Every Smoke must either match an Example or be allowlisted.
for file in "${smoke_files[@]}"; do
    base="${file%Smoke.swift}"
    if contains "$base" "${example_bases[@]}"; then
        continue
    fi
    if contains "$file" "${SMOKE_ONLY_ALLOWLIST[@]}"; then
        continue
    fi
    report "$SMOKE_DIR/$file has no matching $EXAMPLES_DIR/${base}Example.swift (and is not in SMOKE_ONLY_ALLOWLIST)"
done

# The macro-first smoke is a product-contract fixture, not just a source
# example: it must compile after importing only the default umbrella and its
# dedicated one-dependency target must stay in the main gate.
macro_smoke="$SMOKE_DIR/MacrosSmoke.swift"
if [[ -r "$macro_smoke" ]]; then
    if ! grep -qx 'import InnoRouter' "$macro_smoke"; then
        report "$macro_smoke must import the default InnoRouter umbrella"
    fi
    if grep -Eq '^import InnoRouterMacros$' "$macro_smoke"; then
        report "$macro_smoke must not depend on a second InnoRouterMacros import"
    fi
    if ! grep -q '@Router' "$macro_smoke"; then
        report "$macro_smoke must expand @Router through the default umbrella"
    fi
    macro_first_tokens=(
        '@EnvironmentRouter'
        '@DeepLink'
        '@TabItem'
        'RouterHost('
        'RouterModalHost('
        'RouterSplitHost('
        'RouterTabHost('
        'resolveDeepLink('
    )
    for token in "${macro_first_tokens[@]}"; do
        if ! grep -Fq "$token" "$macro_smoke"; then
            report "$macro_smoke must exercise the macro-first surface $token"
        fi
    done
fi

# 3) Manifest must reference every example source and every smoke source.
#    The main gate must also build every human-facing example target.
require_readable_file "$MANIFEST" "Swift package manifest"
require_readable_file "$PRINCIPLE_GATES" "principle gates script"
if (( missing_required_file > 0 )); then
    echo "" >&2
    echo "Examples↔ExamplesSmoke parity gate failed with $errors violation(s)." >&2
    exit 1
fi
for base in "${example_bases[@]}"; do
    src="${base}Example.swift"
    target="InnoRouter${base}Example"
    if ! grep -q "\"$src\"" "$MANIFEST"; then
        report "$MANIFEST does not reference $EXAMPLES_DIR/$src"
    fi
    if ! grep -q "name: \"$target\"" "$MANIFEST"; then
        report "$MANIFEST does not declare target $target for $EXAMPLES_DIR/$src"
    fi
    if ! grep -Eq -- "--target[[:space:]]+$target([[:space:]]|$)" "$PRINCIPLE_GATES"; then
        report "$PRINCIPLE_GATES does not build $target"
    fi
done

for file in "${smoke_files[@]}"; do
    if ! grep -q "\"$file\"" "$MANIFEST"; then
        report "$MANIFEST does not reference $SMOKE_DIR/$file"
    fi
done


if ! grep -q 'soloSmokeTarget(name: "InnoRouterMacroFirstSmoke",[[:space:]]*source: "MacrosSmoke.swift")' "$MANIFEST"; then
    report "$MANIFEST must keep MacrosSmoke.swift in the dedicated one-dependency InnoRouterMacroFirstSmoke target"
fi
if ! grep -Eq -- '--target[[:space:]]+InnoRouterMacroFirstSmoke([[:space:]]|$)' "$PRINCIPLE_GATES"; then
    report "$PRINCIPLE_GATES does not build InnoRouterMacroFirstSmoke"
fi

# The spatial smoke is a second product-contract fixture. It must prove that
# importing only InnoRouterSpatial exposes the scene macros, generated runtime,
# and route-aware environment actions used by the generated scene tree.
spatial_smoke="$SMOKE_DIR/VisionOSImmersiveSmoke.swift"
if [[ -r "$spatial_smoke" ]]; then
    if ! grep -qx 'import InnoRouterSpatial' "$spatial_smoke"; then
        report "$spatial_smoke must import InnoRouterSpatial"
    fi
    if grep -Eq '^import InnoRouter$' "$spatial_smoke"; then
        report "$spatial_smoke must not depend on the InnoRouter umbrella"
    fi
    if ! grep -q '@SceneRouter' "$spatial_smoke"; then
        report "$spatial_smoke must expand @SceneRouter through InnoRouterSpatial"
    fi
    if ! grep -q '\.scenes' "$spatial_smoke"; then
        report "$spatial_smoke must consume the scene tree generated by @SceneRouter"
    fi
    spatial_action_tokens=(
        '@EnvironmentSceneRouter'
        '.open('
        '.dismissWindow('
        '.dismissImmersive('
    )
    for token in "${spatial_action_tokens[@]}"; do
        if ! grep -Fq "$token" "$spatial_smoke"; then
            report "$spatial_smoke must exercise the macro-first spatial action $token"
        fi
    done
fi

if ! grep -q 'name: "InnoRouterSpatialConsumerSmoke"' "$MANIFEST"; then
    report "$MANIFEST must declare the one-dependency InnoRouterSpatialConsumerSmoke target"
fi
if ! grep -q 'source: "VisionOSImmersiveSmoke.swift"' "$MANIFEST"; then
    report "$MANIFEST must keep VisionOSImmersiveSmoke.swift in the dedicated spatial consumer target"
fi
if ! grep -q -- '-scheme InnoRouterSpatialConsumerSmoke' "$PRINCIPLE_GATES"; then
    report "$PRINCIPLE_GATES does not build InnoRouterSpatialConsumerSmoke for visionOS"
fi

if (( errors > 0 )); then
    echo "" >&2
    echo "Examples↔ExamplesSmoke parity gate failed with $errors violation(s)." >&2
    exit 1
fi

echo "✅ Examples↔ExamplesSmoke parity OK (${#example_bases[@]} examples, ${#smoke_files[@]} smokes)"
