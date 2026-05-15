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
    if grep -Fxq "$profile" <<<"$active_profiles"; then
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
  local name="${1:-}"
  local home source target backup
  [[ -n "$name" ]] || die "missing profile name"

  home="$(codex_home)"
  source="$(profile_path "$name")"
  target="$home/auth.json"
  backup="$home/auth.json.bak.$(date +%Y%m%d%H%M%S)"

  [[ -f "$source" ]] || die "profile does not exist: $source"
  install -d -m 700 "$home"

  if [[ "${CODEX_MANAGER_BACKUP:-0}" == "1" && -e "$target" ]]; then
    cp "$target" "$backup"
    info "backed up existing auth.json to $backup"
  fi

  rm -f "$target"
  ln -s "$source" "$target"
  sync_config_model_provider "$name" "$source"
  printf 'using profile: %s\n' "$name"
}
