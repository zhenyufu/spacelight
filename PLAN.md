# Spacelight - a Spotlight-style AeroSpace switcher

## Context

AeroSpace manages the workspaces on this machine, but there is no good way to jump to a workspace or a specific window by name.

The current setup is an `ff()` shell function in `~/.zshrc` that pipes `aerospace list-workspaces` and `aerospace list-windows` into `fzf`, bound to `alt-space` in `~/.aerospace.toml` via `exec-and-forget osascript ... tell application "Terminal"`.
This works logically but fails as a user experience.
Spawning a Terminal window makes AeroSpace tile it, which shifts every other window on the workspace.
After switching, the spawned Terminal is left behind and has to be cleaned up.
There is a visible delay while the shell, the profile, and `fzf` all start up.

Existing third-party alternatives were evaluated and rejected.
`MediosZ/SwipeAeroSpace` is slow.
`rvk7895/aerospace-workspace-switcher` is buggy in use and its typography does not match the system.

The intended outcome is a single executable that the user binds to whatever key they like in `~/.aerospace.toml`, which drops a floating Spotlight-style panel over whatever is on screen with no window disturbance at all.
The panel lists workspaces and windows in one fuzzy-searchable list.
Enter focuses the selection and the panel disappears.
The three non-negotiable properties are: it must be fast enough that the panel feels like it was already there, it must look indistinguishable from a first-party macOS surface, and it must never perturb the window layout.

Spacelight ships exactly one command and **never registers a global hotkey of its own**.
No key combination appears in the binary or in Spacelight's config, `⌥Space` included.
The keybinding lives entirely in `~/.aerospace.toml` alongside every other binding, so a key can never be silently claimed by an app that is invisible from that file, and any key or modifier can be chosen without Spacelight needing a hotkey parser or a settings UI.

## Language and libraries

**Swift 6.3, AppKit, zero third-party dependencies.**

The toolchain on this machine is Xcode 26.6 with Swift 6.3.3 targeting `arm64-apple-macosx26.0`, running macOS 26.5.
The deployment target is macOS 14.

| Concern | Choice | Why |
| --- | --- | --- |
| Language | Swift 6 (strict concurrency on) | Native, no runtime to ship, compiles to a small arm64 binary that starts in milliseconds. |
| UI | AppKit: `NSPanel`, `NSVisualEffectView`, `NSTableView`, `NSTextField` | Total control over row metrics, blur material, and focus behavior. Using system fonts through `NSFont.systemFont` is what guarantees the typography is correct, which is exactly what the rejected alternatives got wrong. |
| Trigger | The bound command talks to the resident agent over a unix socket | No hotkey API is used at all. Measured on this machine: a bare `Darwin`-only spawn is ~3.8ms median, one linking Foundation is ~5.1ms, one linking AppKit is ~5.8ms. Since client and agent code live in one target, one Mach-O, the shipped binary links AppKit regardless of which branch runs, so the real client-path cost is ~5-6ms, not the ~10ms guessed earlier. That is still roughly 3ms of headroom versus a Foundation-only build and immaterial next to the ~20ms total budget, so no separate no-Foundation client target is built for it. |
| AeroSpace access | `Foundation.Process` invoking the `aerospace` CLI | The raw CLI call is ~35-40ms, but `Process` itself adds roughly 30ms of overhead on top (measured: `Process` averages ~72ms for a single invocation versus ~40ms for the same call via raw `posix_spawn`). `Process` is kept anyway for its safety and simpler error handling, since this cost sits entirely off the main thread and behind a cache and never sits in the interaction path; see the Latency budget section for the actual measured snapshot cost. |
| Event stream | One long-lived `aerospace subscribe --all` child process, line-delimited JSON on stdout | Spawned once at launch, so the per-press cost is zero. Keeps the cache warm without polling. |
| Icons | `NSWorkspace.shared.icon(forFile:)` against `app-bundle-path`, memoized | Real app icons at native scale, no asset bundling. |
| Config | JSON at `~/.config/spacelight/config.json` via `Codable` | TOML would mean taking a dependency for no real gain. |
| Login item | An optional `~/Library/LaunchAgents/com.spacelight.agent.plist`, written by `spacelight --install-login-item` | Purely an optimization to skip the one-time cold start. The agent self-starts on first press regardless, so this is never required. |
| Build | Swift Package Manager, no app bundle | `swift build -c release` emits exactly one binary, which is the whole deliverable. |
| Tests | `swift-testing` (the `Testing` module, bundled with the toolchain) | Covers the parser and the fuzzy matcher, which are the two pieces with real logic. |

