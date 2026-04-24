#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="codex-manager"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/codex-manager.sh"
INSTALL_DIR="${HOME}/.local/bin"
TARGET="${INSTALL_DIR}/${APP_NAME}"
BASHRC="${HOME}/.bashrc"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ -f "$SOURCE" ]] || die "missing source script: $SOURCE"

mkdir -p "$INSTALL_DIR"
if [[ -d "$TARGET" && ! -L "$TARGET" ]]; then
  die "install target is an existing directory: $TARGET"
fi
chmod +x "$SOURCE"
ln -sfn "$SOURCE" "$TARGET"

if [[ ! -f "$BASHRC" ]]; then
  touch "$BASHRC"
fi

if ! grep -Fqx "$PATH_LINE" "$BASHRC"; then
  {
    printf '\n'
    printf '# Added by codex-manager install.sh\n'
    printf '%s\n' "$PATH_LINE"
  } >>"$BASHRC"
  printf 'added ~/.local/bin to PATH in %s\n' "$BASHRC"
else
  printf '~/.local/bin is already configured in %s\n' "$BASHRC"
fi

printf 'installed %s -> %s\n' "$TARGET" "$SOURCE"
printf 'restart your shell or run: source ~/.bashrc\n'
