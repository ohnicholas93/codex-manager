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
  if have curl; then
    return 0
  fi
  require_common
}
