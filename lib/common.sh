usage() {
  cat <<'EOF'
Usage:
  codex-manager list
  codex-manager get [--tmux-fallback|--no-tmux-fallback]
  codex-manager use [--move] [--move-days DAYS] <name>
  codex-manager rotate

Options:
  --move                            For use, rewrite session providers in $CODEX_HOME/sessions
  --move-days DAYS                  For use --move, limit moved sessions by mtime; default 30, -1 means all
  --tmux-fallback                    For get, fall back to tmux/codex when direct checks fail
  --no-tmux-fallback                 For get, disable tmux fallback; this is the default

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

table_min_width() {
  printf '%s' 73
}

table_width() {
  local width="${CODEX_MANAGER_TABLE_WIDTH:-80}"
  local min_width

  min_width="$(table_min_width)"
  if [[ ! "$width" =~ ^[0-9]+$ ]] || (( width < min_width )); then
    width="$min_width"
  fi

  printf '%s' "$width"
}

clip_text() {
  local value="$1"
  local width="$2"

  if (( ${#value} <= width )); then
    printf '%s' "$value"
    return 0
  fi

  if (( width <= 1 )); then
    printf '%s' "${value:0:width}"
    return 0
  fi

  printf '%s~' "${value:0:width-1}"
}

print_wrapped_list() {
  local label="$1"
  local entries="$2"
  local width="${3:-$(table_width)}"
  local indent line entry candidate prefix

  indent="$(printf '%*s' "${#label}" '')"
  line="$label"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    prefix="$label"
    [[ "$line" == "$label" ]] || prefix="$indent"

    if [[ "$line" == "$prefix" ]]; then
      candidate="${prefix}${entry}"
    else
      candidate="${line}, ${entry}"
    fi

    if (( ${#candidate} <= width )) || [[ "$line" == "$prefix" ]]; then
      line="$candidate"
      continue
    fi

    printf '%s\n' "$line"
    line="${indent}${entry}"
  done <<<"$entries"

  printf '%s\n' "$line"
}

log_wrapped_list() {
  print_wrapped_list "$@" >&2
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

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
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

require_common() {
  have tmux || die "tmux is required"
  have codex || die "codex is required"
}

require_get_support() {
  local tmux_fallback="${1:-0}"

  if have curl; then
    return 0
  fi

  if [[ "$tmux_fallback" == "1" ]]; then
    require_common
    return 0
  fi

  die "curl is required unless get is run with --tmux-fallback"
}
