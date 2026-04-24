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
DIRECT_TIMEOUT="${CODEX_MANAGER_DIRECT_TIMEOUT:-20}"
DIRECT_CONNECT_TIMEOUT="${CODEX_MANAGER_DIRECT_CONNECT_TIMEOUT:-5}"
USAGE_URL="${CODEX_MANAGER_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"
REFRESH_URL="${CODEX_REFRESH_TOKEN_URL_OVERRIDE:-https://auth.openai.com/oauth/token}"
CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"

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
  CODEX_MANAGER_DIRECT_TIMEOUT       Seconds to wait for direct API response, default 20
  CODEX_MANAGER_DIRECT_CONNECT_TIMEOUT
                                      Seconds to wait for direct API connect, default 5
  CODEX_MANAGER_USAGE_URL            Direct usage endpoint, default ChatGPT Codex usage API
  CODEX_REFRESH_TOKEN_URL_OVERRIDE   Refresh token endpoint override
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

require_get_support() {
  if have curl; then
    return 0
  fi
  require_common
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

json_string_field() {
  local json="$1"
  local key="$2"

  sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' <<<"$json" | tail -n 1
}

json_number_field() {
  local json="$1"
  local key="$2"

  sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' <<<"$json" | tail -n 1
}

json_numeric_field() {
  local json="$1"
  local key="$2"

  sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*([0-9]+([.][0-9]+)?).*/\1/p' <<<"$json" | tail -n 1
}

json_object_field() {
  local json="$1"
  local key="$2"

  awk -v key="$key" '
    BEGIN { RS = "\0" }
    {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\\{"
      if (!match($0, pattern)) {
        exit
      }

      start = RSTART + RLENGTH - 1
      depth = 0
      in_string = 0
      escaped = 0

      for (i = start; i <= length($0); i++) {
        ch = substr($0, i, 1)

        if (escaped) {
          escaped = 0
          continue
        }
        if (ch == "\\" && in_string) {
          escaped = 1
          continue
        }
        if (ch == "\"") {
          in_string = !in_string
          continue
        }
        if (in_string) {
          continue
        }

        if (ch == "{") {
          depth++
        } else if (ch == "}") {
          depth--
          if (depth == 0) {
            print substr($0, start, i - start + 1)
            exit
          }
        }
      }
    }
  ' <<<"$json"
}

curl_config_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

awk_replacement_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  printf '%s' "$value"
}

clamp_percent_left() {
  local used="$1"
  [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v used="$used" '
    BEGIN {
      left = 100 - used
      if (left < 0) left = 0
      if (left > 100) left = 100
      printf "%.0f", left
    }
  '
}

format_epoch_reset() {
  local reset_at="$1"
  local window_seconds="$2"
  local format

  [[ "$reset_at" =~ ^[0-9]+$ ]] || {
    printf 'unknown'
    return
  }

  if [[ "$window_seconds" =~ ^[0-9]+$ && "$window_seconds" -gt 86400 ]]; then
    format='+%H:%M on %d %b'
  else
    format='+%H:%M'
  fi

  date -d "@$reset_at" "$format" 2>/dev/null \
    || date -r "$reset_at" "$format" 2>/dev/null \
    || printf 'unknown'
}

title_case() {
  local value="$1"
  [[ -n "$value" ]] || {
    printf 'unknown'
    return
  }
  awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }' <<<"$value"
}

first_json_object_field() {
  local json="$1"
  shift
  local key value

  for key in "$@"; do
    value="$(json_object_field "$json" "$key")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done

  return 0
}

first_json_number_field() {
  local json="$1"
  shift
  local key value

  for key in "$@"; do
    value="$(json_number_field "$json" "$key")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done

  return 0
}

window_seconds() {
  local window="$1"
  local seconds minutes

  seconds="$(json_number_field "$window" "limit_window_seconds")"
  if [[ -n "$seconds" ]]; then
    printf '%s' "$seconds"
    return
  fi

  minutes="$(json_number_field "$window" "window_minutes")"
  if [[ -n "$minutes" ]]; then
    printf '%s' "$((minutes * 60))"
    return
  fi

  printf ''
}

replace_json_string_field() {
  local json="$1"
  local key="$2"
  local value="$3"
  local replacement

  replacement="\"$key\": \"$(json_escape "$value")\""
  replacement="$(awk_replacement_escape "$replacement")"
  awk -v key="$key" -v replacement="$replacement" '
    BEGIN { RS = "\0"; ORS = "" }
    {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\""
      if (!sub(pattern, replacement)) {
        exit 1
      }
      print
    }
  ' <<<"$json"
}

replace_or_add_last_refresh() {
  local json="$1"
  local value="$2"
  local replacement

  replacement="\"last_refresh\": \"$(json_escape "$value")\""
  replacement="$(awk_replacement_escape "$replacement")"
  awk -v replacement="$replacement" '
    BEGIN { RS = "\0"; ORS = "" }
    {
      pattern = "\"last_refresh\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\""
      if (sub(pattern, replacement)) {
        print
        exit
      }
      sub(/[[:space:]]*}[[:space:]]*$/, ", " replacement "}")
      print
    }
  ' <<<"$json"
}

