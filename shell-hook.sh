# shell-hook.sh — re-wrap tools that an update replaced.
#
# Sourced from /etc/zsh/zshrc + /etc/bash.bashrc (root install) or from
# ~/.zshrc + ~/.bashrc (user install).
#
# Every sandboxed tool is a wrapper at its ORIGINAL path; the real program
# sits next to it as <prefix><tool>. If an update (e.g. `claude update`)
# put a new real program over the wrapper, this moves it aside and wraps it
# again. It is silent unless it had to fix something, and it never asks for
# sudo (for root-owned folders it only warns: run `ai-sandbox-admin sync`).

if [ "$(id -u)" != 0 ] && command -v ai-sandbox-admin >/dev/null 2>&1; then
  ai-sandbox-admin verify -q
fi
