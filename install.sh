#!/usr/bin/env bash
# install.sh — shortcut for:  ai-sandbox-admin.sh install
#   as root (preferred, e.g. `su -`): system-wide in /usr/local, root-owned
#   as a normal user:                 into ~/.local
exec bash "$(dirname "$(readlink -f "$0")")/ai-sandbox-admin.sh" install
