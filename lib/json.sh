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
