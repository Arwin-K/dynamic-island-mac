# Architecture

How DynamicIsland4Mac fits together and why it's built this way. Read this before
changing the window code, the agent pipeline or the installers.

## The big picture

```
                    ┌────────────────────── AppServices (one object graph) ─────────────────────┐
                    │                                                                            │
  NSScreen ───────► │ ScreenManager ──► IslandWindowController (per display)                     │
  changes           │                      ├─ IslandPanel (NSPanel, .mainMenu + 3)               │
                    │                      └─ IslandViewModel ◄── IslandStateMachine (pure)     │
                    │                              │  reads                                      │
                    │                              ▼                                             │
                    │  ThemeStore ◄── ThemeLibrary ◄── FSEvents on Themes/                       │
                    │  PreferencesStore (preferences.json)                                       │
                    │                                                                            │
                    │  ModuleManager ── AnyIslandModule ×N ── ModuleRegistry.swift               │
                    │     │  alerts, priority, compact slot, expanded tabs                       │
                    │     ├─ AgentsModule ◄── AgentHub ◄── LocalServer (127.0.0.1) ◄── hooks     │
                    │     ├─ NowPlayingModule ◄── MediaService ◄── perl + adapter (stream)      │
                    │     ├─ BatteryModule ◄── BatteryService ◄── IOKit notifications            │
                    │     ├─ CalendarModule ◄── EventKit                                         │
                    │     ├─ HUDModule ◄── HUDService ◄── CGEventTap                             │
                    │     ├─ ShelfModule ◄── drops on the island                                 │
                    │     └─ FocusTimerModule (the README example)                               │
                    └────────────────────────────────────────────────────────────────────────────┘
```

Everything on the main actor is `@Observable`. Views read state directly, and the few
pieces of AppKit glue re-run through `withObservationTracking` when the state they read changes.

## The window

**One `NSPanel` per display**, borderless and non-activating, at `level = .mainMenu + 3`,
joining all Spaces. The comments in `IslandPanel.swift` explain each flag. Two things matter most:

- **It must never take keyboard focus** (`canBecomeKey == false`). You're typing in a
  terminal while an agent runs, and clicking the island must not steal that.
- **Clicks must reach the menu bar** wherever the island isn't drawn. The panel is
  **resized to the island's bounding box** in every state, so outside it there is no window
  at all. Inside it, the rounded corners and shadow margin are fully transparent pixels, and
  because `ignoresMouseEvents` keeps its default value, the window server passes clicks on
  them through. The alternative, a big window that toggles `ignoresMouseEvents` from a global
  mouse monitor, costs CPU on every mouse move all day and lags at the edges.

The panel grows *before* a spring animation (to the union of the old and new frames) and
shrinks *after* it settles, so the shape is never clipped mid-animation. SwiftUI is hosted in
a plain container view, because an `NSHostingView` that is the window's `contentView` starts
resizing the window itself during animations, which fights the controller and can throw
"Update Constraints in Window" exceptions.

**Notch geometry** comes from `auxiliaryTopLeftArea`, `auxiliaryTopRightArea` and
`safeAreaInsets.top`. Only the *widths* of the auxiliary areas are used, so the math doesn't
depend on which coordinate space AppKit reports them in. Without a notch, the island becomes
a floating pill below the menu bar. Everything recomputes on
`didChangeScreenParametersNotification`.

## The state machine

`IslandStateMachine` is a value type with four states and a handful of transitions
(`open`, `close`, `beginAlert`, `endAlert`, `setLiveActivity`). It has no timers and no
views, so it's tested directly. `IslandViewModel` wraps it with input handling (hover delay,
click, shortcut, outside click) and sizes, and applies each transition inside
`withAnimation(theme spring)`.

Rules worth knowing: live-activity changes never close an open island or interrupt an alert;
an alert that arrives while the island is open stays pending and shows when it closes.

## Modules

`IslandModule` is the extension point. It uses associated `some View` types so module
authors write plain SwiftUI. `AnyIslandModule` type-erases each module with closures, so
`ModuleManager` can hold them all in one array. Modules get a `ModuleContext` for alerts,
opening the island and settings storage, so a module never touches preferences or windows
directly.

`ModuleManager` owns the priority order (user order first, then each module's `priority`),
on/off state, which module has the compact slot, the expanded tab strip, and the alert queue
(coalescing by key, sticky alerts for approvals). It's shared by every display, so all
islands show the same thing.

## Themes

`Theme` is a plain `Codable` struct with a default for every property. Theme files are read
by `TolerantDecoder`, which deep-merges the file over the encoded defaults and, when a value
is invalid, replaces just that value (or drops a broken dictionary entry) and records a
warning. Old themes never break when keys are added, and a typo costs one value, not the
whole theme.

`ThemeLibrary` merges bundled presets with the user's folder (a user file with a built-in's
id is a "customized" copy, and Reset deletes it) and watches the folder with FSEvents.
`ThemeStore` holds the active theme and the live inputs (dark mode, Reduce Motion, Increase
Contrast, macOS accent, wallpaper and album-art colors), all event driven, and debounces
writes while you drag sliders.

