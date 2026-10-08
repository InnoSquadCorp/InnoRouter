> Router publication: explicitly approved default-on trusted handler. INNO_MERGED_PR_CLEANUP unset/empty/enabled applies only exact merged-PR validation cleanup; other values use read-only inspection. No repository setting was changed.

# Merged-PR cleanup: approved trusted handler

`.github/workflows/merged-pr-cleanup.yml` and `merged_pr_cleanup.py` are reviewed changes for this draft PR. The handler becomes available only after a separately approved merge to the default branch.

The trusted `pull_request_target: closed` workflow requires a merged PR in this exact repository. It checks out the immutable trusted workflow SHA, never PR code, and loads only the reviewed executor, selector and allowlist. The explicitly approved default is cleanup: unset/empty or `INNO_MERGED_PR_CLEANUP=enabled` selects the separate job with `actions: write`. Any other value selects inspection with `actions: read`. The command-line executor still defaults to dry run unless the trusted job explicitly passes `--apply`. Both have `pull-requests: read` and `contents: read`, with no code-writing permission.

The executor verifies repository identity, default-branch workflow context and checkout SHA. It freshly fetches the merged PR and complete bounded paginated run inventory before writes. It selects only unfinished `pull_request` runs in the PR lifetime, with a sole native association to this repository and PR and an exact matching association/run head. Previous heads of this same PR are included. Missing associations or ambiguous identity fail closed. A rerun explicitly started after merge is preserved when its attempt/start-time evidence establishes that fact.

Main push, merge_group, manual/workflow_run events, release/publication/docs-publish, protected stateful workflows, other PRs, completed runs, and same-SHA other events remain excluded. The repository-specific `ci-cleanup-workflows.json` is an exact trusted allowlist.

Immediately before each cancellation the executor re-fetches the PR and run/attempt. Changed or completed candidates are skipped. A 409 is reconciled against fresh completed status; 403 is not retried. HTTP redirects are forbidden and response sizes are bounded. The only write endpoint is the selected run's `/cancel` endpoint.

GitHub's cancel API is run-ID based, not attempt-conditional. A rerun can begin between the final GET and POST; the API provides no atomic exclusion. Thus protection against simultaneous reruns is best-effort, not an absolute guarantee. This limit is exercised by mocked race tests and must be accepted during rollout review.

The workflow permission and default-on behavior were explicitly approved. Repository settings were not changed. Hosted cancellation must still be validated with real native API associations after an authorized merge; this draft PR is not permission to merge. Local mocked pagination, provenance, attempts, fork, forbidden-event, permission and race tests are not hosted cancellation evidence. No token is persisted in the prepared artifacts.
