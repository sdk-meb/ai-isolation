#!/usr/bin/env bash
# uninstall.sh — shortcut for:  ai-sandbox-admin uninstall
#   as root: removes the system install   as a user: removes your user install
# Tools' own data (~/.claude, ~/.config/Cursor, ...) is never touched.
for a in /usr/local/bin/ai-sandbox-admin "$HOME/.local/bin/ai-sandbox-admin" \
         "$(dirname "$(readlink -f "$0")")/ai-sandbox-admin.sh"; do
  [[ -f $a ]] && exec bash "$a" uninstall
done
echo "ai-sandbox-admin not found" >&2; exit 1
