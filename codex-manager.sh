#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="codex-manager"
DEFAULT_CODEX_HOME="$HOME/.codex"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
TMP_ROOT="${CODEX_MANAGER_TMP_ROOT:-$CACHE_HOME/codex-manager}"
READY_TIMEOUT="${CODEX_MANAGER_READY_TIMEOUT:-60}"
STATUS_TIMEOUT="${CODEX_MANAGER_STATUS_TIMEOUT:-90}"
STATUS_INTERVAL="${CODEX_MANAGER_STATUS_INTERVAL:-1}"
STATUS_KEY_DELAY="${CODEX_MANAGER_STATUS_KEY_DELAY:-0.5}"
TMUX_WIDTH="${CODEX_MANAGER_TMUX_WIDTH:-160}"
TMUX_HEIGHT="${CODEX_MANAGER_TMUX_HEIGHT:-40}"

usage() {
  cat <<'EOF'
Usage:
  codex-manager.sh list
  codex-manager.sh get
  codex-manager.sh use <name>
  codex-manager.sh rotate

Environment:
  CODEX_HOME                         Defaults to ~/.codex
  CODEX_MANAGER_TMP_ROOT             Defaults to ${XDG_CACHE_HOME:-~/.cache}/codex-manager
  CODEX_MANAGER_READY_TIMEOUT        Seconds to wait for Codex startup, default 60
  CODEX_MANAGER_STATUS_TIMEOUT       Seconds to wait for refreshed limits, default 90
  CODEX_MANAGER_STATUS_INTERVAL      Seconds between /status attempts, default 1
  CODEX_MANAGER_STATUS_KEY_DELAY     Delay before Enter after typing /status, default 0.5
  CODEX_MANAGER_TMUX_WIDTH           Detached tmux pane width, default 160
  CODEX_MANAGER_TMUX_HEIGHT          Detached tmux pane height, default 40
  CODEX_MANAGER_BACKUP=1             Back up auth.json before use/rotate

Profiles:
  Profiles are JSON files in $CODEX_HOME/profiles.
  The profile name is the filename without .json.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_reset() {
  local line="$1"
  local value

  value="$(sed -nE 's/.*\(resets[[:space:]]+//p' <<<"$line" | tail -n 1)"
  value="${value%%)*}"
  value="${value%%│*}"
  value="${value%%|*}"
  trim "$value"
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

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

require_common() {
  have tmux || die "tmux is required"
  have codex || die "codex is required"
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

is_active_profile() {
  local profile="$1"
  grep -Fxq "$profile" <<<"${ACTIVE_PROFILES:-}"
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

tmux_capture() {
  local session="$1"
  tmux capture-pane -t "$session" -p -S -2000 2>/dev/null || true
}

latest_status_block() {
  awk '
    /^╭/ {
      candidate = $0 ORS
      in_box = 1
      has_codex = 0
      next
    }
    in_box {
      candidate = candidate $0 ORS
      if ($0 ~ /OpenAI Codex/) {
        has_codex = 1
      }
      if ($0 ~ /^╰/) {
        if (has_codex) {
          block = candidate
        }
        in_box = 0
      }
    }
    END {
      printf "%s", block
    }
  '
}

wait_until_ready() {
  local session="$1"
  local elapsed=0
  local pane

  while (( elapsed < READY_TIMEOUT )); do
    pane="$(tmux_capture "$session")"
    if [[ "$pane" == *"OpenAI Codex"* && "$pane" != *"esc to interrupt"* ]]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

parse_status() {
  local pane
  local profile="$2"
  local account tier five_line weekly_line
  local five_percent weekly_percent five_reset weekly_reset

  pane="$(latest_status_block <<<"$1")"
  [[ -n "$pane" ]] || return 1
  if grep -Fqi 'limits may be stale - run /status again shortly' <<<"$pane"; then
    return 1
  fi

  five_line="$(grep -E '5h limit:' <<<"$pane" | tail -n 1 || true)"
  weekly_line="$(grep -E 'Weekly limit:' <<<"$pane" | tail -n 1 || true)"
  [[ -n "$five_line" && -n "$weekly_line" ]] || return 1

  account="$(awk '
    /Account:/ {
      line = $0
      sub(/^.*Account:[[:space:]]*/, "", line)
      sub(/[[:space:]]{2,}[^[:space:]]?[[:space:]]*$/, "", line)
      print line
    }
  ' <<<"$pane" | tail -n 1)"
  account="$(trim "${account:-unknown}")"
  tier="$(sed -nE 's/.*\(([^()]*)\)[[:space:]]*$/\1/p' <<<"$account" | tail -n 1)"
  tier="$(trim "${tier:-unknown}")"

  five_percent="$(sed -nE 's/.*[^0-9]([0-9]+)% left.*/\1/p' <<<"$five_line" | tail -n 1)"
  weekly_percent="$(sed -nE 's/.*[^0-9]([0-9]+)% left.*/\1/p' <<<"$weekly_line" | tail -n 1)"
  five_reset="$(parse_reset "$five_line")"
  weekly_reset="$(parse_reset "$weekly_line")"

  [[ "$five_percent" =~ ^[0-9]+$ && "$weekly_percent" =~ ^[0-9]+$ ]] || return 1

  RESULT_PROFILE="$profile"
  RESULT_TIER="$tier"
  RESULT_5H="$five_percent"
  RESULT_WEEKLY="$weekly_percent"
  RESULT_5H_RESET="$(trim "${five_reset:-unknown}")"
  RESULT_WEEKLY_RESET="$(trim "${weekly_reset:-unknown}")"
  RESULT_SCORE="$(( five_percent < weekly_percent ? five_percent : weekly_percent ))"
  return 0
}

get_one_profile() {
  local profile="$1"
  local session="${2:-}"
  local source tmp_home command elapsed pane
  source="$(profile_path "$profile")"
  tmp_home="$(safe_temp_home "$profile")"
  session="${session:-$(safe_session_name "${APP_NAME}_${profile}_$(profile_hash "$profile")_$$")}"

  [[ -f "$source" ]] || die "profile does not exist: $source"
  reset_temp_home "$tmp_home"
  cp "$source" "$tmp_home/auth.json"
  chmod 600 "$tmp_home/auth.json"
  {
    printf '[projects."%s"]\n' "$(toml_escape "$tmp_home")"
    printf 'trust_level = "trusted"\n'
  } >"$tmp_home/config.toml"
  chmod 600 "$tmp_home/config.toml"

  printf -v command 'cd %q && CODEX_HOME=%q codex' "$tmp_home" "$tmp_home"
  tmux new-session -d -x "$TMUX_WIDTH" -y "$TMUX_HEIGHT" -s "$session" "$command" >/dev/null
  ACTIVE_SESSIONS+=("$session")

  if ! wait_until_ready "$session"; then
    printf '%s\tERROR\tCodex did not become ready within %ss\n' "$profile" "$READY_TIMEOUT"
    return 1
  fi

  elapsed=0
  while (( elapsed < STATUS_TIMEOUT )); do
    tmux send-keys -t "$session" "/status" >/dev/null
    sleep "$STATUS_KEY_DELAY"
    tmux send-keys -t "$session" Enter >/dev/null
    sleep "$STATUS_INTERVAL"
    elapsed=$((elapsed + STATUS_INTERVAL))

    pane="$(tmux_capture "$session")"
    if parse_status "$pane" "$profile"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$RESULT_PROFILE" \
        "$RESULT_5H" \
        "$RESULT_WEEKLY" \
        "$RESULT_5H_RESET" \
        "$RESULT_WEEKLY_RESET" \
        "$RESULT_SCORE" \
        "$RESULT_TIER"
      return 0
    fi
  done

  printf '%s\tERROR\tLimits did not refresh within %ss\n' "$profile" "$STATUS_TIMEOUT"
  return 1
}

cleanup_sessions() {
  local session
  for session in "${ACTIVE_SESSIONS[@]:-}"; do
    tmux kill-session -t "$session" >/dev/null 2>&1 || true
  done
}

cleanup_paths() {
  local path
  for path in "${ACTIVE_TEMP_HOMES[@]:-}"; do
    case "$path" in
      "$TMP_ROOT"/*) rm -rf "$path" ;;
    esac
  done
  for path in "${ACTIVE_TEMP_FILES[@]:-}"; do
    case "$path" in
      /tmp/*) rm -rf "$path" ;;
    esac
  done
}

cleanup_all() {
  cleanup_sessions
  cleanup_paths
}

render_table() {
  local rows_file="$1"
  local title="${2:-Codex Manager Limits}"
  local recommended="${3:-}"
  local active_profiles="${4:-}"
  local active_profile has_plus=0 has_star=0 has_hash=0

  if [[ -n "$recommended" ]]; then
    if grep -Fxq "$recommended" <<<"$active_profiles"; then
      has_plus=1
    else
      has_star=1
    fi
  fi
  while IFS= read -r active_profile; do
    [[ -n "$active_profile" ]] || continue
    if [[ "$active_profile" != "$recommended" ]]; then
      has_hash=1
    fi
  done <<<"$active_profiles"

  printf '\n%s\n' "$title"
  printf '%s\n' '--------------------------------------------------------------------------------'
  printf '%-31s %-6s %-8s %-11s %-13s\n' 'Profile' '5h' 'Weekly' '5h reset' 'Weekly reset'
  printf '%s\n' '--------------------------------------------------------------------------------'
  awk -F '\t' -v recommended="$recommended" -v active_profiles="$active_profiles" '
    function clip(value, width) {
      if (length(value) <= width) return value
      if (width <= 1) return substr(value, 1, width)
      return substr(value, 1, width - 1) "~"
    }
    function label(profile, tier) {
      if (tier == "" || tier == "unknown") return profile
      return profile " (" tier ")"
    }
    function is_active(profile,    count, active, i) {
      count = split(active_profiles, active, "\n")
      for (i = 1; i <= count; i++) {
        if (active[i] == profile) return 1
      }
      return 0
    }
    function marker(profile) {
      if (profile == recommended && is_active(profile)) return "+"
      if (profile == recommended) return "*"
      if (is_active(profile)) return "#"
      return " "
    }
    $2 == "ERROR" {
      printf "%s %-29s %-6s %-8s %-11s %-13s\n", marker($1), clip($1, 29), "ERR", "ERR", "-", "-"
      next
    }
    {
      printf "%s %-29s %-6s %-8s %-11s %-13s\n", marker($1), clip(label($1, $7), 29), $2 "%", $3 "%", clip($4, 11), clip($5, 13)
    }
  ' "$rows_file"
  printf '%s\n' '--------------------------------------------------------------------------------'
  if (( has_plus )); then
    printf '+ recommended rotate target and currently active profile\n'
  fi
  if (( has_hash )); then
    printf '# currently active profile\n'
  fi
  if (( has_star )); then
    printf '* recommended rotate target\n'
  fi
  printf '\n'
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

best_profile_from_rows() {
  local rows_file="$1"

  awk -F '\t' '
    $2 != "ERROR" {
      score = $6 + 0
      five = $2 + 0
      weekly = $3 + 0
      if (!seen || score > best_score || (score == best_score && five > best_five) || (score == best_score && five == best_five && weekly > best_weekly)) {
        seen = 1
        best = $1
        best_score = score
        best_five = five
        best_weekly = weekly
      }
    }
    END {
      if (seen) print best
    }
  ' "$rows_file"
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
  cp "$source" "$target"
  chmod 600 "$target"
  printf 'using profile: %s\n' "$name"
}

cmd_get() {
  require_common
  local rows_file tmp_dir profiles profile output session tmp_home pid i failed=0
  local -a result_files=()
  local -a result_profiles=()
  local -a pids=()
  ACTIVE_SESSIONS=()
  ACTIVE_TEMP_HOMES=()
  ACTIVE_TEMP_FILES=()
  trap cleanup_all EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  rows_file="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  ACTIVE_TEMP_FILES+=("$rows_file" "$tmp_dir")
  profiles="$(profile_names)"
  [[ -n "$profiles" ]] || die "no profiles found in $(profiles_dir)"

  info "retrieving account limits in parallel..."
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    output="$(mktemp "$tmp_dir/result.XXXXXX")"
    session="$(safe_session_name "${APP_NAME}_${profile}_$(profile_hash "$profile")_$$")"
    tmp_home="$(safe_temp_home "$profile")"
    ACTIVE_SESSIONS+=("$session")
    ACTIVE_TEMP_HOMES+=("$tmp_home")
    result_files+=("$output")
    result_profiles+=("$profile")
    info "checking profile: $profile"
    get_one_profile "$profile" "$session" >"$output" &
    pid="$!"
    pids+=("$pid")
  done <<<"$profiles"

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done

  for (( i = 0; i < ${#result_files[@]}; i++ )); do
    output="${result_files[$i]}"
    profile="${result_profiles[$i]}"
    if [[ -s "$output" ]]; then
      cat "$output" >>"$rows_file"
    else
      printf '%s\tERROR\tProfile check failed before producing a result\n' "$profile" >>"$rows_file"
    fi
  done
  rm -rf "$tmp_dir"

  ACTIVE_PROFILES="$(active_profile_names)"
  LAST_RECOMMENDED_PROFILE="$(best_profile_from_rows "$rows_file")"
  render_table "$rows_file" "Codex Manager Limits" "$LAST_RECOMMENDED_PROFILE" "$ACTIVE_PROFILES"
  LAST_ROWS_FILE="$rows_file"
  return "$failed"
}

cmd_rotate() {
  require_common
  local rows_file best_profile

  cmd_get || true
  rows_file="${LAST_ROWS_FILE:-}"
  [[ -n "$rows_file" && -f "$rows_file" ]] || die "could not read get results"

  best_profile="${LAST_RECOMMENDED_PROFILE:-$(best_profile_from_rows "$rows_file")}"

  [[ -n "$best_profile" ]] || die "no usable profile found"
  cmd_use "$best_profile"
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    get) cmd_get "$@" ;;
    use) cmd_use "$@" ;;
    rotate) cmd_rotate "$@" ;;
    list) cmd_list "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; die "unknown command: $command" ;;
  esac
}

main "$@"
