# Contributing to MeowDisplay

Thanks for your interest in MeowDisplay. Bug reports, testing on different
Macs, iPhones, iPads and networks, documentation fixes and code changes are all
welcome.

Please read and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security vulnerabilities

**Do not file security or privacy vulnerabilities as public issues, Discussions
or pull requests.** Use GitHub's private **Report a vulnerability** feature
instead (repository → **Security** → **Report a vulnerability**). See
[SECURITY.md](SECURITY.md).

## Issues

- Search [existing issues](https://github.com/raiseCatError/meowdisplay/issues)
  first; add detail to a matching one rather than opening a duplicate.
- Report bugs with the **Bug report** form.
- Suggest ideas with the **Feature request** form.
- For setup help, see [SUPPORT.md](SUPPORT.md).
- Please open an issue before starting large or architectural work.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make a focused change — one fix or feature per PR, without unrelated
   refactors or formatting churn.
3. Follow the existing Swift and project style (see [AGENTS.md](AGENTS.md) and
   [SETUP.md](SETUP.md) for building).
4. Verify your change: run the relevant tests and/or describe how you tested
   it on real devices.
5. Open a PR describing what changed, why, and how you verified it. PR titles
   must be [Conventional Commits](https://www.conventionalcommits.org/)
   (for example `fix: reconnect after Wi-Fi drop`), because they become the
   squash-merge commit and changelog entry.

Do not commit secrets, credentials, signing identities, provisioning profiles,
private endpoints or personal logs. Keep local signing overrides out of tracked
files.

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

User-facing strings live in `Localizable.xcstrings` String Catalogs (one per
app target: `Mac/`, `iOS/`, `MacReceiver/`). If the meaning or context of a
string is unclear, please open an issue or ask before translating it rather
than guessing.

## License

MeowDisplay is licensed under [GPL-3.0](LICENSE). By contributing, you agree
your contribution is provided under that same license. Keep existing copyright
notices and the OpenDisplay attribution intact.