## Agents

```
Claude Code / Codex ──stdin JSON──► agent-hook.sh ──HTTP + bearer token──► LocalServer
                                    (exits 0 at once)                         │
                       AgentProvider.normalize(raw) ◄─────────────────────────┘
                                    │  AgentEvent (provider-neutral)
                                    ▼
                       AgentSessionReducer (pure) ──► AgentSessionStore ──► AgentsModule UI + alerts
```

- **The hook script is the safety boundary.** It reads stdin, attaches terminal details
  (`$TERM_PROGRAM`, session ids, TTY, parent pids, the launching app's bundle id) as headers,
  hands the upload to a *detached* `curl` with all output sent to `/dev/null`, and exits 0.
  Claude Code feeds async hook output back to the model and Codex rejects plain text on
  some events, so printing anything would change agent behavior. A child process holding
  stdout open would make the agent wait, which is why the output is redirected. The token
  travels in a mode-600 header file so it never appears in `ps`.
- **The server** is Network.framework bound to `127.0.0.1` only, checks the bearer token in
  constant time, caps sizes, and acknowledges events before processing them.
- **Providers** own everything tool-specific: event mapping, installer, terminal focus, and
  the exact PermissionRequest output format. The UI only knows the icon, name and color.
- **`AgentSessionReducer`** is the shared state machine (starting, thinking, runningTool,
  waitingForPermission, waitingForInput, done, failed, interrupted, plus subagents). It
  returns the new session and a list of transitions; alerts are raised from the transitions.
  Claude's `permission_prompt` notification arrives about 6 s after `PermissionRequest`, so it
  is a separate "notice" event that only matters if the request was missed. Without that,
  every permission would alert twice.
- **The store** sweeps stale and dead sessions on a timer that only exists while there are
  sessions.

### Approvals

The synchronous approval hook long-polls `/permission`. `ApprovalCenter` holds the HTTP
response until an explicit click (HTTP 200 with the provider's JSON) or any other outcome
(HTTP 204 = no decision): timeout, the tool running anyway, a new prompt, the session ending,
or the app quitting. The script prints a body only for HTTP 200, so the only way to approve
is a click.

### Installers

`OrderedJSON` parses and prints JSON with key order and number literals preserved.
`HookMerger` appends tagged entries and removes exactly those, using a small install record
so that merge followed by unmerge restores the file byte for byte (tested). `JSONHookInstaller`
adds the user-facing safety: show the diff, refuse to write if the file changed since the
diff, back up first, keep the file's indent and permissions. Codex's installer also defers to
`config.toml` when it already declares hooks inline.

## Media

`MediaService` runs `mediaremote-adapter` through `/usr/bin/perl`, which is allowed to use
the private MediaRemote framework. It runs `test` once, then one long-lived `stream` process
whose JSON diffs are merged off the main thread. Controls are short `send` and `seek`
processes. A crashed stream restarts with exponential backoff a few times, then the service
falls back to AppleScript for Music and Spotify, driven by their distributed notifications.
On SIGTERM or SIGINT the app stops its children, and on launch it reaps adapter streams that a
crashed previous run left behind.

## Performance

The idle budget is under 1% CPU with the island collapsed. Measured on a Release build
(`top`, 2 s samples, M-series MacBook Pro): 0.0% CPU and no idle wakeups while collapsed, and
0.0% for the adapter's `perl` stream process. While music played in the compact island, the
original SwiftUI `TimelineView` waveform cost 10–26%; it's now a Core Animation layer animated
by the render server (a follow-up measurement averaged about 0.6%, but playback may have
paused during it, so confirm with Instruments). The rules that keep it there:

- No polling. IOKit, EventKit, FSEvents, distributed notifications, KVO and NSWorkspace
  notifications drive everything. The few timers (stale sweep, calendar wake-up, finished
  sessions leaving the compact view) are scheduled only while needed.
- Continuous animations (waveform, thinking pulse) are `CABasicAnimation`s, which the render
  server runs without the app.
- `TimelineView` only appears in the expanded view (progress, elapsed time), at 1 s or slower,
  and only while something is changing.

To check yourself: Instruments → Time Profiler or Activity Monitor template, attach to
DynamicIsland4Mac, and leave the island collapsed for a minute.

## Testing

Swift Testing, hosted in the app (which skips starting windows and servers under tests).
Covered: notch geometry, the island state machine, theme decoding (missing, unknown and
invalid keys), preset files, the theme library, module ordering, compact selection and
alerts, the media parser, each provider's `normalize` with JSON fixtures, the session
reducer and store, the local server (parsing, auth, live requests), the hook script's safety
contract (silent, exit 0, fast, timeouts, decisions), approvals end to end, ordered JSON,
merge/unmerge round trips, installs on disk, and the Core Animation views.
