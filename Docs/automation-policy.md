# CI, release candidates, dependencies, and public operations

This repository-local policy adapts InnoDI PR #44's immutable head
`356589ef82ef36d1bfd645169cb1762a7a483e56` (merged as
`4ae50bc58fd19bd10ea673244699fcfd30b79f68`) to InnoRouter's existing gates.
It does not change the runtime API, MIT license, security support, or contact promises.

## Validation contract

`CI` always creates **CI Plan** and **CI Required** on PR opened, synchronize,
reopened, label/unlabel and ready events, main/develop pushes, manual validation,
and merge queue `checks_requested`. There are no workflow-level path filters.
The exact Git merge-base diff uses NUL-delimited name/status output, includes
both rename/copy paths and deleted paths, and fails on missing anchors or malformed
input. Unknown paths, root manifests/locks, shared scripts and empty diffs select
all gates. Main, manual, merge queue, `release-validation`, and API-identified
Dependabot PRs always select every gate. Missing labels do not weaken bot validation.

| Changed path on an ordinary PR | Selected checks (policy always runs) |
| --- | --- |
| README, ordinary Markdown, Docs | Documentation consistency and compiled code blocks |
| DocC catalogs, `.spi.yml`, DocC builder | Documentation contracts and DocC site |
| Dependabot, issue/PR templates, LICENSE, SECURITY | Public operations and policy |
| Runtime, macro, test, example | Existing principle gates (full Swift/macro/restoration tests, public API, source lint, generated and local external consumers), documentation, DocC |
| ConsumerSmoke, NativeSceneSmoke | Principle gates, all platform/Inspector/native scene checks, exact-SHA external consumer |
| Historical MigrationSmoke | Existing 5.2.1/current migration comparison |
| Individual reusable workflow | Its affected gates; principle workflow also selects docs/DocC |
| CI/release orchestration, common scripts, manifest/lock, unknown | Every gate |

The result evaluator declares every dependency exactly once. Selected jobs must
succeed; only explicitly unselected jobs may skip. Missing/unknown results,
failure, cancellation, malformed plans and unexpected skips fail closed.
`always()` preserves the aggregate after failed or skipped dependencies.
Platforms Required and Sanitizers Required require every matrix; matrices retain
`fail-fast: false` with no `continue-on-error`. PR code runs with read-only
contents access and non-persisted checkout credentials. OIDC exists only in the
main-push Codecov upload job, which consumes the validated coverage artifact.
No PR or candidate publishes Pages, a tag/Release, or performance history.

## Protected-check rollout without duplicate builds

The baseline main ruleset `19074564` has strict required checks from GitHub
Actions integration `15368`, no bypass actors, and the following 24 contexts.
Classic branch protection returned 404; that does not replace the ruleset.
No repository settings are changed by this PR.

| Existing required context | New CI equivalent |
| --- | --- |
| lint | core / lint |
| changelog-sync | core / changelog-sync |
| release-contract | core / release-contract |
| gates | core / gates |
| docc | docc / docc |
| coverage | coverage / coverage (portable 85%, comprehensive 83%) |
| migration | migration / migration (historical 5.2.1 fixture retained) |
| smoke | performance / smoke (macro + canonical runtime) |
| address sanitizer | sanitizers / address sanitizer + Sanitizers Required |
| thread sanitizer | sanitizers / thread sanitizer + Sanitizers Required |
| test Inspector UI (iPadOS) | platforms / test Inspector UI (iPadOS) + Platforms Required |
| build iOS | platforms / build iOS + Platforms Required |
| build iPadOS | platforms / build iPadOS + Platforms Required |
| build Mac-Catalyst | platforms / build Mac-Catalyst + Platforms Required |
| build macOS | platforms / build macOS + Platforms Required |
| build tvOS | platforms / build tvOS + Platforms Required |
| build watchOS | platforms / build watchOS + Platforms Required |
| build visionOS | platforms / build visionOS + Platforms Required |
| test iOS | platforms / test iOS + Platforms Required |
| test iPadOS | platforms / test iPadOS + Platforms Required |
| test Mac-Catalyst | platforms / test Mac-Catalyst + Platforms Required |
| test tvOS | platforms / test tvOS + Platforms Required |
| test watchOS | platforms / test watchOS + Platforms Required |
| test visionOS | platforms / test visionOS + Platforms Required |