persist_refreshed_tokens() {
  local source="$1"
  local auth_json="$2"
  local access_token="$3"
  local refresh_token="$4"
  local id_token="$5"
  local updated tmp last_refresh

  updated="$auth_json"
  if [[ -n "$access_token" ]]; then
    updated="$(replace_json_string_field "$updated" "access_token" "$access_token")" || return 1
  fi
  if [[ -n "$refresh_token" ]]; then
    updated="$(replace_json_string_field "$updated" "refresh_token" "$refresh_token")" || return 1
  fi
  if [[ -n "$id_token" ]]; then
    updated="$(replace_json_string_field "$updated" "id_token" "$id_token")" || return 1
  fi

  last_refresh="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  updated="$(replace_or_add_last_refresh "$updated" "$last_refresh")" || return 1

  tmp="$(mktemp "$(dirname "$source")/.${APP_NAME}.auth.XXXXXX")"
  chmod 600 "$tmp"
  printf '%s\n' "$updated" >"$tmp"
  mv "$tmp" "$source"
}

refresh_profile_token() {
  local source="$1"
  local auth_json="$2"
  local old_refresh_token response access_token refresh_token id_token

  have curl || return 1

  old_refresh_token="$(json_string_field "$auth_json" "refresh_token")"
  [[ -n "$old_refresh_token" ]] || return 1

  response="$(
    printf '{"client_id":"%s","grant_type":"refresh_token","refresh_token":"%s"}' \
      "$(json_escape "$CLIENT_ID")" \
      "$(json_escape "$old_refresh_token")" |
      curl -fsS \
        --connect-timeout "$DIRECT_CONNECT_TIMEOUT" \
        --max-time "$DIRECT_TIMEOUT" \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "$REFRESH_URL" 2>/dev/null
  )" || return 1
  response="$(tr -d '\n\r' <<<"$response")"

  access_token="$(json_string_field "$response" "access_token")"
  refresh_token="$(json_string_field "$response" "refresh_token")"
  id_token="$(json_string_field "$response" "id_token")"
  [[ -n "$access_token" || -n "$refresh_token" || -n "$id_token" ]] || return 1

  persist_refreshed_tokens "$source" "$auth_json" "$access_token" "$refresh_token" "$id_token"
}

fetch_usage_response() {
  local access_token="$1"
  local account_id="$2"

  {
    printf 'header = "Authorization: Bearer %s"\n' "$(curl_config_escape "$access_token")"
    if [[ -n "$account_id" ]]; then
      printf 'header = "ChatGPT-Account-ID: %s"\n' "$(curl_config_escape "$account_id")"
    fi
    printf 'header = "User-Agent: codex-cli"\n'
  } | curl -fsS \
    --connect-timeout "$DIRECT_CONNECT_TIMEOUT" \
    --max-time "$DIRECT_TIMEOUT" \
    --config - \
    "$USAGE_URL" 2>/dev/null
}

