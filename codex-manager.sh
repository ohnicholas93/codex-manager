#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/config.sh"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/profiles.sh"
source "$LIB_DIR/json.sh"
source "$LIB_DIR/direct-api.sh"
source "$LIB_DIR/tmux-fallback.sh"
source "$LIB_DIR/render.sh"
source "$LIB_DIR/commands.sh"

main "$@"
