<!-- Title: Conventional Commit, e.g. "fix(android): prevent reconnect loop". Base normal PRs on dev. -->
<!-- Security/privacy vulnerabilities should be reported privately first, not disclosed in an open PR. -->

## Summary

What changed, and why? Link the related issue if one exists.

Closes #

## Scope and compatibility

- Platforms/components affected:
- User-visible behavior:
- Compatibility considerations (older app versions, pairing, settings, protocol, permissions):

## Verification

| Check | Result and evidence |
| --- | --- |
| Automated tests / lint / build | |
| Physical devices tested (models and OS versions) | |
| Simulator or emulator (if used) | |
| Not tested / known limitations | |

## Safety and review checklist

- [ ] This is a focused change with no unrelated refactors.
- [ ] Relevant automated checks ran; failures or skipped tests are documented.
- [ ] I distinguished real-device verification from simulator/emulator or unit tests.
- [ ] Existing pairing, security and consent behavior is preserved, or changes are explained.
- [ ] Public screenshots, logs and test data contain no personal data, private endpoints, identifiers, secrets or pairing codes.
- [ ] Documentation, user-facing terminology and accessibility were updated if relevant.
- [ ] No signing material, credentials, provisioning profiles or local build artifacts are included.
- [ ] This PR does not tag, release, publish, or alter protected release workflows without explicit maintainer coordination.

## Notes for reviewers

Screenshots, behavior notes, tradeoffs, follow-ups, or any setup needed to test.