parse_usage_response() {
  local profile="$1"
  local response="$2"
  local primary secondary plan tier five_used weekly_used five_percent weekly_percent
  local five_reset_at weekly_reset_at five_window weekly_window five_reset weekly_reset score

  response="$(tr -d '\n\r' <<<"$response")"

  primary="$(first_json_object_field "$response" "primary_window" "primary")"
  secondary="$(first_json_object_field "$response" "secondary_window" "secondary")"
  [[ -n "$primary" && -n "$secondary" ]] || return 1

  five_used="$(json_numeric_field "$primary" "used_percent")"
  weekly_used="$(json_numeric_field "$secondary" "used_percent")"
  five_percent="$(clamp_percent_left "$five_used")" || return 1
  weekly_percent="$(clamp_percent_left "$weekly_used")" || return 1

  five_reset_at="$(first_json_number_field "$primary" "reset_at" "resets_at")"
  weekly_reset_at="$(first_json_number_field "$secondary" "reset_at" "resets_at")"
  five_window="$(window_seconds "$primary")"
  weekly_window="$(window_seconds "$secondary")"
  five_reset="$(format_epoch_reset "$five_reset_at" "$five_window")"
  weekly_reset="$(format_epoch_reset "$weekly_reset_at" "$weekly_window")"
  plan="$(json_string_field "$response" "plan_type")"
  tier="$(title_case "$plan")"
  score=$(( five_percent < weekly_percent ? five_percent : weekly_percent ))

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$profile" \
    "$five_percent" \
    "$weekly_percent" \
    "$five_reset" \
    "$weekly_reset" \
    "$score" \
    "$tier"
}

get_one_profile_direct() {
  local profile="$1"
  local source auth_json access_token account_id response

  have curl || return 1

  source="$(profile_path "$profile")"
  [[ -f "$source" ]] || die "profile does not exist: $source"

  auth_json="$(tr -d '\n\r' <"$source")"
  access_token="$(json_string_field "$auth_json" "access_token")"
  account_id="$(json_string_field "$auth_json" "account_id")"
  [[ -n "$access_token" ]] || return 1

  if response="$(fetch_usage_response "$access_token" "$account_id")"; then
    parse_usage_response "$profile" "$response"
    return
  fi

  refresh_profile_token "$source" "$auth_json" || return 1

  auth_json="$(tr -d '\n\r' <"$source")"
  access_token="$(json_string_field "$auth_json" "access_token")"
  account_id="$(json_string_field "$auth_json" "account_id")"
  [[ -n "$access_token" ]] || return 1

  response="$(fetch_usage_response "$access_token" "$account_id")" || return 1
  parse_usage_response "$profile" "$response"
}

get_one_profile_tmux() {
  local profile="$1"
  local session="${2:-}"
  local source tmp_home command elapsed pane
  source="$(profile_path "$profile")"
  tmp_home="$(safe_temp_home "$profile")"
  session="${session:-$(safe_session_name "${APP_NAME}_${profile}_$(profile_hash "$profile")_$$")}"

  [[ -f "$source" ]] || die "profile does not exist: $source"
  reset_temp_home "$tmp_home"
  ln -s "$source" "$tmp_home/auth.json"
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

get_one_profile() {
  local profile="$1"
  local session="${2:-}"

  if get_one_profile_direct "$profile"; then
    return 0
  fi

  if have tmux && have codex; then
    get_one_profile_tmux "$profile" "$session"
    return
  fi

  printf '%s\tERROR\tDirect check failed and tmux/codex fallback is unavailable\n' "$profile"
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
      printf "%s %-29s %-6s %-8s %-11s %-13s\n", marker($1), clip(label($1, $7), 29), $2 "%", $3 "%", clip($4, 11), clip($5, 16)
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
  ln -s "$source" "$target"
  printf 'using profile: %s\n' "$name"
}

cmd_get() {
  require_get_support
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

  if have curl; then
    info "retrieving account limits in parallel with direct API checks..."
  else
    info "retrieving account limits in parallel with tmux fallback..."
  fi
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
  require_get_support
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
