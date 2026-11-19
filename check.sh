#!/usr/bin/env bash
# =============================================================================
# check.sh — prove the sandbox walls hold. Run from a (throwaway) project:
#
#   ai-sandbox-admin check           # installed
#   bash ./check.sh                  # from the source folder
#   AISUP=1 ai-sandbox-admin check   # same, under the exec supervisor
#
# Each test runs a tiny bash command in the built-in "shell" profile, which
# has exactly the common rules every AI tool gets.
# =============================================================================
set -u

SB="${AI_SANDBOX_BIN:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ai-sandbox.sh}"
pass=0 fail=0

# t "<description>" '<bash code that must exit 0 inside the sandbox>'
t() {
  if bash "$SB" run shell -c "$2" </dev/null >/dev/null 2>&1; then
    echo "PASS  $1"; pass=$((pass + 1))
  else
    echo "FAIL  $1"; fail=$((fail + 1))
  fi
}

# --- secrets are invisible ---
t "no ~/.ssh"                    'test ! -e ~/.ssh'
t "no ~/.gnupg"                  'test ! -e ~/.gnupg'
t "no shell history / rc files"  'test ! -e ~/.zsh_history && test ! -e ~/.zshrc'
t "no ssh-agent socket"          'test -z "${SSH_AUTH_SOCK:-}"'
t "no D-Bus session"             'test -z "${DBUS_SESSION_BUS_ADDRESS:-}"'

# --- system and sandbox config are read-only ---
t "/usr is read-only"            '! touch /usr/.ai-sandbox-test'
t "/etc is read-only"            '! touch /etc/.ai-sandbox-test'
t "sandbox config invisible"     'test ! -e ~/.config/ai-sandbox && test ! -e ~/.local/share/ai-sandbox'

# --- project works ---
t "project is writable"          'touch .ai-sandbox-test && rm .ai-sandbox-test'
t "git works"                    'git --version'

# --- process isolation ---
t "own PID namespace"            'test "$(cat /proc/1/comm)" = bwrap'
t "host processes invisible"     'test "$(ls /proc | grep -c "^[0-9]")" -lt 10'
t "cannot become root"           '! sudo -n true'
t "no sandbox in the sandbox"    'test -d /run/.ai-sandbox && test "$AI_SANDBOX" = shell'

# --- network is on (the tools need their API) ---
t "DNS works"                    'getent hosts api.anthropic.com'

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
