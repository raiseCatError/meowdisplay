# Contributing to MeowDisplay

Thanks for helping make MeowDisplay better. Bug reports, carefully described ideas, documentation, physical-device testing, translations, and focused code changes are welcome. You do not need to write code to contribute.

MeowDisplay is currently **Mac-first**: a Mac sends its screen to iPhone, iPad, Android, or another Mac. The Mac Receiver also has an input-forwarding implementation, though **two-Mac physical testing is still outstanding** ([#12](https://github.com/raiseCatError/meowdisplay/issues/12)). Windows and Linux senders/receivers are **not planned** ([#84](https://github.com/raiseCatError/meowdisplay/issues/84)); an idea tracker is not a promised roadmap.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before opening anything

- Search [issues](https://github.com/raiseCatError/meowdisplay/issues) and [pull requests](https://github.com/raiseCatError/meowdisplay/pulls), including closed items, to avoid duplicates.
- Check the current [features](https://meowdisplay.app/features.html), [receiver parity](PARITY.md), [setup guide](https://meowdisplay.app/docs.html), and [support page](SUPPORT.md).
- Keep one problem or proposal per issue. State what you observed and what you tested; avoid assuming a feature exists or is scheduled.
- Every issue and attachment is public. Remove personal content, device identifiers, private network/Tailscale addresses and hostnames, pairing codes, security keys, access tokens, logs containing secrets, and notifications **before** attaching captures or logs. If redaction cannot be verified, do not attach them.

### Where to go

| You want to… | Use |
| --- | --- |
| Report behavior that is broken or regressed | [Bug report](https://github.com/raiseCatError/meowdisplay/issues/new?template=bug_report.yml) |
| Request a concrete change to the supported product | [Feature request](https://github.com/raiseCatError/meowdisplay/issues/new?template=feature_request.yml) |
| Share an early thought, including an unplanned platform idea | [Idea / exploration](https://github.com/raiseCatError/meowdisplay/issues/new?template=idea.yml) |
| Correct confusing, missing, or outdated documentation | [Documentation issue](https://github.com/raiseCatError/meowdisplay/issues/new?template=documentation.yml) |
| Report real-hardware compatibility findings or volunteer device QA | [Device testing / compatibility report](https://github.com/raiseCatError/meowdisplay/issues/new?template=device_testing.yml) |
| Get help installing or pairing | [Support and setup](SUPPORT.md) |
| Privately report a security or privacy vulnerability | **Security tab → Report a vulnerability**, as described in [SECURITY.md](SECURITY.md) |

**Security vulnerabilities never belong in public issues, discussions, PR descriptions, or logs.** Please use the private vulnerability-reporting flow.

### Bugs and testing reports

Include the app version/build (or source commit), sender Mac and macOS version, receiving device and OS, relevant connection type (USB, Wi-Fi, Remote/Tailscale), display mode (Mirror, Extend or Window view), reproducible steps and expected/actual results. Say **physical device**, **simulator/emulator**, **automated test**, or **not tested** rather than treating them as equivalent. You can report a problem without attaching a log if the log is sensitive.

Hardware results are especially helpful for different Android models, Mac-to-Mac input, multi-monitor configurations, accessibility features, and reconnect/permission behavior. Reporting an observed result does not automatically become a release requirement.

### Features versus ideas

A **feature request** describes a specific user problem and an implementable change for an existing supported platform. An **idea** can be speculative, wide in scope, or require a new platform or architecture; it carries **no priority, ETA, or commitment**. The maintainer may discuss, defer, or close proposals based on scope and capacity. Do not interpret a tracking issue as an announcement.

## Contributing code or docs

1. For large features, architecture changes, new dependencies or new platforms, open an issue before implementation to discuss scope. Small bug fixes and clear documentation corrections can be proposed directly.
2. Fork the repository and base your branch on **`dev`**, the active development branch. Use a short descriptive name such as `fix/...`, `feature/...` or `infra/...`. See [BRANCHING.md](BRANCHING.md).
3. Keep the change focused. Do not alter protocol identifiers, bundle IDs, Keychain names, signing, release workflows or public compatibility guarantees casually. Follow the [terminology guide](TERMINOLOGY.md).
4. Read [SETUP.md](SETUP.md) and the relevant platform documentation. Run appropriate automated checks and, if possible, test the behavior on physical hardware. Tell us explicitly which platforms you **did not** test.
5. Open a PR against `dev` with a **Conventional Commit-style title** such as `fix(android): restore video after reconnect`, `docs: clarify pairing` or `feat(ios): improve window switching`. Use the PR template's testing, compatibility and privacy sections.

Maintainers coordinate `release/<version>` branches; **please don't open routine contributions against release branches** or edit version numbers, tags, release manifests or `CHANGELOG.md` for an ordinary PR. [RELEASE.md](RELEASE.md) describes the separate signed-build and publication gates.

Relevant platform checks include the Mac Xcode schemes and tests described in [SETUP.md](SETUP.md), and Android's `./gradlew :core:test :app:testDebugUnitTest :app:lintRelease` from `AndroidReceiver/`. If a test requires hardware you do not have, document that fact instead of marking it passed. CI is not a substitute for physical QA.

Never commit signing certificates, provisioning profiles, secrets, local overrides, private logs or personal screenshots. Use synthetic data in tests and examples. Do not modify unrelated branches or generated outputs. Contributions influenced by the external OpenDisplay project should retain applicable attribution and follow [REFERENCE.md](REFERENCE.md).

## Review expectations

Reviews depend on volunteer/maintainer capacity; a report or PR may not be acted on quickly. Keep discussions respectful and focused on reproducible evidence. A proposed change being technically possible does not mean it belongs on the roadmap. Revisions and small follow-up PRs are welcome.

## Translations

MeowDisplay welcomes community translations. If you speak another language
and would like to help localize the app, contributions are welcome. English
is currently the only source language; additional languages will be added as
real contributors provide and review them, one at a time — this list isn't a
wishlist to fill in advance.

Translations should be written or reviewed by a person who understands the
language well enough to judge natural wording, tone and context. **Please do
not submit AI-generated or machine-translated localization** — that includes
translations produced with ChatGPT, Claude, Gemini, Google Translate or
similar automatic translation systems. Good localization is more than word
substitution, and we'd rather support fewer languages well than ship many
awkward or incorrect translations. Minor tooling assistance for file
formatting or working with `.xcstrings` files is fine; the translated text
itself must be human-written and human-reviewed.

User-facing strings live in String Catalogs, one set per app target:
`Localizable.xcstrings` for the app's text and `InfoPlist.xcstrings` for
system permission prompts, in `Mac/` (the Mac app), `iOS/` (iPhone and iPad)
and `MacReceiver/` (the Mac Receiver). English is the source language and
every catalog already contains the current English strings.

To contribute a translation:

1. Fork and clone the repository, and create a branch from `dev`.
2. Generate and open the Xcode project as described in [SETUP.md](SETUP.md).
3. Open a String Catalog, click **+** at the bottom of its language list and
   add your language (or select it if it already exists).
4. Translate the entries. Read the comment shown next to a string for
   context, keep placeholders such as `%@` and `%lld`, and leave product names
   (MeowDisplay, MEOW) and technical terms like H.264, HEVC and USB as they
   are. Don't change source code, identifiers or protocol values.
5. If you can, build and run the app you translated with your language
   selected and check that the text fits.
6. Open a pull request that names the language, which catalogs it covers and
   who wrote or reviewed the translation.

Partial translations are welcome as long as the pull request says what is
still missing — quality matters more than the number of languages. If the
meaning or context of a string is unclear, please open an issue or ask before
translating it rather than guessing.

## License

MeowDisplay is licensed under [GPL-3.0](LICENSE). By contributing, you agree
your contribution is provided under that same license. Keep existing copyright
notices and the OpenDisplay attribution intact.
