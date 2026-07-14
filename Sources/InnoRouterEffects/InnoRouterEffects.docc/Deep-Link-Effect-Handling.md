# Deep-link effect handling

@Metadata {
  @PageKind(article)
}

`DeepLinkEffectHandler` turns a `DeepLinkDecision` into a typed execution result.

Important result shapes include:

- `.executed`
- `.executionFailed`
- `.applicationRejected`
- `.pending`
- `.rejected`
- `.unhandled`
- `.invalidURL`
- `.missingDeepLinkURL`
- `.noPendingDeepLink`

The handler keeps deep-link execution explicit:

- it does not hide pending replay
- it does not collapse rejection into generic failure
- it validates the produced `NavigationPlan` before execution and
  reports `.applicationRejected` when the current stack cannot apply it
- its flow counterpart preserves the authority's exact
  `FlowRejectionReason` in `.applicationRejected(plan:path:reason:)`
- it reports `.executionFailed` with the full batch when middleware or
  command execution prevents every step from succeeding
- it keeps batch execution payloads visible to the caller
- it keeps exactly one pending slot, replacing older deferred links with newer
  requests even when their URL and plan values are equal
- it lets callers drop the slot explicitly via `clearPendingDeepLink()`

Use `resumePendingDeepLinkIfAllowed` when auth state must be checked
asynchronously before replaying a stored plan. Its `rethrows` contract accepts
both nonthrowing authorization checks and token refresh or session probes that
can fail before a boolean authorization decision exists.

Pending replay uses request identity rather than value equality. If a new
equal-valued request arrives while the authorization closure is suspended, the
in-flight call returns that replacement as `.pending`; only a later replay may
consume it.