All 24 are transitively required by **CI Required** for exhaustive plans. New
policy, compiled docs and exact remote SHA proof add coverage. Six runtime lanes
retain their execution-count checks (10 iOS, 10 iPadOS, 10 Catalyst, 12 tvOS,
6 watchOS, 10 visionOS), zero skips/expected failures, native scene closure on
iPadOS/visionOS and Inspector interaction assertions. Confirm the numbers against
the actual workflow matrix when changing tests; do not lower a floor to pass CI.

Until `INNOROUTER_CI_AGGREGATE=true`, standalone workflows keep their current
names and execution. CI Required uses read-only API access to reuse their latest
successful original workflow runs at the exact PR head, verifies PR/base/test-merge
identity before and after, and reads all jobs of the latest run attempt and verifies GitHub Actions app, suite, head/merge and job/check association. It
rejects stale, missing, duplicate, failed, cancelled or unexpectedly skipped
children. This avoids a second set of heavy Swift/platform/sanitizer runs.
Policy/docs/exact-SHA consumer checks are additional. Ordinary documentation PRs
still pay the legacy full cost in this transition; selection is not fully active.

Owner-approved activation order:

1. Add **CI Required**, integration `15368`, to the existing strict main ruleset
   while preserving all 24 contexts, deletion/non-fast-forward rules and no bypass.
2. Verify the exact full PR head, original 24 checks and new aggregate succeeded;
   review this equivalence table and the negative tests.
3. After the owner merges the reviewed implementation into main, set repository Actions variable `INNOROUTER_CI_AGGREGATE` to `true`. Existing
   standalone jobs become explicit skips while the new CI calls the same reusable
   implementations. The new required aggregate now enforces selected/exhaustive
   gates; GitHub accepts skipped legacy contexts, so it must be required first.
4. Rerun a full validation at the same reviewed head in active mode. Verify actual
   context names/IDs and every platform child, then retire the old 24 required
   contexts, keeping strict **CI Required** and the trusted bot gate. Remove the
   obsolete standalone triggers in a follow-up PR after this proof.

Repository variables and ruleset writes require separate approval. Never enable
the variable before CI Required protection. Roll back by setting the variable
false; standalone full gates resume. Do not remove strict or app-bound protection.
A prior standalone success alone is not active-mode proof. Existing open PRs
must incorporate the new base before the new required workflow can be available.

## Release candidates and publication

Dispatch `release.yml` **from main** with `version=<bare SemVer>`,
`commit_sha=<40 lowercase hexadecimal characters>`, `publish=false` (default),
and no `tag`. The commit must be reachable from main and match the runtime,
README installation versions and GA/prerelease changelog phase. The local
`scripts/validate-release-candidate.py --version … --commit-sha …` checks
identity without network access or creating a tag.

Candidate validation runs every existing platform/Inspector, coverage, sanitizer,
performance, migration and principle gate, plus a clean remote exact-SHA macro
consumer. It packages versioned DocC, notes and checksums as Actions artifacts.
Candidate source links use the SHA, `/latest/` stays excluded, and **Candidate
Required** must succeed. No tag, draft Release, public Release or Pages write
is possible with `publish=false`.

A tag is already public to SwiftPM before GitHub Release publication. Obtain owner
approval for the version and exact SHA **before creating/pushing the tag**.
After approval, the existing immutable tag path remains authoritative: tag-push
GA publication and explicitly dispatched `tag=…`, `publish=true` recovery retain
exact-ref/event-SHA/main-ancestry checks, GA exact-tag consumer resolution,
RC/GA channel policy, existing-site preservation, latest/versioned docs and
serialized publication. Pre-release tag pushes remain publication no-ops;
manual pre-release publication also requires `publish=true` and `prerelease=true`.
No candidate code creates a tag. Tag/release/deployment execution is outside the
implementation authorization. Preserve an existing tag during retries; never
move/recreate it to recover publication.

