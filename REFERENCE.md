# The OpenDisplay reference

MeowDisplay began as a fork of [OpenDisplay](https://github.com/peetzweg/opendisplay)
and is now developed and released independently ([BRANCHING.md](BRANCHING.md)).
OpenDisplay is an **external reference**: worth reading for fixes and ideas,
never the source of MeowDisplay's releases, versions or roadmap. Its
history, its GPL-3.0 license and its contributors' attribution stay in this
repository as they are.

MeowDisplay's own design is authoritative wherever the two differ: the
secure protocol (pv 22: transcript-authenticated pairing, pinned mutual TLS
1.3, per-connection session admission and input grants), the receiver
controls, the unified Mac app's roles, and our performance requirements.
OpenDisplay's version numbers never set MeowDisplay's.

## `reference/opendisplay`

A read-only copy of OpenDisplay's `main`, kept current by
`reference-sync.yml`:

- it checks the external repository's pinned identity (node `R_kgDOS2SYLQ`, `peetzweg/opendisplay`, default branch `main`) and that the fetched commit is the one GitHub's API reports;
- it only creates or fast-forwards `reference/opendisplay`, never force-pushes, and fetches no tags (the external project's tags never enter MeowDisplay's tag namespace);
- it never merges, cherry-picks, tags, releases or touches another branch, and holds no secrets; its push uses `GITHUB_TOKEN`, which starts no workflows, so the external project's workflow files on that branch don't run;
- the job summary and the `reference-sync` artifact record the external commit, the previous one and the result (`created`, `fast-forwarded`, `unchanged`, `diverged`, `mismatch`).

It runs when dispatched, and daily once the repository variable
`REFERENCE_SYNC` is `enabled`. A ruleset lets only GitHub Actions update the
branch.

**Rewritten history.** If OpenDisplay rewrites `main` (the old head is no
longer an ancestor), the sync stops with `diverged` and changes nothing. A
person then: (1) looks at what changed upstream of us; (2) keeps the old
copy by creating `reference/opendisplay-archive/<date>` at the current
`reference/opendisplay`; (3) with the reference ruleset's bypass (an admin,
deliberately), moves `reference/opendisplay` to the new external head; (4)
records it below. Product branches are never involved.

## Intake: deciding what to adopt

`reference-intake.yml` (dispatch, read-only) runs
`scripts/reference/intake.rb` over the reference commits since the last
review. For each change that looks like a security, reliability,
rendering/decoding, platform-compatibility or regression fix, it reports:
the external PR or commit, the problem it describes, whether MeowDisplay
already has it (the same patch, or a reference in our history), whether it
touches protocol, pairing or transport code, its areas (Mac, iOS, Shared,
Android, Linux, release tooling) and a suggested starting recommendation.

A person decides for each: **ignore**, **investigate**, **adapt** (our own
implementation of the idea) or **port** (the change itself). Nothing is
applied automatically. An adopted change is an ordinary MeowDisplay PR into
`dev` with its own tests, and:

- never weakens the secure protocol (no plaintext transport, no weaker pairing, no trust from discovery metadata);
- names its source in plain text in the commit message, for example "Port of OpenDisplay reference PR 424", never as `owner/repo#N` (which would cross-link the external project);
- keeps the GPL-3.0 headers and author attribution of anything copied, and says in the PR what was copied and why our own implementation wasn't preferred.

Create an issue or draft PR for a candidate only when it is justified, and
never merge one without review.

## Ledger

| Reviewed through | Date | Report | Notes |
| --- | --- | --- | --- |
| `v1.28.0` (`a7df481`) | 2026-10-26 | the 2026-10-26 upstream catch-up audit (maintainer's notes) | Ported or compared: 320, 304, 288 (own codec negotiation), 219, 392; deliberately different: 325. Next candidates: 346, 393 (with 413's tolerance), 399, 323 |
| `bcf8e2b` | 2026-10-27 | `intake.rb` run over `v1.28.0..bcf8e2b` | One candidate: OpenDisplay reference PR 424 (Mac asks only Android-looking USB devices for accessory mode). **Investigate** for a future Android USB binding; MeowDisplay has no Android USB path today. |
