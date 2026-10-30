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
| `reference/opendisplay` | Read-only copy of the external project's `main`, moved only by `reference-sync.yml` (fast-forward, no tags). Never a base for features or releases. | Fast-forward only, never deleted, no bypass (temporary, until a dedicated App writes it) |
| `release-state` | The release workflows' persistent records (`releases/<version>.json`). No source code. | **Closed**: no creation, update, deletion or force-push, no bypass, until the owner's dedicated release App exists and becomes its only bypass (release automation is off until then) |

Required checks: `mac`, `release-tooling`, `android` (Tests) and `conventional` (PR
title).

## The repository today (2026-10-30)

- `raiseCatError/meowdisplay` is public and a GitHub **network fork** of `peetzweg/opendisplay`.
- **Default branch: `legacy/dev-opendisplay-next`** (`3f24b51`), the former `dev/opendisplay-next`, renamed so `dev` could exist (Git can't hold `dev` beside `dev/…`). It becomes `dev` once the release workflows' resume and store-safety fixes are on `dev` and the scheduled workflows are confirmed inert.
- **`dev`** (created at `3f24b51`) takes the 2.0 integration (`feature/v2-hotspot-parity` at `52727ce`) by PR; every later change reaches it by PR.
- **`main` = `a186369`**: the external project's tree at the fork point. **It shares no history with MeowDisplay's line**, whose first commit is `94aaa88` (2026-09-24); `main`, the inherited tags and the two pre-restart tags `pairing-encryption-v1` and `pre-testflight-ultrareview-2026-09-17` hold that earlier history and are never deleted. Its inherited `release.yml` and `pages.yml` (and the old default branch's `app-store-candidate.yml`) are **disabled** in Actions settings.
- **`release/app-store-rc` = `65d46e8`**: the source of v1.20.0 (`cbbad7f`) and its follow-up fix; contained in `52727ce`.
- Open PRs #19, #24–#28 and #30 are all contained in `52727ce` and are closed as included once the integration PR merges.
- One GitHub Release: **MeowDisplay 1.20.0 for Mac** (Latest), whose assets are the live Sparkle feeds.
- Rulesets: "Protect Main Branch", "Protect development branch" (now covering both the old and the renamed branch name) and those in `.github/rulesets/` once applied. Required checks: `mac`, `release-tooling`, `conventional`, `android`.

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
| The release-state and reference branches | A manual push could corrupt state or import external code | Restricting writes to the workflows needs a bypass actor GitHub accepts on a user-owned repository: GitHub's own Actions app (integration 15368) is refused ("must be part of the ruleset source or owner organization"); a GitHub App the owner creates and installs is accepted. Without one, anything holding `contents: write` could write `release-state`: the owner, and any workflow given `contents: write` on any branch of this repository (its `GITHUB_TOKEN`). So **`release-state` fails closed** (nobody may create or update it) until the owner's release App exists and is its only bypass; the release workflows then write it with that App's token. Independently of who can write it, publication never trusts it: publish-mac and every resume require the `release-publish` approval, and before anything is released the stores' live approval of the recorded builds, the GitHub Release for this exact commit with the recorded hashes, and a successful publish-mac job for this commit are re-derived (`verify-live`, `verify-resume`). `reference/opendisplay` is temporarily fast-forward-only and never deleted: an update can only move it forward, and the sync verifies the external head before pushing |

## Migration sequence

Each step is reversible, rewrites no history and force-pushes nothing. ⚑ = the owner's approval or account.

1. ✅ ⚑ Disable the inherited `release.yml`, `pages.yml` and `app-store-candidate.yml` (Actions settings). Re-enabling any of them needs its own safety review.
2. ✅ ⚑ Rename `dev/opendisplay-next` → `legacy/dev-opendisplay-next` after adding the new name to its ruleset (same commit, same protection; PRs #19 and #24 retarget automatically).
3. ✅ Create `dev` at `3f24b51`.
4. ⚑ Apply `.github/rulesets/*.json` (`scripts/release/apply-rulesets.sh`, then `--apply`) from a checkout that has them, including `tags.json` (no tag is ever deleted or moved). The old two rulesets stay.
5. ⚑ Create the protected environments and move the signing secrets into them (RELEASE.md § Credentials); each replacement is proven to work before its repository copy is deleted.
6. Merge the 2.0 integration PR (`feature/v2-hotspot-parity` → `dev`) once every required check, Android included, passes on the exact `52727ce` tree. Close #19, #24–#28 and #30 as included.
7. ⚑ Default branch → `dev` once the release-tooling fixes are on `dev` and the scheduled workflows are confirmed inert without their variables. Set `EXPECTED_DEFAULT_BRANCH=dev`.
8. ⚑ Start the reference branch (dispatch **Reference sync** once; `REFERENCE_SYNC=enabled` after reviewing it).
9. ⚑ Cut `release/2.0.0` from `dev` after the coordinated QA; the release PR and candidate pipeline follow (RELEASE.md).
10. ⚑ At the approved public launch only, **reconcile `main` without rewriting it**: a promotion branch whose one commit has the `v2.0.0` tree and two parents, `v2.0.0` and `main` (`git commit-tree 'v2.0.0^{tree}' -p v2.0.0 -p main`), merged into `main` by PR. `main`'s tree then equals the tag's, the upstream history stays in `main`'s ancestry with its authors, and none of the inherited workflows exists in the new tree. A plain `--allow-unrelated-histories` merge would conflict and keep `main`-only files; resetting `main` would be a force-push: neither is used. Later releases promote `release/<version>` → `main` normally.
11. ⚑ Default branch → `main` after the launch; development PRs keep targeting `dev`. Release fixes are made on `release/<version>` and merged back into `dev`.
12. ⚑ Branch cleanup only from a re-validated manifest and an explicit list: branches whose commits exist nowhere else are archived as tags first; `main`, every tag and `legacy/dev-opendisplay-next` stay.

## Not changed by this

The published v1.20.0 release, its tag, assets and URLs; the live Sparkle
feeds; bundle identifiers, Keychain groups, Bonjour service types
(`_opensidecar._tcp`), protocol identifiers, Xcode target and scheme names
(`OpenSidecar*`), signing metadata. Those are compatibility contracts;
renaming any of them is a separate, justified migration.
