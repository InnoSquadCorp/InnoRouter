# Snapshot key-decoding investigation

PR #71 failed the unchanged `snapshot_roundtrip_throughput` gate at
`81c30ba3cf6e6d347467fd5eb18ae834f93fc062`: 1479.798083 ms, then
1499.957041 ms on one unchanged-head retry, against 1300 ms. Each measurement
is the median of five release samples, each encoding/decoding 200 states with
500 routes. The other six canonical workloads passed. Runs and reports:

- https://github.com/InnoSquadCorp/InnoRouter/actions/runs/38041575369
- First job: 114182719000; retry: 114210143483

## Scope

Main `333ba033` (PR #70) was merged into this branch without conflicts. Its
native visionOS probe synchronization fix is separate from this optimization.

Source inspection found at least 2,500 isolated Foundation key decodes per
snapshot roundtrip: the 500 route keys pass encode preflight/admission and
decode preflight/transient screening/admission. These calls repeat for every
roundtrip. This is a cost hypothesis, not yet a measured attribution.

The candidate directly converts only quoted, unescaped ASCII keys without JSON control characters.
Escaped, Unicode and malformed candidates retain the existing Foundation path.
All existing work/key-decode reservations, error mapping, duplicate detection,
route byte spans, transient checks, and validation order remain in place.
No workload size, threshold, sampling count or admission budget changes.

## Verification

The performance script first substitutes the previous Foundation-only algorithm
behind the helper signature, requires the new regression to fail at its explicit
Foundation-invocation assertion, restores the real source, and runs the focused
key, work-budget, route-byte and transient-persistence contract suites. The source
backup is restored on failure as well. Do not run another SwiftPM process against
this checkout during that serialized harness.

The release executable reports five alternating same-process reference/optimized
scalar-key samples, with equal output and exact logical budget assertions. These
are attribution diagnostics; the original seven-workload gate remains unchanged.

Cloud checks passed: README parity and its 11 regressions, performance-report
validator scenarios, four skill-consumer-output regressions, shell syntax and
`git diff --check`. Swift/Xcode and native execution are unavailable in this Linux
workspace. Compiler, reference-failure proof, optimized contracts, A/B timings and
complete platform results must be obtained from CI for the published candidate.

## CI evidence and diagnostic isolation

At candidate `3fdbc5cf44fe3a5f23442f408960bc19c017fd32`, Apple CI established:

- Intended Foundation-only regression failure, followed by passing optimized contracts
- All seven canonical benchmarks passed; snapshot median **673.122458 ms**, unchanged 1300 ms limit
- Scalar 100,000-key A/B medians: Foundation **58.722375 ms**, optimized **3.813125 ms**
- https://github.com/InnoSquadCorp/InnoRouter/actions/runs/38080931254/job/114297505967

These timings belong to that exact candidate and are not a promise for later heads.
The A/B ratio describes scalar-key cost, not a predicted whole-snapshot speedup.

Review comment 4238983177 identified that attribution diagnostics preceded report
creation. They now run through separate `--profile-json-keys` process execution,
after the canonical report is saved and validated. Diagnostic failure produces a
warning without changing canonical success; a canonical failure still fails and
is never bypassed. Four synthetic orchestration regressions pass locally, including
a failed diagnostic, successful diagnostic, failed canonical workload, and separate
command dispatch. The unchanged key-regression harness remains mandatory.