Explicitly not used: Electron, Tauri, and any web view, because they are the root cause of the "fonts are wrong" and "slow" complaints about the existing projects.
SwiftUI is also not used, even for the row list, to avoid inheriting its list scrolling and focus quirks on a surface where pixel accuracy is the point.

## Architecture

One binary with two roles, selected by how it is invoked.

Run bare, `spacelight` is a **client**: it connects to `~/.local/state/spacelight/agent.sock`, writes `toggle`, and exits.
Run as `spacelight --agent`, it is the **agent**: an always-running process that owns the panel and the cache, and that sets `NSApp.setActivationPolicy(.accessory)` before anything else.
If the client finds no agent listening, it `posix_spawn`s `spacelight --agent`, waits for the socket to appear with a short bounded retry, then sends `toggle`.
That self-healing start is what removes any setup step and survives a reboot or a crash.

The `.accessory` policy matters for two reasons: it keeps the app out of the Dock and the app switcher, and it is what keeps AeroSpace from ever treating the panel as a tileable window.

The client and agent are one Swift target compiled into one Mach-O, dispatched by `argv` in `main.swift`, not two separately linked binaries.
That means the client code path itself uses plain `Darwin` socket calls (`socket`, `connect`, `write`, `close`), but the binary it runs inside still has AppKit as a linked framework because the agent code lives in the same target.
Measured on this machine, that costs the client path about 5-6ms rather than the sub-4ms a truly AppKit-free binary would get, which is a real but small difference and not worth a second executable target for.
The design keeps the client's own code minimal regardless, since it is the one part of the system where process startup sits in the critical path and every allocation there is pure loss.

```
   <any key you bind> in ~/.aerospace.toml
     exec-and-forget /usr/local/bin/spacelight
                              │
                              ▼
  ┌───────────────────────────────────────────────┐
  │ client   (~5-6ms, exits at once)               │
  │   connect → write "toggle" → close             │
  │   if no socket: posix_spawn the agent first    │
  └───────────────┬───────────────────────────────┘
                  │ unix socket
                  ▼
  ┌───────────────────────────────────────────────┐
  │ agent · AppDelegate                            │
  │   owns a single prewarmed SwitcherPanel        │
  └───────────────┬───────────────────────────────┘
                  │ reads (never blocks)
                  ▼
  ┌───────────────────────────────────────────────┐
  │ StateStore   (@MainActor, holds last snapshot) │
  └───────▲───────────────────────────┬───────────┘
          │ refresh result            │ actions
          │                           ▼
  ┌───────┴───────────┐   ┌───────────────────────┐
  │ EventSubscriber   │   │ AeroSpaceClient       │
  │ aerospace         │   │ Process → aerospace   │
  │   subscribe --all │   │   list-* / workspace  │
  │ (one child proc,  │   │   / focus             │
  │  lives forever)   │   │ (background actor)    │
  └───────────────────┘   └───────────────────────┘
```

### The control socket

The agent listens on a unix socket at `~/.local/state/spacelight/agent.sock`, created with mode `0600` and unlinked on clean exit.
A stale socket file left by a crash is detected by attempting a connect and unlinking on `ECONNREFUSED`, so a crashed agent never wedges the next press.

The protocol is one newline-terminated ASCII verb per connection, with no framing and no versioning to get wrong: `toggle`, `show`, `hide`, `quit`, `ping`.
Only `toggle` is needed for normal use, but the others make the thing debuggable from a shell and give the CLI something useful to expose.

Single-instance safety comes from binding the socket itself.
If `bind` fails with `EADDRINUSE` and a connect succeeds, another agent is already live and this one exits immediately, so a race between two simultaneous first presses cannot produce two agents.

### The AeroSpace bridge

`AeroSpaceClient` resolves the `aerospace` executable path once at startup, checking `/opt/homebrew/bin/aerospace` first and falling back to a `PATH` search, then reuses that path for every `Process`.

A snapshot is exactly two invocations, run concurrently:

