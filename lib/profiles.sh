codex_home() {
  local home="${CODEX_HOME:-$DEFAULT_CODEX_HOME}"
  case "$home" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${home#~/}" ;;
    *) printf '%s\n' "$home" ;;
  esac
}

profiles_dir() {
  printf '%s/profiles\n' "$(codex_home)"
}

profile_path() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid profile name: $name"
  printf '%s/%s.json\n' "$(profiles_dir)" "$name"
}

profile_names() {
  local dir
  dir="$(profiles_dir)"
  [[ -d "$dir" ]] || die "profiles directory does not exist: $dir"

  find "$dir" -maxdepth 1 -type f -name '*.json' -printf '%f\n' \
    | sed 's/\.json$//' \
    | sort
}

active_profile_names() {
  local home dir auth profile file
  home="$(codex_home)"
  dir="$(profiles_dir)"
  auth="$home/auth.json"

  [[ -f "$auth" && -d "$dir" ]] || return 0

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    file="$dir/$profile.json"
    if cmp -s "$auth" "$file"; then
      printf '%s\n' "$profile"
    fi
  done < <(profile_names)
}

config_path() {
  printf '%s/config.toml\n' "$(codex_home)"
}

toml_has_model_provider_table() {
  local file="$1"
  local name="$2"

  [[ -f "$file" ]] || return 1

  awk -v table="[model_providers.${name}]" '
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == table) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

profile_has_subscription_shape() {
  local file="$1"
  local auth_json

  [[ -f "$file" ]] || return 1
  auth_json="$(<"$file")"
  json_has_required_profile_shape "$auth_json"
}

profile_provider_kind() {
  local name="$1"
  local file="$2"
  local config

  config="$(config_path)"
  if [[ -n "$name" && -f "$config" ]] && toml_has_model_provider_table "$config" "$name"; then
    printf 'custom\n'
    return 0
  fi

  if profile_has_subscription_shape "$file"; then
    printf 'openai\n'
    return 0
  fi

  printf 'unknown\n'
}

ordered_profile_names() {
  local profile file kind order

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    file="$(profile_path "$profile")"
    kind="$(profile_provider_kind "$profile" "$file")"
    case "$kind" in
      openai) order=0 ;;
      custom) order=1 ;;
      *) order=2 ;;
    esac
    printf '%s\t%s\n' "$order" "$profile"
  done < <(profile_names) | sort -t $'\t' -k1,1n -k2,2 | cut -f2-
}

active_profile_name() {
  local home dir auth auth_real dir_real profile file
  home="$(codex_home)"
  dir="$(profiles_dir)"
  auth="$home/auth.json"

  if [[ -L "$auth" && -d "$dir" ]]; then
    auth_real="$(readlink -f "$auth" 2>/dev/null || true)"
    dir_real="$(readlink -f "$dir" 2>/dev/null || true)"
    if [[ -n "$auth_real" && -n "$dir_real" ]]; then
      case "$auth_real" in
        "$dir_real"/*.json)
          profile="${auth_real##*/}"
          profile="${profile%.json}"
          if [[ "$profile" =~ ^[A-Za-z0-9._-]+$ && -f "$(profile_path "$profile")" ]]; then
            printf '%s\n' "$profile"
            return 0
          fi
          ;;
      esac
    fi
  fi

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    file="$(profile_path "$profile")"
    [[ -f "$file" ]] || continue
    printf '%s\n' "$profile"
    return 0
  done < <(active_profile_names)
}

active_provider_name() {
  local kind profile file target

  target="$(codex_home)/auth.json"
  [[ -e "$target" ]] || return 0

  profile="$(active_profile_name)"
  if [[ -n "$profile" ]]; then
    file="$(profile_path "$profile")"
    kind="$(profile_provider_kind "$profile" "$file")"
    provider_name_for_kind "$kind" "$profile" 2>/dev/null || true
    return 0
  fi

  if profile_has_subscription_shape "$target"; then
    printf 'openai\n'
  fi
}

provider_name_for_kind() {
  local kind="$1"
  local profile="$2"

  case "$kind" in
    openai) printf 'openai\n' ;;
    custom) printf '%s\n' "$profile" ;;
    *) return 1 ;;
  esac
}

session_provider_change_count() {
  local provider="$1"
  local move_window_days="$2"
  session_provider_rewrite count "$(codex_home)/sessions" "$provider" "$move_window_days"
}

move_session_providers() {
  local provider="$1"
  local move_window_days="$2"
  session_provider_rewrite write "$(codex_home)/sessions" "$provider" "$move_window_days"
}

