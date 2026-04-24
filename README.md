# Codex Manager

`codex-manager.sh` is a small Bash utility for managing multiple Codex
accounts by swapping the active `$CODEX_HOME/auth.json` from named profiles.

By default, Codex uses:

```bash
CODEX_HOME=~/.codex
```

Codex Manager stores all account profiles in:

```bash
$CODEX_HOME/profiles/
```

Each profile is a unique `auth.json` file. The profile name is the filename
without `.json`.

Example:

```text
~/.codex/
  auth.json
  profiles/
    gmail.json
    nitrous.json
    nicholas.json
```

## Requirements

- `bash`
- `tmux`
- `codex`
- Standard Unix utilities: `find`, `sed`, `awk`, `cp`, `rm`, `install`

## Usage

```bash
./codex-manager.sh list
./codex-manager.sh get
./codex-manager.sh use <name>
./codex-manager.sh rotate
```

## Commands

### `list`

Lists all available profiles from `$CODEX_HOME/profiles/*.json`.
The currently active profile is marked with `#` when `$CODEX_HOME/auth.json`
exactly matches a profile file.

```bash
./codex-manager.sh list
```

### `use <name>`

Activates a profile by replacing `$CODEX_HOME/auth.json` with
`$CODEX_HOME/profiles/<name>.json`.

```bash
./codex-manager.sh use gmail
```

To back up the existing active `auth.json` before replacement:

```bash
CODEX_MANAGER_BACKUP=1 ./codex-manager.sh use gmail
```

### `get`

Checks account limits for every profile in parallel.

For each profile, Codex Manager:

1. Creates an isolated temp Codex home at `${XDG_CACHE_HOME:-~/.cache}/codex-manager/<profile>/`.
2. Copies the profile JSON to that temp home as `auth.json`.
3. Writes a temp `config.toml` that trusts that temp home.
4. Starts a detached tmux session in that temp workspace.
5. Runs `codex --yolo`.
6. Polls `/status` until Codex reports refreshed limit data.
7. Prints a per-profile table with 5h and weekly availability.
8. Marks the recommended rotate target with `*`.
9. Marks the currently active profile with `#` when `$CODEX_HOME/auth.json`
   exactly matches a profile file.

```bash
./codex-manager.sh get
```

This command launches real Codex sessions, so it may create live session
activity for each account.

### `rotate`

Runs `get`, chooses the best available profile, then activates it with
`use <name>`.

```bash
./codex-manager.sh rotate
```

The selection score is:

```text
min(5h percent left, weekly percent left)
```

Ties prefer the higher 5h value, then the higher weekly value.

## Environment

| Variable | Default | Description |
| --- | --- | --- |
| `CODEX_HOME` | `~/.codex` | Codex home containing `auth.json` and `profiles/`. |
| `CODEX_MANAGER_TMP_ROOT` | `${XDG_CACHE_HOME:-~/.cache}/codex-manager` | Temp root for isolated profile checks. |
| `CODEX_MANAGER_READY_TIMEOUT` | `60` | Seconds to wait for Codex startup. |
| `CODEX_MANAGER_STATUS_TIMEOUT` | `90` | Seconds to wait for refreshed limits. |
| `CODEX_MANAGER_STATUS_INTERVAL` | `1` | Seconds between `/status` attempts. |
| `CODEX_MANAGER_STATUS_KEY_DELAY` | `0.2` | Delay before pressing Enter after typing `/status`. |
| `CODEX_MANAGER_TMUX_WIDTH` | `160` | Detached tmux pane width used for status rendering. |
| `CODEX_MANAGER_TMUX_HEIGHT` | `40` | Detached tmux pane height used for status rendering. |
| `CODEX_MANAGER_BACKUP` | `0` | Set to `1` to back up active `auth.json` before `use` or `rotate`. |

## Installing

Run the installer:

```bash
./install.sh
```

It creates this symlink:

```bash
~/.local/bin/codex-manager -> ./codex-manager.sh
```

It also adds this line to `~/.bashrc` if it is not already present:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

After installing, restart your shell or run:

```bash
source ~/.bashrc
codex-manager list
```

## Notes

- `get` does not modify the real `$CODEX_HOME/auth.json`.
- `use` and `rotate` do modify the real `$CODEX_HOME/auth.json`.
- Profile names must contain only letters, numbers, dots, underscores, or hyphens.
- Detached tmux sessions and temp files created by `get` are cleaned up when the script exits, including Ctrl+C.
