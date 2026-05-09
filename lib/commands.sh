cmd_get() {
  local tmux_fallback=0
  while (($#)); do
    case "$1" in
      --tmux-fallback) tmux_fallback=1 ;;
      --no-tmux-fallback) tmux_fallback=0 ;;
      -h|--help)
        usage
        return 0
        ;;
      *) usage; die "unknown get option: $1" ;;
    esac
    shift
  done

  require_get_support "$tmux_fallback"
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

  if [[ "$tmux_fallback" == "1" ]]; then
    info "retrieving account limits in parallel with direct API checks and tmux fallback..."
  elif have curl; then
    info "retrieving account limits in parallel with direct API checks..."
  else
    info "retrieving account limits in parallel with direct API checks..."
  fi
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    output="$(mktemp "$tmp_dir/result.XXXXXX")"
    session=""
    if [[ "$tmux_fallback" == "1" ]]; then
      session="$(safe_session_name "${APP_NAME}_${profile}_$(profile_hash "$profile")_$$")"
      tmp_home="$(safe_temp_home "$profile")"
      ACTIVE_SESSIONS+=("$session")
      ACTIVE_TEMP_HOMES+=("$tmp_home")
    fi
    result_files+=("$output")
    result_profiles+=("$profile")
    info "checking profile: $profile"
    (
      trap - EXIT INT TERM
      ACTIVE_SESSIONS=()
      ACTIVE_TEMP_HOMES=()
      ACTIVE_TEMP_FILES=()
      get_one_profile "$profile" "$session" "$tmux_fallback"
    ) >"$output" &
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
