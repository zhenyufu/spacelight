# Spacelight

A Spotlight-style workspace and window switcher for [AeroSpace](https://github.com/nikitabobko/AeroSpace) on macOS.

Press your chosen key, a floating panel appears over whatever you were doing, type to fuzzy-search your workspaces and windows, press Return to jump there.
The panel never disturbs your window layout, needs no Accessibility permission, and stays idle at ~0% CPU between uses.

## Requirements

- macOS 14 or later
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) installed and running
- Xcode 16 or later (or the matching Swift 6 toolchain) to build from source

Spacelight needs **no Accessibility, Screen Recording, or other permissions of its own**.
It asks the already-running AeroSpace process to move focus, and AeroSpace is the one holding those permissions.

## Install

Build and install from source:

```sh
git clone https://github.com/zhenyufu/spacelight.git
cd spacelight
make install
```

That installs a single binary to `~/.local/bin/spacelight`. No `sudo` needed.

To remove it again:

```sh
make uninstall
```

## Set up the keybinding

Spacelight deliberately does **not** register a global hotkey of its own.
No key combination is baked into the app, so all of your bindings stay in one file and no key can be silently claimed by something invisible from your AeroSpace config.

Add a binding to `~/.aerospace.toml` under `[mode.main.binding]`, replacing `YOUR_USERNAME` with your own:

```toml
[mode.main.binding]
    alt-f = 'exec-and-forget /Users/YOUR_USERNAME/.local/bin/spacelight'
```

Use the full path rather than a bare `spacelight`, since `exec-and-forget` does not run through your shell's `PATH`.

If you have `auto-reload-config = true` in your config, saving the file is enough.
Otherwise reload AeroSpace's config manually (`alt-shift-semicolon` then `esc` in the default config, or run `aerospace reload-config`).

Any key works — `alt-f` is just an example. To use something else, change the key on the left; Spacelight neither knows nor cares which key launched it, so no rebuild or app-side config change is needed.

## Usage

Press your bound key to open the panel. Press it again to close.

The panel opens in **navigation mode** with your current workspace already highlighted, so you can move and jump without touching the search field. Press `/` to start searching. A footer along the bottom always lists the keys available in the current mode.

Navigation mode:

| Key | Action |
| --- | --- |
| `j` / `k` or `↓` / `↑` | Move the selection |
| `Return` | Switch to the selected workspace or window |
| `/` | Start searching |
| `Esc` | Close the panel |
| Click a row | Switch to it directly |

Search mode:

| Key | Action |
| --- | --- |
| Type anything | Fuzzy-filter workspaces and windows |
| `↓` / `↑` or `⌃J` / `⌃K` | Move the selection |
| `Return` | Switch to the selected workspace or window |
| `Esc` | Cancel the search and return to navigation mode |

The two modes exist so that bare `j` and `k` can navigate. That only works while the search field is unfocused: with focus in a text field there is no way to tell "move down" from "the first letter of a query starting with `j`" at the moment the key is pressed. Hence `/` to search explicitly, and `⌃J` / `⌃K` while searching for anyone who prefers to keep their hands off the arrow keys.

Escape is two-level: the first press cancels a search, the second closes the panel, so a mistyped query never costs you the whole session.

The list shows:

- **Workspaces** that currently have windows in them, each with a summary of the apps inside (e.g. `Chrome, Terminal`). Empty workspaces are skipped, since your existing `alt-1`-style bindings already cover visiting those.
- **Windows** across every workspace, searchable by both app name and window title.

## How it runs

Spacelight is one binary that plays two roles.
Run bare, it is a thin client: it sends a message to the background agent over a unix socket and exits in a few milliseconds.
Run as `spacelight --agent`, it is that agent — the process that holds the prewarmed panel and a warm cache of your AeroSpace state.

You never have to start the agent yourself.
The first time you press your key, the client notices nobody is listening, starts the agent, and shows the panel.
It survives reboots and crashes the same way, so there is no setup step and no login item to configure.

That split is what makes it feel instant: the panel and its data already exist before you press the key, so opening it is not building anything.

### Other commands

Mostly useful for debugging or scripting:

```sh
spacelight            # same as `spacelight toggle`
spacelight toggle     # show the panel, or hide it if already showing
spacelight show       # show the panel
spacelight hide       # hide the panel
spacelight ping       # verify the agent is alive and can reach AeroSpace
spacelight quit       # stop the background agent
```

## Development

```sh
make build            # release build
make test             # run the test suite
make run-agent        # run the agent in the foreground, logging to the terminal
```

To watch what the agent is doing:

```sh
log stream --predicate 'subsystem == "com.spacelight"' --level debug
```

Note that `.debug`-level messages are not persisted by the unified logging system — they exist only while something is actively streaming them. `log stream` has to be running *before* you reproduce an issue, or there will be nothing to read afterwards.

## License

MIT. See `LICENSE`.
