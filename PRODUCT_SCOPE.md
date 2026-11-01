# MeowDisplay: product scope and ideas

**Mac Everywhere, On Whatever Display**

MeowDisplay is a **personal-first display and control tool**. It gives you
another way to see and use a Mac on devices you already have. The priorities
are great interaction, reliable display modes, clear permission controls,
privacy and good performance—not managing other people's computers.

## What MeowDisplay is

- **Mac sender:** mirror a Mac screen, create an extended Mac workspace, or
  work with individual Mac windows in Window view.
- **Receivers:** iPhone, iPad, Android and Mac, each with the features
  documented in [PARITY.md](PARITY.md).
- **Direct device connections:** USB where supported, local network or
  private-network Remote Access such as Tailscale. Pairing, peer identity
  and permission control are essential; see [SECURITY.md](SECURITY.md).
- **Useful for work too.** Individuals, designers, developers and other
  professionals are welcome to use it commercially or in the workplace.
  **Personal-first is a design focus, not a non-commercial-use restriction.**
  Actual license rights and obligations are in [LICENSE](LICENSE)
  (GPL-3.0), not in this description.

## What MeowDisplay is not trying to become

MeowDisplay is **not currently being developed as an enterprise remote
desktop, remote help-desk or IT fleet-administration product**. User
management, organization identity, unattended fleet enrollment, centralized
monitoring and managed support services are outside the intended scope.
That doesn't prohibit working remotely with your **own authorized Mac**.

MeowDisplay also does not currently require or run a developer-hosted
cloud account, media relay or centralized device directory. Remote Access
over a user-chosen network is not a hosted MeowDisplay remote service.

**Windows and Linux sender/receiver apps are not planned.** The maintainer
focuses on platforms used and testable directly, and a new operating-system
port creates substantial ongoing maintenance and compatibility work.
Ideas may be revisited if circumstances change; no roadmap, funding
threshold or implementation promise is attached.

## Where to discuss a different direction

The following public issues are **discussion trackers, not work commitments**:

| Direction | Discussion |
| --- | --- |
| Windows sender or receiver | [#84](https://github.com/raiseCatError/meowdisplay/issues/84) |
| Linux sender or receiver | [#85](https://github.com/raiseCatError/meowdisplay/issues/85) |
| Enterprise remote desktop or IT administration | [#86](https://github.com/raiseCatError/meowdisplay/issues/86) |
| Hosted accounts, relay or centralized sync | [#87](https://github.com/raiseCatError/meowdisplay/issues/87) |

Concrete requests for the **supported** apps and speculative ideas use
different [GitHub issue forms](CONTRIBUTING.md). The maintainer may read,
discuss, defer, decline or close suggestions based on product direction and
capacity. **A suggestion or issue is not a guarantee of consideration,
implementation, support or release timing.**

## Scope versus release status

An idea tracker says nothing about whether a feature is available in a
released build. See the [README](README.md), [receiver parity](PARITY.md)
and actual [releases](https://github.com/raiseCatError/meowdisplay/releases)
for implemented behavior and distribution status.

MeowDisplay 2.0 release preparation is handled separately under
[RELEASE.md](RELEASE.md). Store review, upload, approval and publication
are different states: no document should say a platform is available to the
public until the corresponding store/release actually confirms that.
