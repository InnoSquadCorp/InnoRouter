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
    swift_filter='EventBroadcasterTests|RouterStateMachineTests|RouterStoreTests|RouterSceneLifecycleTests|RouterSignpostTrackerTests|RouterTestStoreTests|RouterScenarioCaptureTests|RouterTwelfthReviewRegressionTests|RouterTwelfthReviewReplayTests|RouterThirteenthReviewRegressionTests|RouterFourteenthReviewRegressionTests|RouterFifteenthReviewRegressionTests|RouterSixteenthReviewRegressionTests|RouterEighteenthReviewRegressionTests|RouterNineteenthReviewRegressionTests|RouterNineteenthReviewDurableOrderingTests|RouterNineteenthReviewDurableMatrixTests|RouterNineteenthReviewRestorePhaseTests|RouterNineteenthReviewDurabilityFailureTests|RouterTwentySecondReviewRegressionTests|RouterFeatureMappingTests|RouterPartialRestorationTests|RouterHistoryTests|RouterStateRestorationTests|RouterDeepLinkBehaviorTests|RouterNineteenthReviewDeepLinkTests|RouterTwentySecondReviewDeepLinkTests|RouterLinkPipelineTests'
    ;;
  address)
    swift_filter='RouterLifecycleTests|RouterSceneLifecycleTests|RouterInspectorImportFuzzTests|RouterInspectorDiagnosticBundleTests|RouterInspectorTests|RouterInputFuzzTests|RouterStateMachineTests|RouterSignpostTrackerTests|RouterSnapshotTests|RouterScenarioCaptureTests|RouterTwelfthReviewRegressionTests|RouterTwelfthReviewReplayTests|RouterThirteenthReviewRegressionTests|RouterFourteenthReviewRegressionTests|RouterFifteenthReviewRegressionTests|RouterSixteenthReviewRegressionTests|RouterEighteenthReviewRegressionTests|RouterNineteenthReviewRegressionTests|RouterNineteenthReviewDurableOrderingTests|RouterNineteenthReviewDurableMatrixTests|RouterNineteenthReviewRestorePhaseTests|RouterNineteenthReviewDurabilityFailureTests|RouterTwentySecondReviewRegressionTests|RouterFeatureMappingTests|RouterPartialRestorationTests|RouterHistoryTests|RouterStateRestorationTests|RouterNineteenthReviewDeepLinkTests|RouterTwentySecondReviewDeepLinkTests|RouterLinkPipelineTests|RouterDeepLinkBehaviorTests'
    ;;
  *)
    usage
    exit 2
    ;;
esac

swift_filter+='|RouterTwentyThirdReviewDeepLinkTests|RouterTwentyThirdReviewRestorationTests|RouterTwentyThirdReviewTraversalBoundaryTests'
swift_filter+='|RouterTwentyFourthReviewRestorationTests'
swift_filter+='|RouterPublicationCleanupTests|RestorationLifetimeTests|MountedImmersiveLifetimeTests'
swift_filter+='|RouterInspectorTimelineTests'
# Tab and deep-link hosts drive restoration across the SwiftUI boundary, so
# both sanitizers must actually execute them (RBR-V1).
swift_filter+='|RouterTabHostTests|RouterDeepLinkHostTests|NativeHostRuntimeTests'
swift_filter+='|RouterRestorationBoundaryRegressionTests|RouterTabRestorationTopologyTests'
swift_filter+='|RouterTabRestorationSafetyTests|RouterRestoredTabHostTests'
swift_filter+='|RouterSnapshotLimitTests|RouterRestorationDriverPartialTests'

cd "$ROOT_DIR"
echo "[sanitizer-smoke] Running $KIND sanitizer with filter: $swift_filter"
swift test \
  --sanitize="$KIND" \
  --jobs "$JOBS" \
  --no-parallel \
  --scratch-path ".build/sanitizers/$KIND" \
  --filter "$swift_filter"