```
aerospace list-workspaces --monitor all --empty no \
  --format '%{workspace}%{tab}%{workspace-is-focused}%{tab}%{workspace-is-visible}%{tab}%{monitor-id}%{tab}%{monitor-appkit-nsscreen-screens-id}'

aerospace list-windows --all \
  --format '%{window-id}%{tab}%{app-name}%{tab}%{window-title}%{tab}%{workspace}%{tab}%{app-bundle-path}%{tab}%{monitor-id}'
```

`--empty no` excludes workspaces with no windows in them: an empty workspace has nothing useful to switch to via this list, since the numbered/named `aerospace workspace <n>` bindings already in `~/.aerospace.toml` cover "go create/visit an empty workspace." On this machine that's the difference between listing 17 workspaces and listing the 7 that actually have something in them.

Tab-delimited `--format` is used rather than `--json` because window titles routinely contain characters that make eyeballing JSON painful, and splitting on tab is both faster and simpler to unit test.
Window titles cannot contain a literal tab, so the split is unambiguous.

`EventSubscriber` runs `aerospace subscribe --all` once and parses its stdout line by line.
The stream emits `focus-changed`, `focused-workspace-changed`, `focused-monitor-changed`, and `mode-changed`.
It notably does **not** emit window created or destroyed events, so those four events are treated as a hint to re-snapshot rather than as a complete picture, debounced at about 150ms.
A snapshot is also kicked off on every panel show, so the list is never more than one AeroSpace round trip stale.

Actions are a single invocation: `aerospace workspace <name>` for a workspace row, `aerospace focus --window-id <id>` for a window row.

### The panel

`SwitcherPanel` is an `NSPanel` created once at launch, fully laid out, and then just ordered in and out.
Never rebuilding the window is the single biggest reason this will feel faster than the alternatives.

