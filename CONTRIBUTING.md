# Contributing

Thanks for helping. Forks are encouraged too: the app is built to be customized.

## Setup

```sh
git clone --recurse-submodules <repo>
open DynamicIsland4Mac.xcodeproj
```

Xcode 16 or later, macOS 14 or later. No other tools. Before opening a pull request, run the
tests (⌘U, or `xcodebuild -scheme DynamicIsland4Mac test`).

## Ground rules

These keep the app trustworthy and cheap to run:

- **No network access** except the existing `127.0.0.1` server. No telemetry, no analytics,
  no third-party SDKs. Dependencies go through Swift Package Manager, and only with a very
  good reason.
- **No polling** when an event, notification or KVO exists. If you need a timer, schedule
  one wake-up for the next moment that matters (see `CalendarModule.scheduleWakeUp`) and
  only while something is on screen. Continuous animations use Core Animation layers, not
  `TimelineView` (see `Island/CoreAnimationViews.swift`). The collapsed island must stay
  under 1% CPU.
- **Never break the agents.** `scripts/agent-hook.sh` must always exit 0, print nothing in
  event mode, and return immediately. Permission approvals must never decide without an
  explicit click. `HookScriptTests` and `ApprovalCenterTests` guard this; keep them passing.
- **Never surprise the user's files.** Installers show a diff, back up, merge and tag. The
  round-trip tests in `InstallerTests` must stay exact.
- **No force-unwraps** outside truly impossible cases. Errors go to Settings as well as the logs.
- **Comment the why**, especially around window levels, hit testing, the media adapter, hooks
  and anything surprising. People read this code to learn.
- **Accessibility**: label interactive elements for VoiceOver, respect Reduce Motion
  (`ThemeStore.animation` already swaps springs for fades) and Increase Contrast.
- Log with `os.Logger` through `Log.<category>`. Use `privacy: .public` only for
  non-personal values.

## Adding things

- **A module**: see "Write your own module in 5 minutes" in the README. One file in
  `Modules/<Name>/` and one line in `ModuleRegistry.swift`. Give it a `preview` with fake data.
- **An agent provider**: see "Add a new agent provider" in the README. Include fixtures and
  normalize tests.
- **A theme key**: add it with a default value in `Theme.swift` (old theme files keep
  working through `TolerantDecoder`), add an editor in `AppearanceSettingsView.swift`, and
  document it in `Themes/README.md`.

## Submit your theme

Community themes are very welcome.

1. Design it in Settings → Appearance, then **Export…** it (or write the JSON by hand).
2. Trim it: keep only the keys that differ from the defaults, so it stays readable and picks
   up future improvements. Every key is optional.
3. Pick a unique, lowercase, hyphenated `id` and name the file `<id>.json`. Set `name` and
   `author`.
4. Put it in `Themes/`. Add a row to the preset table in `Themes/README.md`.
5. Run the tests. `builtInPresetsAllDecodeCleanly` checks that every bundled theme decodes
   with no warnings.
6. Open a pull request with screenshots of the collapsed, compact and expanded states (the
   Settings preview is fine). Include both the light and dark variants if your theme has both.

Please don't use other products' logos or trademarks in themes; SF Symbols and your own
colors are great.

## Pull requests

- One topic per pull request, with a clear description of what changed and why.
- For anything visual, include before and after screenshots.
- For hook or installer changes, describe how you tested with the real tools and the
  versions you used.
- The CI workflow builds and runs the tests on every push and pull request.
