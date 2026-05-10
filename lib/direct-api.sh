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

json_has_required_profile_shape() {
  local json="$1"
  local tokens_json key

  for key in auth_mode OPENAI_API_KEY tokens; do
    json_object_has_key "$json" "$key" || return 1
  done

  tokens_json="$(json_object_field "$json" "tokens")"
  [[ -n "$tokens_json" ]] || return 1

  for key in id_token access_token refresh_token; do
    json_object_has_key "$tokens_json" "$key" || return 1
  done
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
  local tokens_json old_refresh_token response access_token refresh_token id_token

  have curl || return 1

  tokens_json="$(json_object_field "$auth_json" "tokens")"
  old_refresh_token="$(json_string_field "$tokens_json" "refresh_token")"
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
  local source auth_json tokens_json access_token account_id response

  have curl || return 1

  source="$(profile_path "$profile")"
  [[ -f "$source" ]] || die "profile does not exist: $source"

  auth_json="$(tr -d '\n\r' <"$source")"
  json_has_required_profile_shape "$auth_json" || {
    printf '%s\t-\t-\t-\t-\t-\t-\n' "$profile"
    return 0
  }

  tokens_json="$(json_object_field "$auth_json" "tokens")"
  access_token="$(json_string_field "$tokens_json" "access_token")"
  account_id="$(json_string_field "$tokens_json" "account_id")"
  [[ -n "$access_token" ]] || return 1

  if response="$(fetch_usage_response "$access_token" "$account_id")"; then
    parse_usage_response "$profile" "$response"
    return
  fi

  refresh_profile_token "$source" "$auth_json" || return 1

  auth_json="$(tr -d '\n\r' <"$source")"
  tokens_json="$(json_object_field "$auth_json" "tokens")"
  access_token="$(json_string_field "$tokens_json" "access_token")"
  account_id="$(json_string_field "$tokens_json" "account_id")"
  [[ -n "$access_token" ]] || return 1

  response="$(fetch_usage_response "$access_token" "$account_id")" || return 1
  parse_usage_response "$profile" "$response"
}
