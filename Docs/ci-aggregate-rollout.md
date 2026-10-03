# CI aggregate rollout

The default remains transition mode until the new fixed-name metadata gate is
merged and a full aggregate dispatch passes on the current main commit. A PR
must retain the existing required contexts until that evidence exists.

The transition bridge waits up to 330 minutes within a 360-minute job budget,
including macOS runner queue time. Polling backs off from 15 to 120 seconds;
the latest failed or cancelled workflow rejects the gate even when another
workflow remains queued. PR/head/base changes and incomplete proof still fail.
This temporary polling job is bypassed after aggregate activation, when GitHub
waits for child jobs through native `needs` dependencies without an idle runner.
Aggregate and metadata gates retain a separate 10-minute timeout.

GitHub may include the API-created `Dependabot Merge Ready` check in a native
workflow's jobs response. The bridge, coordinator and metadata validators
separate it only after verifying the Actions app, PR/head, suite, external ID
and API-created check URL. Its verdict remains independently required; it
cannot substitute for a missing, failed or skipped native validation job.

After merging this change:

1. Dispatch `ci.yml` on `main` without a Dependabot recovery input. Manual
   dispatch always enables every aggregate gate, regardless of the variable.
2. Wait for that exact run to succeed. Preview the settings with
   `python3 scripts/rollout-ci-aggregate.py --run-id RUN_ID`.
3. Apply the reviewed transition with the same command plus `--apply`.
   The tool verifies the native full-validation check and rechecks main/run and
   ruleset identity. It preserves all unrelated rules and strictness, changes
   required contexts to GitHub Actions `CI Required` and `Dependabot Merge Ready`, then sets
   `INNOROUTER_CI_AGGREGATE=true`. If setting the variable fails, the required
   aggregate still verifies all legacy checks in transition mode; rerun after
   resolving the error. Do not enable the variable first.
4. Verify a source PR (all gates), a documentation PR (policy/docs only), a
   normal label/body edit (only the existing-evidence gate), and a base edit
   (fresh validation). Skipped legacy workflows should consume no runner.

Do not infer rollout completion from a merged PR or a successful transition
run. The repository settings are not changed by this PR. To roll back, set the
variable to `false` first, run and verify fresh legacy checks, then restore the
saved required contexts if necessary. Never remove `CI Required` before the
replacement checks are available.
