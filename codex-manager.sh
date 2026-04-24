#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="codex-manager"
DEFAULT_CODEX_HOME="$HOME/.codex"
TMP_ROOT="${CODEX_MANAGER_TMP_ROOT:-/tmp/codex-manager}"
READY_TIMEOUT="${CODEX_MANAGER_READY_TIMEOUT:-60}"
STATUS_TIMEOUT="${CODEX_MANAGER_STATUS_TIMEOUT:-90}"
STATUS_INTERVAL="${CODEX_MANAGER_STATUS_INTERVAL:-1}"
STATUS_KEY_DELAY="${CODEX_MANAGER_STATUS_KEY_DELAY:-0.2}"

usage() {
  cat <<'EOF'
Usage:
  codex-manager.sh get
  codex-manager.sh use <name>
  codex-manager.sh rotate
  codex-manager.sh profiles

Environment:
  CODEX_HOME                         Defaults to ~/.codex
  CODEX_MANAGER_TMP_ROOT             Defaults to /tmp/codex-manager
  CODEX_MANAGER_READY_TIMEOUT        Seconds to wait for Codex startup, default 60
  CODEX_MANAGER_STATUS_TIMEOUT       Seconds to wait for refreshed limits, default 90
  CODEX_MANAGER_STATUS_INTERVAL      Seconds between /status attempts, default 1
  CODEX_MANAGER_STATUS_KEY_DELAY     Delay before Enter after typing /status, default 0.2
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

wait_until_ready() {
  local session="$1"
  local elapsed=0
  local pane

  while (( elapsed < READY_TIMEOUT )); do
    pane="$(tmux_capture "$session")"
    if [[ -n "$pane" && "$pane" != *"esc to interrupt"* ]]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

parse_status() {
  local pane="$1"
  local profile="$2"
  local account five_line weekly_line
  local five_percent weekly_percent five_reset weekly_reset

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

  five_percent="$(sed -nE 's/.*[^0-9]([0-9]+)% left.*/\1/p' <<<"$five_line" | tail -n 1)"
  weekly_percent="$(sed -nE 's/.*[^0-9]([0-9]+)% left.*/\1/p' <<<"$weekly_line" | tail -n 1)"
  five_reset="$(parse_reset "$five_line")"
  weekly_reset="$(parse_reset "$weekly_line")"

  [[ "$five_percent" =~ ^[0-9]+$ && "$weekly_percent" =~ ^[0-9]+$ ]] || return 1

  RESULT_PROFILE="$profile"
  RESULT_ACCOUNT="$account"
  RESULT_5H="$five_percent"
  RESULT_WEEKLY="$weekly_percent"
  RESULT_5H_RESET="$(trim "${five_reset:-unknown}")"
  RESULT_WEEKLY_RESET="$(trim "${weekly_reset:-unknown}")"
  RESULT_SCORE="$(( five_percent < weekly_percent ? five_percent : weekly_percent ))"
  return 0
}

get_one_profile() {
  local profile="$1"
  local source tmp_home session command elapsed pane
  source="$(profile_path "$profile")"
  tmp_home="$(safe_temp_home "$profile")"
  session="$(safe_session_name "${APP_NAME}_${profile}_$(profile_hash "$profile")_$$")"

  [[ -f "$source" ]] || die "profile does not exist: $source"
  reset_temp_home "$tmp_home"
  cp "$source" "$tmp_home/auth.json"
  chmod 600 "$tmp_home/auth.json"

  printf -v command 'CODEX_HOME=%q codex --yolo' "$tmp_home"
  tmux new-session -d -s "$session" "$command" >/dev/null
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
        "$RESULT_ACCOUNT"
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

render_table() {
  local rows_file="$1"
  local title="${2:-Codex Manager Limits}"

  printf '\n%s\n' "$title"
  printf '%s\n' '-------------------------------------------------------------------------------'
  printf '%-18s %-6s %-8s %-18s %-22s %s\n' 'Profile' '5h' 'Weekly' '5h reset' 'Weekly reset' 'Account'
  printf '%s\n' '-------------------------------------------------------------------------------'
  awk -F '\t' '
    $2 == "ERROR" {
      printf "%-18s %-6s %-8s %-18s %-22s %s\n", $1, "ERR", "ERR", "-", "-", $3
      next
    }
    {
      printf "%-18s %-6s %-8s %-18s %-22s %s\n", $1, $2 "%", $3 "%", $4, $5, $7
    }
  ' "$rows_file"
  printf '%s\n\n' '-------------------------------------------------------------------------------'
}

cmd_profiles() {
  profile_names
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
  local rows_file profiles profile failed=0
  ACTIVE_SESSIONS=()
  trap cleanup_sessions EXIT

  rows_file="$(mktemp)"
  profiles="$(profile_names)"
  [[ -n "$profiles" ]] || die "no profiles found in $(profiles_dir)"

  info "retrieving account limits..."
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    info "checking profile: $profile"
    if ! get_one_profile "$profile" >>"$rows_file"; then
      failed=1
    fi
  done <<<"$profiles"

  render_table "$rows_file"
  LAST_ROWS_FILE="$rows_file"
  return "$failed"
}

cmd_rotate() {
  require_common
  local rows_file best_profile

  cmd_get || true
  rows_file="${LAST_ROWS_FILE:-}"
  [[ -n "$rows_file" && -f "$rows_file" ]] || die "could not read get results"

  best_profile="$(awk -F '\t' '
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
  ' "$rows_file")"

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
    profiles) cmd_profiles "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; die "unknown command: $command" ;;
  esac
}

main "$@"