session_provider_rewrite() {
  local mode="$1"
  local sessions_dir="$2"
  local provider="$3"
  local move_window_days="$4"

  have python3 || die "python3 is required to rewrite session provider metadata"

  python3 - "$mode" "$sessions_dir" "$provider" "$move_window_days" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

mode, sessions_dir, target_provider, move_window_days_raw = sys.argv[1:5]
write_changes = mode == "write"
root = Path(sessions_dir)

if not root.is_dir():
    print(0)
    sys.exit(0)

try:
    root_resolved = root.resolve()
except OSError:
    root_resolved = root.absolute()

try:
    move_window_days = int(move_window_days_raw)
except ValueError:
    print(f"invalid move window days: {move_window_days_raw}", file=sys.stderr)
    sys.exit(2)

cutoff_mtime = None
if move_window_days >= 0:
    cutoff_mtime = time.time() - (move_window_days * 86400)

changed_sessions = 0
skipped_hot_sessions = 0
skipped_changed_sessions = 0

def process_looks_like_codex(proc):
    try:
        comm = (proc / "comm").read_text(errors="ignore").strip().lower()
    except OSError:
        comm = ""

    if comm == "codex":
        return True

    try:
        exe = os.readlink(proc / "exe")
    except OSError:
        exe = ""

    if Path(exe).name.lower() == "codex":
        return True

    try:
        cmdline = (proc / "cmdline").read_bytes()
    except OSError:
        return False

    argv = [arg for arg in cmdline.split(b"\0") if arg]
    if not argv:
        return False

    try:
        argv0 = argv[0].decode("utf-8", errors="ignore")
    except UnicodeDecodeError:
        return False

    if Path(argv0).name.lower() == "codex":
        return True

    return False

def open_codex_rollout_state():
    open_inodes = set()
    deleted_rollouts = []
    proc_root = Path("/proc")

    if not proc_root.is_dir():
        return open_inodes, deleted_rollouts

    for proc in proc_root.iterdir():
        if not proc.name.isdigit():
            continue
        if not process_looks_like_codex(proc):
            continue

        fd_dir = proc / "fd"
        try:
            fds = list(fd_dir.iterdir())
        except OSError:
            continue

        for fd in fds:
            try:
                target = os.readlink(fd)
            except OSError:
                target = ""

            if "rollout-" in target and target.endswith(".jsonl (deleted)"):
                deleted_path = target[:-10]
                try:
                    if Path(deleted_path).resolve(strict=False).is_relative_to(root_resolved):
                        deleted_rollouts.append((proc.name, target))
                except OSError:
                    pass

            try:
                fd_stat = fd.stat()
            except OSError:
                continue

            open_inodes.add((fd_stat.st_dev, fd_stat.st_ino))

    return open_inodes, deleted_rollouts

open_rollout_inodes, deleted_rollout_fds = open_codex_rollout_state()

def record_deleted_rollouts(items):
    seen = set(deleted_rollout_fds)
    for item in items:
        if item not in seen:
            deleted_rollout_fds.append(item)
            seen.add(item)

for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue

    try:
        original_stat = path.stat()
    except OSError:
        continue

    if cutoff_mtime is not None and original_stat.st_mtime < cutoff_mtime:
        continue

    try:
        original_lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except (OSError, UnicodeDecodeError):
        continue

    new_lines = []
    session_changed = False
    saw_session_meta = False

    for line in original_lines:
        newline = "\n" if line.endswith("\n") else ""
        raw = line[:-1] if newline else line

        if not saw_session_meta:
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                new_lines.append(line)
                continue

            if item.get("type") == "session_meta" and isinstance(item.get("payload"), dict):
                saw_session_meta = True
                payload = item["payload"]
                if payload.get("model_provider") != target_provider:
                    session_changed = True
                    payload["model_provider"] = target_provider
                    new_lines.append(json.dumps(item, separators=(",", ":")) + newline)
                    continue

        new_lines.append(line)

    if not session_changed:
        continue

    if (original_stat.st_dev, original_stat.st_ino) in open_rollout_inodes:
        skipped_hot_sessions += 1
        action = "skipping" if write_changes else "excluding"
        print(f"warning: {action} hot active Codex session rollout: {path}", file=sys.stderr)
        continue

    if not write_changes:
        changed_sessions += 1
        continue

    tmp = path.with_name(path.name + ".tmp.codex-manager")
    try:
        tmp.write_text("".join(new_lines), encoding="utf-8")
        os.chmod(tmp, original_stat.st_mode)

        latest_open_rollout_inodes, latest_deleted_rollout_fds = open_codex_rollout_state()
        record_deleted_rollouts(latest_deleted_rollout_fds)

        try:
            latest_stat = path.stat()
        except OSError:
            skipped_changed_sessions += 1
            tmp.unlink()
            print(f"warning: skipping session rollout that disappeared before rewrite: {path}", file=sys.stderr)
            continue

        if (latest_stat.st_dev, latest_stat.st_ino) != (original_stat.st_dev, original_stat.st_ino):
            skipped_changed_sessions += 1
            tmp.unlink()
            print(f"warning: skipping session rollout that changed before rewrite: {path}", file=sys.stderr)
            continue

        if (latest_stat.st_dev, latest_stat.st_ino) in latest_open_rollout_inodes:
            skipped_hot_sessions += 1
            tmp.unlink()
            print(f"warning: skipping hot active Codex session rollout: {path}", file=sys.stderr)
            continue

        os.replace(tmp, path)
        os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        changed_sessions += 1
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise

if skipped_hot_sessions:
    action = "skipped" if write_changes else "excluded"
    print(
        f"warning: {action} {skipped_hot_sessions} hot active Codex session(s); "
        "close or resume them cleanly before migrating their provider metadata.",
        file=sys.stderr,
    )

if skipped_changed_sessions:
    print(
        f"warning: skipped {skipped_changed_sessions} session rollout(s) that changed during migration; "
        "rerun after active Codex sessions are closed.",
        file=sys.stderr,
    )

if deleted_rollout_fds:
    print(
        "warning: detected active Codex rollout file descriptor(s) for deleted JSONL files; "
        "a previous live rewrite may already have detached persisted history.",
        file=sys.stderr,
    )
    for pid, target in deleted_rollout_fds:
        print(f"warning: pid {pid} has deleted rollout fd: {target}", file=sys.stderr)

print(changed_sessions)
PY
}

