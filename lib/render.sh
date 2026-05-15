render_table() {
  local rows_file="$1"
  local title="${2:-Codex Manager Limits}"
  local recommended="${3:-}"
  local active_profiles="${4:-}"
  local active_profile has_plus=0 has_star=0 has_hash=0

  if [[ -n "$recommended" ]]; then
    if grep -Fxq -- "$recommended" <<<"$active_profiles"; then
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
    $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {
      printf "%s %-29s %-6s %-8s %-11s %-13s\n", marker($1), clip($1, 29), "-", "-", "-", "-"
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

best_profile_from_rows() {
  local rows_file="$1"

  awk -F '\t' '
    $2 != "ERROR" && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ {
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
