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

json_object_keys() {
  local json="$1"

  awk '
    BEGIN { RS = "\0" }
    {
      in_string = 0
      escaped = 0
      depth = 0
      want_key = 0
      key = ""

      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)

        if (escaped) {
          escaped = 0
          if (in_string && want_key) key = key ch
          continue
        }

        if (ch == "\\" && in_string) {
          escaped = 1
          continue
        }

        if (ch == "\"") {
          if (!in_string) {
            in_string = 1
            if (depth == 1) {
              want_key = 1
              key = ""
            }
          } else {
            in_string = 0
            if (want_key) {
              j = i + 1
              while (j <= length($0) && substr($0, j, 1) ~ /[[:space:]]/) j++
              if (substr($0, j, 1) == ":") print key
            }
            want_key = 0
          }
          continue
        }

        if (in_string) {
          if (want_key) key = key ch
          continue
        }

        if (ch == "{") {
          depth++
        } else if (ch == "}") {
          depth--
        }
      }
    }
  ' <<<"$json"
}

json_object_has_key() {
  local json="$1"
  local key="$2"

  json_object_keys "$json" | grep -Fxq -- "$key"
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
