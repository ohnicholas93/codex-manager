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

Project layout:

```text
codex-manager.sh   # entrypoint and module loader
lib/               # implementation modules
```

## Requirements

- `bash`
- `curl` for fast direct limit checks
- `python3` for moving session provider metadata and rotating local thread IDs
- `tmux` and `codex` for optional fallback when direct checks fail
- Standard Unix utilities: `find`, `sed`, `awk`, `cp`, `rm`, `ln`, `install`

## Usage

```bash
codex-manager list
codex-manager get [--tmux-fallback|--no-tmux-fallback]
codex-manager use [--move] [--move-days DAYS] <name>
codex-manager rotate-ids [--apply]
codex-manager rotate
```

## Commands

### `list`

Lists all available profiles from `$CODEX_HOME/profiles/*.json`.
The currently active profile is marked with `#` when `$CODEX_HOME/auth.json`
exactly matches a profile file.

```bash
codex-manager list
```

### `use <name>`

Activates a profile by replacing `$CODEX_HOME/auth.json` with a symlink to
`$CODEX_HOME/profiles/<name>.json`. This lets Codex token refreshes update the
profile file itself.

If `$CODEX_HOME/config.toml` contains `[model_providers.<name>]`, `use <name>`
also sets the root `model_provider = "<name>"` entry. Existing commented
root `model_provider` lines are uncommented and replaced when there is no
active root `model_provider` line. If no root `model_provider` line exists, one
is inserted at the top of the file.

When switching back to a ChatGPT subscription profile, any active root
`model_provider = ...` line is commented out so Codex uses OpenAI again.
API-key-only profiles without a matching `[model_providers.<name>]` table leave
`config.toml` unchanged.

```bash
codex-manager use gmail
```

When switching to a different provider, existing rollout files in
`$CODEX_HOME/sessions/` and the Desktop thread index keep their current
`model_provider` unless you opt in. `use` prints how many sessions would change
and recommends the exact command to rerun.

To migrate those session files and indexed Desktop threads while activating the
profile:

```bash
codex-manager use --move gmail
```

By default, `--move` only migrates rollout files with an `mtime` in the last 30
days. Codex Manager preserves each file's original `mtime` after rewriting
session metadata, so this uses the same timestamp Codex can rely on for
last-edited ordering. After the rollout rewrite, Codex Manager also updates
matching rows in `$CODEX_HOME/state_*.sqlite` so Codex Desktop does not keep
reopening moved threads through stale persisted provider metadata.

Before counting or rewriting rollouts, Codex Manager checks `/proc` for active
Codex processes that already have the file open. Hot active rollouts are excluded
from the count, rechecked immediately before replacement, skipped during
migration, and reported instead of being replaced under a running writer. This is
a best-effort guard because Codex does not currently provide a cooperative
migration lock. If Codex Manager detects an active deleted rollout file
descriptor, it warns that a previous live rewrite may already have detached
persisted history.

```bash
codex-manager use --move --move-days 7 gmail
```

Use `-1` to migrate all sessions regardless of age:

```bash
codex-manager use --move --move-days -1 gmail
```

Custom provider targets write the profile name as the session provider. OpenAI
subscription targets write `openai`.

### Rotating local thread IDs

Codex uses a thread's id as the upstream `prompt_cache_key`. To intentionally
break prompt-cache continuity for all locally discoverable sessions without
changing providers, use:

```bash
codex-manager rotate-ids
```

The command is a dry run by default. It scans both `$CODEX_HOME/sessions/` and
`$CODEX_HOME/archived_sessions/`, plus matching Desktop thread-index rows, and
prints every eligible old-id to new-id rewrite. To apply the migration:

```bash
codex-manager rotate-ids --apply
```

Active rollouts that are open by a running Codex process are skipped and
reported. Inactive rollout files are written under their new filename before
the old filename is removed, with original file modes and mtimes preserved.
Codex Manager also updates local SQLite thread references, rollout paths, and
thread-name index entries so resumed threads use the new ids.

To back up the existing active `auth.json` before replacement:

```bash
CODEX_MANAGER_BACKUP=1 codex-manager use gmail
```

### `get`

Checks account limits for every profile in parallel.

When `curl` is available, Codex Manager reads each profile JSON and calls the
same Codex usage endpoint directly. This avoids launching Codex sessions and is
the preferred path.

If the direct usage request fails and the profile contains a `refresh_token`,
Codex Manager calls the ChatGPT OAuth refresh endpoint, persists any returned
tokens back to the profile JSON, and retries the usage request once.

By default, direct checking failures are reported without launching Codex. To
allow a tmux fallback for profiles whose direct check fails, run:

```bash
codex-manager get --tmux-fallback
```

For that fallback, Codex Manager:

1. Creates an isolated temp Codex home at `${XDG_CACHE_HOME:-~/.cache}/codex-manager/<profile>/`.
2. Symlinks the profile JSON into that temp home as `auth.json`.
3. Writes a temp `config.toml` that trusts that temp home.
4. Starts a detached tmux session in that temp workspace.
5. Runs `codex --yolo`.
6. Polls `/status` until Codex reports refreshed limit data.
7. Prints a per-profile table with 5h and weekly availability.
8. Marks the recommended rotate target with `*`.
9. Marks the currently active profile with `#` when `$CODEX_HOME/auth.json`
   exactly matches a profile file.

```bash
codex-manager get
```

The direct path does not use `jq`. It may update profile JSON files when token
refresh is needed. The tmux fallback may create live Codex session activity for
accounts that need fallback, so it only runs when `--tmux-fallback` is passed.

### `rotate`

Runs `get`, chooses the best available profile, then activates it with
`use <name>`.

```bash
codex-manager rotate
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
| `CODEX_MANAGER_STATUS_KEY_DELAY` | `0.5` | Delay before pressing Enter after typing `/status`. |
| `CODEX_MANAGER_TMUX_WIDTH` | `160` | Detached tmux pane width used for status rendering. |
| `CODEX_MANAGER_TMUX_HEIGHT` | `40` | Detached tmux pane height used for status rendering. |
| `CODEX_MANAGER_DIRECT_TIMEOUT` | `20` | Seconds to wait for direct usage API response. |
| `CODEX_MANAGER_DIRECT_CONNECT_TIMEOUT` | `5` | Seconds to wait for direct usage API connection. |
| `CODEX_MANAGER_USAGE_URL` | `https://chatgpt.com/backend-api/wham/usage` | Direct usage endpoint. |
| `CODEX_REFRESH_TOKEN_URL_OVERRIDE` | `https://auth.openai.com/oauth/token` | Refresh token endpoint override. |
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

The installed command resolves the real script path, so the `lib/` directory
beside `codex-manager.sh` is loaded correctly through the symlink.

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

- Direct `get` does not modify the real `$CODEX_HOME/auth.json`.
- Direct `get` can modify profile JSON files when refreshing expired access tokens.
- `get --tmux-fallback` can update profile files if Codex refreshes tokens.
- `use` and `rotate` replace the real `$CODEX_HOME/auth.json` symlink.
- Profile names must contain only letters, numbers, dots, underscores, or hyphens.
- Detached tmux sessions and temp files created by `get` are cleaned up when the script exits, including Ctrl+C.
