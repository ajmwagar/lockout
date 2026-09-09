#!/usr/bin/env bash
#
# Symlink lockout onto PATH and its skill into ~/.claude/skills.
# Symlinks, not copies: `git pull` in this checkout updates the install.

set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd)
BIN_DIR=${LOCKOUT_BIN_DIR:-$HOME/.local/bin}
SKILL_DIR=${LOCKOUT_SKILL_DIR:-$HOME/.claude/skills}
UNINSTALL=0

while [ $# -gt 0 ]; do
  case $1 in
    --uninstall) UNINSTALL=1; shift ;;
    --prefix)    BIN_DIR=${2:-}; shift 2 ;;
    -h|--help)
      printf 'usage: %s [--prefix DIR] [--uninstall]\n' "$0"
      printf '  --prefix DIR   where to link the lockout binary (default ~/.local/bin)\n'
      printf '  --uninstall    remove the links this script created\n'
      exit 0 ;;
    *) printf 'install: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

link() { # target linkname
  local target=$1 name=$2
  if [ -e "$name" ] && [ ! -L "$name" ]; then
    printf '  skip %s (exists and is not a symlink)\n' "$name"
    return 1
  fi
  ln -sfn "$target" "$name" && printf '  link %s -> %s\n' "$name" "$target"
}

if [ "$UNINSTALL" = 1 ]; then
  echo "removing:"
  for p in "$BIN_DIR/lockout" "$SKILL_DIR/lockout"; do
    if [ -L "$p" ]; then rm -f "$p"; printf '  gone %s\n' "$p"
    else printf '  skip %s (not a symlink we made)\n' "$p"; fi
  done
  exit 0
fi

echo "installing lockout from $HERE"
mkdir -p "$BIN_DIR" "$SKILL_DIR" || exit 1
link "$HERE/bin/lockout" "$BIN_DIR/lockout"
link "$HERE/skills/lockout" "$SKILL_DIR/lockout"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\n  note: %s is not on PATH. Add this to your shell rc:\n    export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac

cat <<NEXT

optional: queue plain 'cargo build' with no wrapper by putting the shim first
on PATH (it passes non-compiling subcommands straight through):

    export PATH="$HERE/shim:\$PATH"

verify:
    lockout version && lockout status
NEXT
