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
  session_provider_rewrite count "$(codex_home)/sessions" "$provider"
}

move_session_providers() {
  local provider="$1"
  session_provider_rewrite write "$(codex_home)/sessions" "$provider"
}

session_provider_rewrite() {
  local mode="$1"
  local sessions_dir="$2"
  local provider="$3"

  have python3 || die "python3 is required to rewrite session provider metadata"

  python3 - "$mode" "$sessions_dir" "$provider" <<'PY'
import json
import os
import sys
from pathlib import Path

mode, sessions_dir, target_provider = sys.argv[1:4]
write_changes = mode == "write"
root = Path(sessions_dir)

if not root.is_dir():
    print(0)
    sys.exit(0)

changed_sessions = 0

for path in sorted(root.rglob("*")):
    if not path.is_file():
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

    changed_sessions += 1
    if not write_changes:
        continue

    tmp = path.with_name(path.name + ".tmp.codex-manager")
    try:
        tmp.write_text("".join(new_lines), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise

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
  done < <(profile_names)
  printf '%s\n' '--------------------------------------------------------------------------------'

  if [[ -n "$active_profiles" ]]; then
    printf '# currently active profile\n'
  fi
}

cmd_use() {
  local name="" move_sessions=0
  local parsing_options=1
  local home source target backup target_kind current_provider target_provider
  local provider_changed=0 sessions_to_move migrated

  while (($#)); do
    if [[ "$parsing_options" == "1" ]]; then
      case "$1" in
        --move-sessions)
          move_sessions=1
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
    migrated="$(move_session_providers "$target_provider")"
    printf 'migrated %s sessions to provider: %s\n' "$migrated" "$target_provider"
  elif [[ "$provider_changed" == "1" && -n "$target_provider" ]]; then
    sessions_to_move="$(session_provider_change_count "$target_provider")"
    printf 'provider changed; %s sessions would be moved. Run "codex-manager.sh use --move-sessions %s" to migrate them.\n' "$sessions_to_move" "$name"
  fi
}