- Style mask `[.nonactivatingPanel, .borderless]`, with `canBecomeKey` overridden to `true` so it can take keyboard focus.
- `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = true`.
  `.stationary` (meant for desktop-picture-like windows pinned to their original Space) was tried here too and caused a real, confusing bug: combined with `.canJoinAllSpaces`, the panel reported `isVisible == true` while `occlusionState` never contained `.visible` — ordered in from AppKit's perspective but never actually composited on screen. Removed.
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`, with the corner radius applied to the content view's layer.
- Content is an `NSVisualEffectView` with `material = .hudWindow`, `blendingMode = .behindWindow`, `state = .active`.
- Positioned on `NSScreen.main` (AppKit's own notion of "the screen holding the window currently receiving keyboard events"), horizontally centered, with its top edge around 22% down the visible frame, which is where Spotlight sits.
  Determining "the focused AeroSpace monitor" the literal way would mean an AeroSpace round trip before the panel can appear, which at the measured ~70-115ms cost would blow the ~20ms press-to-visible budget entirely.
  `NSScreen.main` gets the same practical answer for free, since AeroSpace's focus state and macOS's key-window state track each other in every normal case; the one place they can diverge is focusing an AeroSpace monitor whose current workspace has no windows at all, where `NSScreen.main` would still reflect wherever focus last actually was. That's an acceptable trade for keeping positioning off the critical path.
  `SwitcherItem.nsScreenNumber` (the `monitor-appkit-nsscreen-screens-id` join key) is still captured on every snapshot regardless, since it costs nothing to record and may be useful later for grouping or a corrective refresh; it just isn't on the show-time critical path.
  `NSScreen.main` is resolved **once per `show()`** and cached for the whole visible session (`SwitcherPanel.screenForCurrentSession`), not re-resolved on every reposition. This is a real bug found in testing: `EventSubscriber`'s background refreshes call `reposition(rowCount:)` continuously while the panel is open, and re-resolving `NSScreen.main` on each of those let the panel silently teleport to a different physical monitor mid-session whenever its answer changed for any transient reason, vanishing from whichever screen the user was actually looking at. A floating panel's position should track "where you were when you opened it," not "whatever the system says right now."

All colors come from semantic `NSColor` values (`labelColor`, `secondaryLabelColor`, `selectedContentBackgroundColor`) so light and dark mode both work with no branching.
All fonts come from `NSFont.systemFont(ofSize:weight:)`.
No color literal and no font name string appears anywhere in the UI code.

Layout metrics, tuned against a side-by-side screenshot of real Spotlight:

- Panel width 720pt, corner radius 20pt.
- Search field 24pt regular, borderless, no focus ring, with generous leading inset.
- A hairline separator between the field and the list.
- Row height 44pt, 28pt icon, primary label 14pt regular, secondary label 12pt in `secondaryLabelColor`.
- Up to 9 rows visible, then scroll.

The panel shows **one merged list**: workspaces first, then windows, matching the order the original `ff()` shell function presented them in.
A two-pane layout (workspaces and windows side by side) was built and tried during implementation but reverted: it required a `⌃H`/`⌃L`-style modifier-only scheme for switching between panes to avoid the same bare-key-versus-typing ambiguity that ruled out bare `hjkl`, and in practice that indirection made the tool feel more complicated to use than the single list it replaced, for no real gain — a merged list already reads top-to-bottom in the order that matters (workspaces you might already be on, then the windows within them).

The list is a view-based `NSTableView` with a single column and recycled cell views.
Selection is drawn by the cell, not by the table's default highlight, so the rounded selection pill matches the system look.

Each workspace row's subtitle is a comma-joined summary of the app names of the windows currently in it (e.g. "Chrome, Terminal"), computed once per snapshot by grouping the window list by workspace name, rather than a generic "Workspace" label.

### Focus handoff

This is where the existing tools get it wrong, so the ordering is explicit.

On show: capture nothing about the previous app, call `NSApp.activate()`, then `panel.makeKeyAndOrderFront(nil)`.

On accept: order the panel out **first**, call `NSApp.hide(nil)` so macOS returns activation to the previous app, and only **then** dispatch the `aerospace` command.
Sending the focus command before hiding lets our own deactivation land after the switch and steal focus back, which is the class of bug that makes these tools feel flaky.

On cancel via Escape, or on the panel resigning key, order out and hide with no command sent.

Because the agent runs with `.accessory` activation policy and its only window is a floating non-activating panel, AeroSpace never sees a manageable window and the layout is untouched.
This is asserted in the verification steps below rather than assumed.

### Search

`FuzzyMatcher` is a self-contained subsequence scorer in the spirit of fzf's v1 algorithm.
It awards bonuses for consecutive matched characters, for matches at a word or camel-case boundary, and for a match at the start of the haystack, and it penalizes gaps.
Each item precomputes its lowercased haystack once when the snapshot is built, so filtering is pure arithmetic over a few hundred short strings and runs synchronously on the main thread inside a single frame.

Ranking rules:

- An empty query shows AeroSpace's own listing order: workspaces, then windows.
- With a query, sort by score descending; break ties by putting workspaces above windows, then alphabetically by display text, purely for stable, predictable ordering rather than depending on incidental array order.
- A window matches against both its app name and its window title, so typing `chrome` finds every Chrome window and typing a page title finds the one.

Window titles get a light cleanup pass for display only: a trailing ` - <app name>` suffix is stripped, since Chrome and others append it to every title. The raw title is still what gets searched.

### Keyboard

Handled through the search field's delegate via `control(_:textView:doCommandBy:)`, which is the correct AppKit seam and keeps normal text editing intact.

| Key | Action |
| --- | --- |
| `↓` / `⌃N` / `⌃J` | Next row |
| `↑` / `⌃P` / `⌃K` | Previous row |
| `Return` | Focus selection, dismiss |
| `Esc` | Dismiss, no action |

`⌘1`–`⌘9` jump-to-row was in the initial design but removed before shipping; clicking a row still selects and accepts it directly.

Pressing the bound key again while the panel is open dismisses it, because the client sends `toggle` and the agent tracks visibility.
That works for whatever key is bound without Spacelight knowing what it is.

#### Why vim navigation is `⌃J` / `⌃K` and not bare `j` / `k`

Focus lives in a search field, so a bare `j` is a character the user is trying to type.
Swallowing it would make workspace names like `japanese` or window titles containing a `j` unsearchable, which is a worse bug than the one it fixes.

`⌥J` / `⌥K` are not an option either, and for a harder reason.
AeroSpace's bindings are global and consume the keystroke before any application sees it, and `~/.aerospace.toml` already binds `alt-j` and `alt-k` to `focus down` and `focus up`.
Pressing them over the panel would move focus in the tiling tree underneath rather than moving the selection.

`⌃J` and `⌃K` are free, sit adjacent to the `⌃N` / `⌃P` that AppKit already provides for free in every text field, and preserve typing.
`⌃J` is caught at the window level (`SwitcherPanel.performKeyEquivalent`) rather than in the search field's `doCommandBy:` switch, because AppKit's built-in Emacs-style text bindings already claim it as a synonym for Return (raw ASCII linefeed) at the field-editor level; catching it earlier, at the window, is what lets Spacelight claim it for navigation instead. `⌃K` needs the same treatment since it default-binds to "delete to end of line."

A bare (unmodified) `hjkl` scheme was considered and explicitly rejected: the moment `h`/`j`/`k`/`l` is pressed with an empty query, there is no way to tell "navigate" from "the first letter of a search that happens to start with that letter" — the field is empty at the instant either way, and no heuristic (timing, hold-to-navigate) resolves that without making the tool feel unpredictable. Requiring the modifier removes the ambiguity entirely at the cost of one extra key held down.

## Latency budget

The target is that pressing the bound key puts pixels on screen in about 20ms, roughly one frame after the unavoidable spawn.

| Step | Budget |
| --- | --- |
| AeroSpace `exec-and-forget` fork | ~2ms |
| Client process start (measured) | ~6ms |
| Socket connect, write, agent wakeup | < 1ms |
| Filter cached snapshot | < 1ms for a few hundred items |
| Panel order-in and first draw | ~8ms, one frame, no allocation |
| **Press to visible** | **~20ms** |
| AeroSpace refresh (measured, two concurrent invocations via `Process`) | ~85-115ms, off the main thread, off the critical path |

The refresh result is diffed against what is already displayed and only reloads rows if something actually changed, preserving the current query and selection.
Nothing in the press-to-visible path touches AeroSpace, the filesystem, or a lock, and the only process created is the ~5-6ms client.

### Open latency by scenario

| Scenario | Time to visible | Notes |
| --- | --- | --- |
| Normal press, agent warm | **~20ms** | The overwhelmingly common case. One frame at 60Hz is 16.7ms. |
| First press after boot, no login item | ~150-250ms | Once per boot. AppKit init, first WindowServer connection, font and blur warm-up, plus a cold AeroSpace snapshot. |
| First press after boot, login item installed | ~20ms | The agent already started and prewarmed at login, so the cold start is paid before you ever press. |
| Press right after a crash | ~150-250ms | Stale socket detected, agent respawned. Same as a cold start. |
| Typing a character | < 1ms | Filter over a few hundred cached items, no I/O. |
| Enter to focused window | ~70ms (measured, single `Process` invocation) | After the panel is already gone, so it is not perceived as panel latency. |

For reference, the current `fzf` approach spends roughly 400-900ms spawning Terminal and loading the zsh profile, and permanently disturbs the layout.
The gap that matters is not 20ms versus 140ms, it is 20ms versus most of a second plus a window shuffle.

## System resources when idle

The agent is genuinely idle between presses, not merely quiet.
There is no timer, no polling loop, and no run loop wakeup source other than two blocking file descriptors: the control socket waiting on `accept`, and the pipe from `aerospace subscribe` waiting on `read`.
This is the single most important property for background residency, because on Apple silicon it is timer wakeups rather than memory that drive energy impact.

| Resource | Idle cost | Notes |
| --- | --- | --- |
| CPU | ~0.0% | Both descriptors block. No timers, no polling, no periodic refresh. |
| Wakeups | Only on a real AeroSpace event or a keypress | Activity Monitor should report Energy Impact of 0. |
| Memory, `spacelight --agent` | ~30-45MB RSS, ~15-25MB private | An AppKit process with one window. Swift runtime, AppKit, and CoreUI are all in the OS shared cache and shared with every other app, so private dirty memory is the honest figure. |
| Memory, `aerospace subscribe` child | ~10-15MB RSS | The AeroSpace CLI held open for the event stream. |
| Memory, icon cache | ~1-3MB | Bounded by distinct running apps, typically under 15. `NSImage` references, not decoded bitmaps. |
| Processes | 2 resident, plus a ~5-6ms transient per press | The agent and its `subscribe` child. |
| Disk | ~2-3MB | One binary. The Swift stdlib is ABI-stable and lives in the OS, so it is not bundled. |

Two honest caveats.

The ~15MB figure quoted earlier in this conversation was too optimistic; it was the private-memory number, not what Activity Monitor shows in its Memory column.
Any AppKit process carries a floor of roughly 25-30MB RSS that no amount of care removes, and the numbers above are estimates to be replaced with measurements at milestone 4.

Holding an `aerospace subscribe` child open is a real cost of about 10-15MB that pure polling would avoid.
It is worth it because polling would mean a timer, and a timer would mean wakeups forever, which is worse for battery than the memory is for anything.
If the measured memory cost comes in materially higher than expected, the fallback is to drop the subscription and refresh only on panel show, which costs the measured ~85-115ms snapshot round trip as staleness on open and nothing else.

## Repository layout

```
Package.swift
Makefile
Sources/Spacelight/
  main.swift                     arg dispatch: client path vs --agent path
  Client/Client.swift            Darwin socket write, kept minimal for spawn cost
  Client/AgentLauncher.swift     posix_spawn --agent, bounded wait for socket
  Agent/ControlSocket.swift      listener, verb parsing, single-instance bind
  AppDelegate.swift              wiring, lifecycle, prewarm
  Support/Config.swift           JSON config, defaults
  Support/Paths.swift            socket + config paths, one definition
  Support/Logging.swift          os.Logger + signposts for the latency budget
  AeroSpace/AeroSpaceClient.swift   process runner, snapshot queries, actions
  AeroSpace/EventSubscriber.swift   long-lived subscribe --all reader
  AeroSpace/SnapshotParser.swift    tab-delimited parsing, pure and testable
  Model/SwitcherItem.swift       workspace or window, precomputed haystack
  Model/StateStore.swift         @MainActor cache, diffing
  Search/FuzzyMatcher.swift      scoring + ranking
  UI/SwitcherPanel.swift         the NSPanel subclass
  UI/SwitcherViewController.swift  field, table, key handling, placement
  UI/ResultRowView.swift         one row, icon + labels + selection pill
  UI/IconCache.swift             bundle path → NSImage, memoized
