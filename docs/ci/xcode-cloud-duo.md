# iPhone Duo UI tests in Xcode Cloud

Xcode Cloud runs the iPhone Duo UI tests on Apple's simulators. It runs the same three classes as
the GitHub `ios-duo` job (`AdaptiveLayoutTests`, `DemoModeSmokeTests` and
`LocalCalculatorTourTests`), with no live Mac (`MEOW_NO_LIVE_MAC=1`). The GitHub job stays as it is.

## What is in the repository

| File | What it does |
| --- | --- |
| `ci_scripts/ci_post_clone.sh` | Generates `MeowDisplay.xcodeproj` from `project.yml` after the clone. The project is generated and not committed. |
| `iOSUITests/DuoUITests.xctestplan` | The three classes, `MEOW_NO_LIVE_MAC=1`, and a 300 s limit per test. |
| `OpenSidecariOSDuo` scheme (in `project.yml` and `project.local.yml`) | Builds the receiver and tests it with that plan. No other scheme changes. |

## One-time setup (owner, in Xcode and App Store Connect)

1. Generate the project locally with `./generate-local.sh` and open it in Xcode 27.1.
2. In Xcode, choose **Integrate ▸ Create Workflow…** (or, in App Store Connect, Xcode Cloud ▸
   the OpenSidecariOS product ▸ Workflows, which can edit workflows in the browser) (Report navigator ▸ Cloud). Pick the
   **OpenSidecariOS** app (`com.raisecaterror.meowdisplay.ios`). Xcode Cloud uses the app's App
   Store Connect record and asks to create it if it doesn't exist.
3. Grant Xcode Cloud access to the GitHub repository when Xcode or App Store Connect asks. Only
   the account owner can do this step.
4. Edit the new workflow:
   - **Environment:** Xcode 27.1 or later (`.xcode-version` names 27.1), latest macOS. No
     environment variables are needed: the post-clone script signs for the team Xcode Cloud runs
     as (`CI_TEAM_ID`). A `DEVELOPMENT_TEAM` variable overrides it.
   - **Start Conditions:** manual start, or the branches to cover (for example `dev` and
     `codex/*`). Duo runs are slow, so don't start one on every push to every branch.
   - **Actions:** remove the default Archive action and add a **Test** action. Platform iOS,
     scheme **OpenSidecariOSDuo**, test plan **DuoUITests**, destination **iPhone Duo** (the
     simulator Xcode 27.1 lists as `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`), on the
     newest iOS 27 runtime.
   - **Post-Actions:** none are needed. Results, screenshots and logs stay in Xcode's Cloud
     reports and in App Store Connect.
5. Save, then run the workflow once manually on the branch.

## Reading a run

- The test report lists each test with its attachments. The layout tests attach their
  `receiver-chrome-*` screenshots, which show the Duo layout in each posture and orientation that
  the tests set.
- A class that ran no passing test is a failure. Check the report for each of the three classes.
  Xcode Cloud doesn't run the GitHub job's "ran nothing" check.
- The Mac isn't involved: tests that need a live Mac skip themselves.
