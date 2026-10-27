# Branches, releases and the repository's independence

MeowDisplay is managed as its own product: its own branches, versions, CI,
releases and roadmap. The OpenDisplay project is an optional external
reference ([REFERENCE.md](REFERENCE.md)), never the source of our releases.
Git history, GPL-3.0 obligations, copyright notices and commit attribution
stay exactly as they are.

## Branch model

| Branch | Role | Rules (`.github/rulesets/`) |
| --- | --- | --- |
| `main` | The exact source of the latest **published** MeowDisplay release; its tag `vX.Y.Z` names the release commit. Changes only by the release's promotion PR. Landing on `main` never publishes anything. | PR (merge commits only), required checks, no deletion or force-push, no bypass |
| `dev` | Active development: features, fixes, Android, Mac and iOS work integrate here by PR. | PR, required checks, no deletion or force-push |
| `release/<version>` | One release's candidate for every platform (RELEASE.md). Created from an approved `dev` baseline; takes release fixes, QA findings and distribution preparation; fixes are forward-ported to `dev`. Every push builds a candidate; nothing publishes without approval. | Only admins create one (its own ruleset, so the admin bypass covers creation only); PR, required checks, no deletion or force-push. The signing environments allow `release/*` only, so this decides who can reach the signing keys |
| `feature/*`, `fix/*`, `infra/*` | Short-lived work, by draft PR into `dev` (or a release branch for a release fix). | — |
| `reference/opendisplay` | Read-only copy of the external project's `main`, moved only by `reference-sync.yml` (fast-forward, no tags). Never a base for features or releases. | Only the sync workflow may update it |
| `release-state` | The release workflows' persistent records (`releases/<version>.json`). No source code. | Only the release workflows may update it |

Required checks: `mac`, `release-tooling` (Tests) and `conventional` (PR
title); `android` once the Android app is in the branch.

## The repository today (audited 2026-10-27)

