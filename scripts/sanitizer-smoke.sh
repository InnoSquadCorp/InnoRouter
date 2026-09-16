#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KIND="${1:-}"
JOBS="${SWIFTPM_JOBS:-1}"

usage() {
  echo "Usage: ./scripts/sanitizer-smoke.sh <thread|address>" >&2
}

case "$KIND" in
  thread)
    swift_filter='EventBroadcasterTests|RouterStateMachineTests|RouterStoreTests|RouterSceneLifecycleTests|RouterSignpostTrackerTests|RouterTestStoreTests|RouterScenarioCaptureTests|RouterTwelfthReviewRegressionTests|RouterTwelfthReviewReplayTests|RouterThirteenthReviewRegressionTests|RouterFourteenthReviewRegressionTests|RouterFifteenthReviewRegressionTests|RouterSixteenthReviewRegressionTests|RouterEighteenthReviewRegressionTests|RouterNineteenthReviewRegressionTests|RouterNineteenthReviewDurableOrderingTests|RouterNineteenthReviewDurableMatrixTests|RouterNineteenthReviewRestorePhaseTests|RouterNineteenthReviewDurabilityFailureTests|RouterFeatureMappingTests|RouterPartialRestorationTests|RouterHistoryTests|RouterStateRestorationTests|RouterDeepLinkBehaviorTests|RouterLinkPipelineTests'
    ;;
  address)
    swift_filter='RouterLifecycleTests|RouterSceneLifecycleTests|RouterInspectorImportFuzzTests|RouterInspectorDiagnosticBundleTests|RouterInspectorTests|RouterInputFuzzTests|RouterStateMachineTests|RouterSignpostTrackerTests|RouterSnapshotTests|RouterScenarioCaptureTests|RouterTwelfthReviewRegressionTests|RouterTwelfthReviewReplayTests|RouterThirteenthReviewRegressionTests|RouterFourteenthReviewRegressionTests|RouterFifteenthReviewRegressionTests|RouterSixteenthReviewRegressionTests|RouterEighteenthReviewRegressionTests|RouterNineteenthReviewRegressionTests|RouterNineteenthReviewDurableOrderingTests|RouterNineteenthReviewDurableMatrixTests|RouterNineteenthReviewRestorePhaseTests|RouterNineteenthReviewDurabilityFailureTests|RouterFeatureMappingTests|RouterPartialRestorationTests|RouterHistoryTests|RouterStateRestorationTests|RouterLinkPipelineTests'
    ;;
  *)
    usage
    exit 2
    ;;
esac

cd "$ROOT_DIR"
echo "[sanitizer-smoke] Running $KIND sanitizer with filter: $swift_filter"
swift test \
  --sanitize="$KIND" \
  --jobs "$JOBS" \
  --no-parallel \
  --scratch-path ".build/sanitizers/$KIND" \
  --filter "$swift_filter"