set_config_model_provider() {
  local file="$1"
  local name="$2"
  local tmp

  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v name="$name" '
    BEGIN {
      replacement = "model_provider = \"" name "\""
    }
    {
      lines[++count] = $0
      if (!root_done && $0 ~ /^[[:space:]]*\[/) {
        root_done = 1
      }
      if (!root_done) {
        if (!active_idx && $0 ~ /^[[:space:]]*model_provider[[:space:]]*=/) {
          active_idx = count
        } else if (!comment_idx && $0 ~ /^[[:space:]]*#[[:space:]]*model_provider[[:space:]]*=/) {
          comment_idx = count
        }
      }
    }
    END {
      if (active_idx) {
        lines[active_idx] = replacement
      } else if (comment_idx) {
        lines[comment_idx] = replacement
      } else {
        print replacement
      }
      for (i = 1; i <= count; i++) {
        print lines[i]
      }
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

comment_config_model_provider() {
  local file="$1"
  local tmp
  local status

  [[ -f "$file" ]] || return 1

  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if awk '
    BEGIN {
      changed = 0
    }
    {
      if (!root_done && $0 ~ /^[[:space:]]*\[/) {
        root_done = 1
      }
      if (!root_done && $0 ~ /^[[:space:]]*model_provider[[:space:]]*=/) {
        print "# " $0
        changed = 1
        next
      }
      print
    }
    END {
      exit changed ? 0 : 1
    }
  ' "$file" >"$tmp"; then
    status=0
  else
    status=1
  fi
  mv "$tmp" "$file"
  return "$status"
}

sync_config_model_provider() {
  local name="$1"
  local source="$2"
  local config

  config="$(config_path)"
  [[ -f "$config" ]] || return 0

  if toml_has_model_provider_table "$config" "$name"; then
    set_config_model_provider "$config" "$name"
    info "set config.toml model_provider to $name"
    return 0
  fi

  if profile_has_subscription_shape "$source"; then
    if comment_config_model_provider "$config"; then
      info "commented config.toml model_provider for OpenAI profile"
    fi
  fi
}

safe_session_name() {
  local raw="$1"
  printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '_'
}

profile_hash() {
  local raw="$1"
  cksum <<<"$raw" | awk '{print $1}'
}

safe_temp_home() {
  local profile="$1"
  printf '%s/%s\n' "$TMP_ROOT" "$profile"
}

reset_temp_home() {
  local dir="$1"
  case "$dir" in
    "$TMP_ROOT"/*) ;;
    *) die "refusing to reset unexpected temp directory: $dir" ;;
  esac

  rm -rf "$dir"
  install -d -m 700 "$dir"
}

cmd_list() {
  local active_profiles profile marker
  active_profiles="$(active_profile_names)"

  printf '%s\n' '--------------------------------------------------------------------------------'
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    marker=" "
    if grep -Fxq -- "$profile" <<<"$active_profiles"; then
      marker="#"
    fi
    printf '%s %s\n' "$marker" "$profile"
  done < <(ordered_profile_names)
  printf '%s\n' '--------------------------------------------------------------------------------'

  if [[ -n "$active_profiles" ]]; then
    printf '# currently active profile\n'
  fi
}

cmd_use() {
  local name="" move_sessions=0 move_window_days=30 move_window_days_explicit=0
  local parsing_options=1
  local home source target backup target_kind current_provider target_provider
  local provider_changed=0 sessions_to_move migrated move_command

  while (($#)); do
    if [[ "$parsing_options" == "1" ]]; then
      case "$1" in
        --move)
          move_sessions=1
          shift
          continue
          ;;
        --move-sessions)
          info "warning: --move-sessions is deprecated; use --move instead"
          move_sessions=1
          shift
          continue
          ;;
        --move-days)
          shift
          [[ $# -gt 0 ]] || die "--move-days requires a value"
          [[ "$1" =~ ^-?[0-9]+$ ]] || die "--move-days must be an integer"
          (( "$1" >= -1 )) || die "--move-days must be -1 or greater"
          move_window_days="$1"
          move_window_days_explicit=1
          shift
          continue
          ;;
        --move-days=*)
          move_window_days="${1#*=}"
          [[ "$move_window_days" =~ ^-?[0-9]+$ ]] || die "--move-days must be an integer"
          (( move_window_days >= -1 )) || die "--move-days must be -1 or greater"
          move_window_days_explicit=1
          shift
          continue
          ;;
        --move-window-days)
          info "warning: --move-window-days is deprecated; use --move-days instead"
          shift
          [[ $# -gt 0 ]] || die "--move-window-days requires a value"
          [[ "$1" =~ ^-?[0-9]+$ ]] || die "--move-window-days must be an integer"
          (( "$1" >= -1 )) || die "--move-window-days must be -1 or greater"
          move_window_days="$1"
          move_window_days_explicit=1
          shift
          continue
          ;;
        --move-window-days=*)
          info "warning: --move-window-days is deprecated; use --move-days instead"
          move_window_days="${1#*=}"
          [[ "$move_window_days" =~ ^-?[0-9]+$ ]] || die "--move-window-days must be an integer"
          (( move_window_days >= -1 )) || die "--move-window-days must be -1 or greater"
          move_window_days_explicit=1
          shift
          continue
          ;;
        --)
          parsing_options=0
          shift
          continue
          ;;
        -h|--help)
          usage
          return 0
          ;;
      esac
    fi

    [[ -z "$name" ]] || {
      usage
      die "use accepts exactly one profile name"
    }
    name="$1"
    shift
  done

  [[ -n "$name" ]] || die "missing profile name"

  home="$(codex_home)"
  source="$(profile_path "$name")"
  target="$home/auth.json"
  backup="$home/auth.json.bak.$(date +%Y%m%d%H%M%S)"

  [[ -f "$source" ]] || die "profile does not exist: $source"

  target_kind="$(profile_provider_kind "$name" "$source")"
  current_provider="$(active_provider_name)"

  target_provider=""
  if [[ "$target_kind" == "openai" || "$target_kind" == "custom" ]]; then
    target_provider="$(provider_name_for_kind "$target_kind" "$name")"
  fi

  if [[ -n "$current_provider" && -n "$target_provider" && "$current_provider" != "$target_provider" ]]; then
    provider_changed=1
  fi

  if [[ "$move_sessions" == "1" ]]; then
    [[ -n "$target_provider" ]] || die "profile $name is neither a configured custom provider nor an OpenAI subscription profile"
    have python3 || die "python3 is required to rewrite session provider metadata"
  elif [[ "$provider_changed" == "1" ]]; then
    have python3 || die "python3 is required to count session provider metadata changes"
  fi

  install -d -m 700 "$home"

  if [[ "${CODEX_MANAGER_BACKUP:-0}" == "1" && -e "$target" ]]; then
    cp "$target" "$backup"
    info "backed up existing auth.json to $backup"
  fi

  rm -f "$target"
  ln -s "$source" "$target"
  sync_config_model_provider "$name" "$source"
  printf 'using profile: %s\n' "$name"

  if [[ "$move_sessions" == "1" ]]; then
    migrated="$(move_session_providers "$target_provider" "$move_window_days")"
    printf 'migrated %s sessions to provider: %s\n' "$migrated" "$target_provider"
  elif [[ "$provider_changed" == "1" && -n "$target_provider" ]]; then
    sessions_to_move="$(session_provider_change_count "$target_provider" "$move_window_days")"
    move_command="codex-manager use --move"
    if [[ "$move_window_days_explicit" == "1" ]]; then
      move_command="$move_command --move-days $move_window_days"
    fi
    move_command="$move_command $name"
    if [[ "$move_window_days" == "-1" ]]; then
      printf 'provider changed; %s sessions would be moved. Run "%s" to migrate them.\n' "$sessions_to_move" "$move_command"
    else
      printf 'provider changed; %s sessions from the last %s days would be moved. Run "%s" to migrate them.\n' "$sessions_to_move" "$move_window_days" "$move_command"
    fi
  fi
}