- `raiseCatError/meowdisplay` is public and a GitHub **network fork** of `peetzweg/opendisplay`. Default branch: `dev/opendisplay-next`.
- **`main` = `a186369`**: the external project's tree at the fork point, with no MeowDisplay commits. It still carries that project's `release.yml` (release-please on push to `main`) and `pages.yml` (GitHub Pages deploy on push to `main`). **It is not a MeowDisplay release.**
- **`release/app-store-rc` = `65d46e8`**: the source of everything shipped (v1.20.0 = `cbbad7f`) plus the type-check fix (#29). **Unprotected** (no ruleset).
- **`dev/opendisplay-next` = `3f24b51`**: v1.20.0's merge-base plus five docs-only commits; 30 commits behind the release line. Protected (PR, no force-push), required-checks list empty.
- **`integration/meowdisplay-next-preview` = `c57f422`**: draft PR #30, the combined v2 preview of PRs #24–#28 (do not merge).
- Open draft PRs: #24 → `dev/opendisplay-next`; #25 → #24's branch; #26 → #25's branch (stacked); #27, #28, #30 → `release/app-store-rc`; #19 → `dev/opendisplay-next` (already contained in the release line).
- Tags: MeowDisplay's own start at `v1.20.0` (→ `cbbad7f`). The external project's older tags (`v0.1.0`–`v1.16.0` and others) were inherited at the fork point and stay as history; local clones keep newer external tags under `refs/upstream-tags/*`. The reference sync never imports tags.
- One GitHub Release: **MeowDisplay 1.20.0 for Mac** (Latest) with both DMGs, both signed feeds and `SHA256SUMS.txt`. Installed Macs update from it through `meowdisplay.app/appcast*.xml` → `releases/latest/download/…`.
- Rulesets: "Protect Main Branch" (`main`, with an always-bypass for a repository role) and "Protect development branch" (`dev/opendisplay-next`); both have empty required-checks lists. No environments. Actions token read-only; Actions can't create PRs.
- Secrets at repository level: `DEVELOPMENT_TEAM`, `MATCH_DEPLOY_KEY`, `MATCH_GIT_URL`, `SPARKLE_PRIVATE_KEY`.
- ~75 remote branches, most of them copies of the external project's branches from the fork; they do nothing and can be cleaned up later (never needed for the migration).

## Fork relationship: operational independence vs. GitHub metadata

Being a network fork is GitHub metadata: it groups the repositories,
suggests the parent as a PR base in some tools (`gh pr create` needs
`-R raiseCatError/meowdisplay`), and shares Git object storage. It grants
the external project no access to our branches, secrets, Actions, releases
or settings, and none of our workflows depend on it.

Operational independence (this document and RELEASE.md) needs no change to
the fork relationship. Detaching the fork, renaming, transferring or
replacing the repository are separate decisions with their own risks
(release asset URLs, the Sparkle feed redirect, App Store and website
links all name `raiseCatError/meowdisplay`) and are **not** part of this
migration.

## Migration risks

| Risk | Why it matters | Mitigation in the sequence |
| --- | --- | --- |
| Anything landing on today's `main` runs the external project's `release.yml` and `pages.yml` | release-please could open or create a release; a Latest release without feeds 404s every installed Mac's updates | Nothing lands on `main` until a commit carrying MeowDisplay's dispatch-only workflows does: the first promotion is 2.0.0 published through the new pipeline |
| `release/app-store-rc` is unprotected | The shipped source could be force-pushed or deleted | Protect it first (step 1) |
| The workflow files must exist on the default branch to be dispatchable, and scheduled ones run only there | Monitor, sync and guard can't run otherwise | `dev` becomes the default branch early (step 6), `main` after 2.0.0 (step 13) |
| Stacked PRs #24 → #25 → #26 | Retargeting or squashing out of order replays or loses reviewed changes | Merge in the reviewed order with merge commits; retarget each only after its parent merged |
| Secrets readable by any workflow on any branch | A workflow from another branch (or the reference branch's files) could read signing keys | Move them into environments limited to `release/*`; delete the repository-level copies |
| The release-state and reference branches | A manual push could corrupt state or import external code | Rulesets allow only GitHub Actions to update them |

## Migration sequence

Each step is reversible, rewrites no history and force-pushes nothing.
**Every step marked ⚑ needs your explicit approval** and is done by you or
on your instruction; nothing here is applied by a workflow.

1. ⚑ **Protect `release/app-store-rc`** (ruleset: no deletion, no force-push, PR required). *Rollback:* disable the ruleset.
2. ⚑ **Merge the reviewed v2 stack into `release/app-store-rc`** in the order the integration review set: #28, #27, then retarget #24 to `release/app-store-rc` and merge #24 → #25 → #26 (retargeting each only after its parent merged), merge commits only. Close #30 (preview) and #19 (superseded). Check `git diff 07935b2 release/app-store-rc` is empty. *Rollback:* revert the merge commits.
3. ⚑ **Create `dev`** at `release/app-store-rc` (a new branch; `dev/opendisplay-next` is not renamed or deleted). Check `dev/opendisplay-next` is an ancestor of `dev` (its docs commits arrived through #24). *Rollback:* delete `dev` (it holds no unique commits).
4. **Land the work branches into `dev` by draft PR**, reviewed one by one: `infra/repository-independence` (this; after its own review), `feature/v2-apple-finalization`, `feature/same-mac-sessions`, then the Android branches. *Rollback:* revert the PRs.
5. ⚑ **Create the environments and credentials** (RELEASE.md § Credentials), move the signing secrets into them, delete the repository-level copies, create the release and website GitHub Apps. Run **Release dry run** from a release branch to confirm. *Rollback:* re-add repository secrets; delete environments.
6. ⚑ **Default branch → `dev`.** Set `EXPECTED_DEFAULT_BRANCH=dev`. *Rollback:* switch back to `dev/opendisplay-next`.
7. ⚑ **Apply the rulesets** (`scripts/release/apply-rulesets.sh`, then `--apply`): `main`, `dev`, `release/*` (protection, and admin-only creation), `reference/opendisplay`, `release-state`. The old two rulesets stay until step 14. Once a second maintainer exists, raise the required approvals on `main` and `release/*` to 1 (a sole maintainer can't approve their own PRs). *Rollback:* disable the new rulesets.
8. ⚑ **Start the reference branch**: dispatch **Reference sync** once; enable `REFERENCE_SYNC` after reviewing its first run. Optionally `REPOSITORY_GUARD=enabled`.
9. ⚑ **Cut `release/2.0.0` from `dev`** after the integration review and the coordinated physical QA. Run **Release PR** on it and merge the PR: the candidate builds for every platform.
10. ⚑ **Store setup**: App Store version 2.0.0 metadata; Play Console app, managed publishing on, internal/closed testing tracks; then `RELEASE_AUTOMATION=enabled` (the monitor submits and follows review).
11. ⚑ **Approve publication** (`release-publish`) when the readiness report says *Ready to publish*.
12. ⚑ **Merge the promotion PR** `release/2.0.0` → `main` (merge commit; `git diff v2.0.0 main` empty afterwards). `main`'s inherited workflows are replaced in that same commit by MeowDisplay's, so nothing else runs on it.
13. ⚑ **Default branch → `main`**, `EXPECTED_DEFAULT_BRANCH=main`; forward-port release fixes from `release/2.0.0` to `dev` by PR.
14. ⚑ **Retire old names** once nothing depends on them: remove the old two rulesets; leave `dev/opendisplay-next` and `release/app-store-rc` as protected, read-only history (or delete them after confirming every open PR and worktree moved; the tags keep the shipped source regardless).

Release fixes after 2.0.0: on `release/2.0.x` (or `release/2.0.1`) from the
release tag, forward-ported to `dev`.

## Not changed by this

The published v1.20.0 release, its tag, assets and URLs; the live Sparkle
feeds; bundle identifiers, Keychain groups, Bonjour service types
(`_opensidecar._tcp`), protocol identifiers, Xcode target and scheme names
(`OpenSidecar*`), signing metadata. Those are compatibility contracts;
renaming any of them is a separate, justified migration.
