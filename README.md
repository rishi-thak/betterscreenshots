# SSClipboard

Invisible macOS screenshot agent that:

- owns global screenshot hotkeys
- captures the screen directly and copies immediately to the clipboard
- saves each capture into the active macOS screenshot folder
- offers transient `Share` and `Delete` actions in a lightweight overlay

## Hotkeys

This app registers:

- `cmd+shift+3` for full-screen capture
- `cmd+shift+4` for region capture

For those exact shortcuts to work reliably, disable or rebind the native macOS screenshot shortcuts in:

`System Settings > Keyboard > Keyboard Shortcuts > Screenshots`

## Why there is an overlay instead of modifying the system screenshot thumbnail

macOS does not provide a public API for third-party apps to inject buttons into the built-in screenshot preview thumbnail in the bottom-right corner. This app stays invisible in the Dock and runs as an agent, but it uses its own transient panel for `Share` and `Delete`.

## Build

```bash
./scripts/build_app.sh
```

The built app bundle is written to:

```text
dist/SSClipboard.app
```

## Install as a login agent

```bash
./scripts/install_launch_agent.sh
```

This copies the app to `~/Applications/SSClipboard.app` and loads a LaunchAgent so it starts automatically at login.
