parse_reset() {
  local line="$1"
  local value

  value="$(sed -nE 's/.*\(resets[[:space:]]+//p' <<<"$line" | tail -n 1)"
  value="${value%%)*}"
  value="${value%%│*}"
  value="${value%%|*}"
  trim "$value"
}

tmux_capture() {
  local session="$1"
  tmux capture-pane -t "=$session" -p -S -2000 2>/dev/null || true
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
    tmux send-keys -t "=$session" "/status" >/dev/null
    sleep "$STATUS_KEY_DELAY"
    tmux send-keys -t "=$session" Enter >/dev/null
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
  local tmux_fallback="${3:-0}"

  if get_one_profile_direct "$profile"; then
    return 0
  fi

  if [[ "$tmux_fallback" != "1" ]]; then
    printf '%s\tERROR\tDirect check failed and tmux fallback is disabled\n' "$profile"
    return 1
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
    tmux kill-session -t "=$session" >/dev/null 2>&1 || true
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