Tests/SpacelightTests/
  SnapshotParserTests.swift      fixtures with tabs, unicode, empty titles
  FuzzyMatcherTests.swift        ordering and scoring expectations
  ControlSocketTests.swift       verb parsing, stale socket recovery
```

Client and agent are one executable target, so the client path is measured to run at ~5-6ms regardless of what `Client/Client.swift` itself imports, since the Mach-O it ships in already links AppKit for the agent code elsewhere in the same target.
A CI check restricting imports in `Client/` would not change that number, so none is added; `Client/Client.swift` still avoids Foundation on principle, to keep the one hot path free of unnecessary allocation, but this is a code-quality habit rather than a load-bearing performance requirement.

There is deliberately **no `.app` bundle**.
The deliverable is one binary, which is exactly what the AeroSpace binding needs to name, and `make install` simply copies it to `/usr/local/bin/spacelight`.

Dropping the bundle removes the `Info.plist`, the assembly script, and the `/Applications` install step.
The one thing the bundle was carrying, `LSUIElement`, is replaced by the agent calling `NSApp.setActivationPolicy(.accessory)` as its first act, which has the same effect of no Dock icon, no menu bar, and no `⌘Tab` entry.
Because Spacelight needs no Accessibility, Screen Recording, or other TCC permission, it never needs the stable bundle identity that a TCC prompt would require, which is what usually forces a bundle in this kind of app.

The binary is ad-hoc signed with `codesign -s -` as part of `make`, which costs nothing and keeps Gatekeeper quiet on first run.

## Build order

1. **Skeleton.** `Package.swift`, `main.swift`, `Makefile`. `spacelight --agent` launches with `.accessory` policy, no Dock icon, and does nothing else. Confirms the single-binary story before any real code depends on it.
2. **AeroSpace bridge.** `AeroSpaceClient` and `SnapshotParser` with tests, driven from a temporary debug log line. Prove the two queries parse cleanly against this machine's real 17 workspaces and 12 windows, including the Chrome titles that contain `|` and `*`.
3. **Client and agent split.** `main.swift` arg dispatch, `ControlSocket`, `Client`, `AgentLauncher`. Prove that a bare `spacelight` cold-starts the agent, that a second invocation is served by the existing one, and that a stale socket is recovered from. Time the client and confirm it stays near the measured 5-6ms.
4. **Panel shell.** Prewarmed `NSPanel`, blur, search field, empty table, `toggle` showing and hiding it. This is the point to stop and compare against real Spotlight on screen and tune the metrics.
5. **List and search.** `SwitcherItem`, `StateStore`, `FuzzyMatcher`, `ResultRowView`, `IconCache`. The panel now shows and filters real data.
6. **Actions and focus handoff.** Enter dispatches the command in the correct hide-then-switch order.
7. **Live cache.** `EventSubscriber` wired to debounced refresh, diffed reloads.
8. **Polish.** Config file, optional `SMAppService` login item registration to skip even the first cold start, signpost instrumentation, and the `~/.aerospace.toml` change that swaps the `osascript` Terminal binding for `exec-and-forget /usr/local/bin/spacelight`.

## Verification

Unit level:

```
swift test
```

covers parsing, ranking, and socket verb handling, including titles with tabs stripped, empty window lists, and expected result ordering for queries like `chr`, `dev`, and a partial page title.

End to end, on this machine, with real windows open across both monitors.
Replace the existing `alt-space` line in `~/.aerospace.toml` with a binding to the new command, on whatever key is preferred, and let the config auto-reload:

```toml
alt-space = 'exec-and-forget /usr/local/bin/spacelight'
```

1. `make install`, which places one binary at `/usr/local/bin/spacelight` and nothing else. Confirm nothing is running yet with `pgrep -fl spacelight`.
2. **Cold start works with no setup.** Press the bound key. The agent starts itself and the panel appears. `pgrep -fl spacelight` now shows exactly one agent. Press again and confirm the count stays at one.
3. **No Dock presence.** Confirm no Dock icon and no entry in `⌘Tab` while the agent runs.
4. **Layout is untouched.** Note the exact window positions on the focused workspace. With the panel open, run `aerospace list-windows --all` from a second terminal on another workspace. Spacelight must not appear in that list, and no window may have moved. This is the specific failure of the current `fzf` approach and is the primary acceptance test.
5. **Workspace switch.** Press the key, type `dev`, press Enter. The `dev` workspace is focused, the panel is gone, and no Terminal or other artifact is left behind.
6. **Window switch across monitors.** From a workspace on the built-in display, type part of a window title living on a workspace on the external monitor, press Enter. That exact window is focused and is genuinely key, meaning keystrokes land in it immediately with no extra click.
7. **Escape.** Press the key then Escape. Focus returns to the window that was focused before, with the layout unchanged.
8. **Toggle.** Press the key twice in quick succession. The panel opens and closes, with no second agent spawned.
9. **Freshness.** Open a new window, immediately press the key. The new window is listed.
10. **Rebinding.** Change the binding to a different key in `~/.aerospace.toml` and confirm it works with no Spacelight restart, no Spacelight config change, and no rebuild.
11. **Crash recovery.** `pkill -9 spacelight`, leaving a stale socket file, then press the key. A fresh agent starts and the panel appears.
12. **Appearance.** Screenshot the panel next to real Spotlight in both light and dark mode at 1x and 2x. Compare corner radius, blur, row height, font size and weight, and selection pill. Iterate on the metrics until they match.
13. **Vim keys.** With a query typed, confirm `⌃J` and `⌃K` move the selection while bare `j` and `k` still type into the field. Separately confirm `⌥J` and `⌥K` are correctly swallowed by AeroSpace, since that is the documented reason they are not used.
14. **Latency.** Time repeated calls to `/usr/local/bin/spacelight ping` to confirm the client stays near 5-6ms, then `log stream --predicate 'subsystem == "com.spacelight"'` while pressing the key repeatedly to confirm the press-to-visible signpost interval stays around 20ms.
15. **Idle cost.** Leave the agent running for an hour untouched, then check Activity Monitor. CPU must read 0.0%, Energy Impact 0, and idle wakeups near zero. Record real RSS for both the agent and its `subscribe` child, and replace the estimates in the resources table with the measurements.
