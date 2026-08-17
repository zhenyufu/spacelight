# Spacelight

A Spotlight-style workspace and window switcher for [AeroSpace](https://github.com/nikitabobko/AeroSpace) on macOS.

Press your chosen key binding (eg. alt-f), a floating panel appears over the current screen, use jk to select workspaces, type / to fuzzy-search your workspaces and windows, press Return to jump there.
The panel never disturbs your window layout, needs no Accessibility permission, and stays idle at ~0% CPU between uses. Only non empty workspaces are shown
## Demo 
<img src="demo/spacelight_demo" alt="Spacelight switching workspaces" width="720">  

## Requirements

- macOS 14 or later
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) installed and running
- Xcode 16 or later (or the matching Swift 6 toolchain) to build from source


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

Spacelight does **not** register a global hotkey of its own, and depends on your AeroSpace config for setting up a key binding.

Add a binding to `~/.aerospace.toml` under `[mode.main.binding]`, replacing `YOUR_USERNAME` with your own:

```toml
[mode.main.binding]
    alt-f = 'exec-and-forget /Users/YOUR_USERNAME/.local/bin/spacelight'
```

Use the full path rather than a bare `spacelight`, since `exec-and-forget` does not run through your shell's `PATH`. Reload your config. 

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


The list shows:
- **Workspaces** that currently have windows in them, each with a summary of the apps inside (e.g. `Chrome, Terminal`). Empty workspaces are skipped, since your existing `alt-1`-style bindings already cover visiting those.
- **Windows** across every workspace, searchable by both app name and window title.

## How it runs

Spacelight keeps a small background process running that holds the panel and a cached copy of your AeroSpace state, so pressing your key reveals something that already exists rather than building it.

You never start that process yourself.
The first key press starts it, and it comes back on its own after a reboot or a crash: no setup step, no login item.

### Other commands

Mostly useful for debugging or scripting:

```sh
spacelight            # same as `spacelight toggle`
spacelight toggle     # show the panel, or hide it if already showing
spacelight show       # show the panel
spacelight hide       # hide the panel
spacelight ping       # check Spacelight is running and can reach AeroSpace
spacelight quit       # stop the background process
```

## Development

```sh
make build            # release build
make test             # run the test suite
make run-agent        # run in the foreground, logging to the terminal
```

To watch what Spacelight is doing:

```sh
log stream --predicate 'subsystem == "com.spacelight"' --level debug
```

Note that `.debug`-level messages are not persisted by the unified logging system, so they exist only while something is actively streaming them. `log stream` has to be running *before* you reproduce an issue, or there will be nothing to read afterwards.

## License

MIT. See `LICENSE`.