## Dependabot and automatic merge

| Ecosystem | Asia/Seoul schedule | Version PR limit | Prefix | Group |
| --- | --- | --- | --- | --- |
| Actions | Monday 09:00 | 5 | chore(ci) | actions-minor-patch, minor/patch |
| Swift | Monday 09:30 | 3 | chore(deps) | swift-minor-patch, minor/patch |

Swift tracks root, ConsumerSmoke and NativeSceneSmoke manifests. Historical
MigrationSmoke/Before and After, generated/scratch packages and negative fixtures
are deliberately excluded. Actions remain full SHA-pinned. SwiftSyntax uses the
normalized `github.com/swiftlang/swift-syntax` pattern and is excluded from the
minor/patch group; every major and SwiftSyntax update remains its own PR but is
eligible for automatic merge after exhaustive verification. The reviewed Swift
config uses no unsupported development prefix, dependency-type or toolchain key.
Root SwiftSyntax constraint and all live locks must agree; a partial toolchain
update fails the public-operations guard. Migration locks retain historical pins.

Configured labels are `dependencies`, `github-actions`, `swift` and
`release-validation` (Swift). None existed in the read-only baseline. GitHub
ignores missing custom labels; separate label creation is required. Bot exhaustive
validation relies on the API author, not those labels. Version PR limits do not
limit security-update PRs. Existing security alert/settings behavior is preserved.

The automatic-merge coordinator and its activation contract must remain API-only
trusted default-branch code. It must identify `dependabot[bot]`, same-repository
head, main base, open/non-draft status, exact current head and test-merge/base,
latest attempts and all expected checks. Human PRs, fork/wrong-base/draft PRs,
review blocks, unresolved threads, conflict/stale base, partial/pending/failed
checks and uncertain API results cannot merge. Native auto-merge must retain
strict app-bound protection and head-CAS. See the coordinator's implementation
and negative tests for the exact required contexts. At baseline
`allow_auto_merge=false`; activation and trusted gate protection remain owner
settings decisions. No PAT/App credential is created. The implementation PR
itself is never an automatic merge target.

Official references: [Dependabot options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference),
[Swift normalization](https://github.com/dependabot/dependabot-core/blob/main/swift/lib/dependabot/swift/url_helpers.rb),
[Dependabot with Actions](https://docs.github.com/en/code-security/tutorials/secure-your-dependencies/automate-dependabot-with-actions),
[GITHUB_TOKEN event constraints](https://docs.github.com/en/actions/concepts/security/github_token).

## Public package operations

InnoRouter already appears in SPI's official
[PackageList](https://github.com/SwiftPackageIndex/PackageList/blob/main/packages.json)
and [listing](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter). Do not submit
another registration. `.spi.yml` uses supported `external_links.documentation`
pointing to the existing [latest DocC portal](https://innosquadcorp.github.io/InnoRouter/latest/).
Native SPI targets would require proof of SPI's build path; the canonical generator
uses the three public products and archive/catalog preparation. No DocC plugin is
added to the consumer package. Validate `.spi.yml` with the official SPIManifest
parser, separately from the repository guard and YAML/schema checks.

On 2026-09-30 the Pages API reported the existing gh-pages source. HTTP 200 and
DocC JSON checks confirmed the actual runtime landing
`/latest/runtime/documentation/innorouter/innorouter/` and migration article.
GitHub's current stable release was 6.1.0. SPI registration does not prove the
current tag/compiler matrix is indexed; after an approved release, check the
indexed version/SHA, builds and hosted documentation separately.

README English/Korean quick starts, CONTRIBUTING, SECURITY, RELEASING and issue/PR
forms share these references. Preserve MIT 2025 InnoSquad, the current security
support line, acknowledgment/patch promises and private advisory reporting.
Repository metadata, visibility, credentials, security settings, registration
and support-policy changes are separate owner decisions.
