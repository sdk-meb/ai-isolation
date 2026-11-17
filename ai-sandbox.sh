#!/usr/bin/env bash
# =============================================================================
# ai-sandbox — run an AI tool inside bubblewrap, as described in YOUR config
#              (installed as /usr/local/bin/ai-sandbox by root — preferred —
#               or as ~/.local/bin/ai-sandbox by a user install)
#
#   ai-sandbox run [--via ORIG] <tool> [args...]
#                                     start <tool> sandboxed. You rarely type
#                                     this: the wrapper that replaced the
#                                     original program (e.g. ~/.local/bin/claude)
#                                     does it, so every caller is sandboxed.
#                                     --via: which of the tool's wrapped
#                                     programs was called (extra wrappers only)
#   ai-sandbox list                   your sandboxed tools
#   ai-sandbox check                  test the walls from the current directory
#
# Config (per user, private, created from the defaults on first use):
#   ~/.config/ai-sandbox/tools.conf    which tools, what each may see
#   ~/.config/ai-sandbox/policy.conf   exec rules for aisup
#   It is never visible inside the sandbox, so a tool can't change its rules.
#
# Per-run knobs:
#   AI_PROJECT=/path  use another project dir than tools.conf says
#   AISUP=1           force the seccomp exec supervisor on
#   AI_NEW_SESSION=0  stay attached to the terminal (see README: TIOCSTI)
#   AI_DEBUG=1        print the final command
# =============================================================================
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
case $HERE in
  /usr/local/bin)     LIB=/usr/local/lib/ai-sandbox ;;      # root install
  "$HOME/.local/bin") LIB=$HOME/.local/lib/ai-sandbox ;;    # user install
  *)                  LIB=$HERE ;;                          # source folder (testing)
esac
# shellcheck source=lib.sh
source "$LIB/lib.sh"

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox"

# Log what this run creates on the host (folders/files it binds), so
# ai-sandbox-undo can remove them again. Nothing is logged if nothing is new.
act_begin "ai-sandbox $*"

# First use: copy the default config into the user's home.
ensure_conf "$CONF" "$LIB"

# The config must be yours and writable by nobody else.
for f in "$CONF/tools.conf" "$CONF/policy.conf"; do
  read -r owner mode < <(stat -c '%u %a' "$f") || die "missing $f"
  (( owner == $(id -u) && (8#$mode & 8#022) == 0 )) \
    || die "$f must belong to you and not be group/world-writable (chmod 600 $f)"
done

case "${1:-}" in
  run)   shift ;;
  list)  list_tools "$CONF/tools.conf"; exit 0 ;;
  check) AI_SANDBOX_BIN="$SELF" exec bash "$LIB/check.sh" ;;
  *)     die "usage: ai-sandbox run <tool> [args...] | list | check" ;;
esac

# =============================================================================
# 1. Load the tool's description
# =============================================================================
VIA=""
if [[ ${1:-} == --via ]]; then VIA=${2:-}; shift 2 || die "usage: ai-sandbox run [--via ORIG] <tool> [args...]"; fi
NAME="${1:-}"
[[ $NAME =~ ^[A-Za-z0-9_-]+$ ]] || die "usage: ai-sandbox run <tool> [args...]"
shift

if [[ $NAME == shell ]]; then
  # built-in test profile: bash with only the common rules
  conf_load /dev/null shell || true
  T_EXEC=/bin/bash
else
  conf_load "$CONF/tools.conf" "$NAME" \
    || die "'$NAME' is not in $CONF/tools.conf (add it: ai-sandbox-admin add $NAME)"
fi

# a tool with several wrapped programs: run the one whose wrapper was called
if [[ -n $VIA ]]; then
  i=-1
  for j in "${!T_WRAPS[@]}"; do if [[ ${T_WRAPS[j]} == "$VIA" ]]; then i=$j; fi; done
  (( i >= 0 )) || die "[$NAME] '$VIA' is not one of its wrapped programs (see tools.conf)"
  # exec-newest is about the main program only
  if (( i > 0 )); then T_EXEC=${T_EXECS[i]} T_WRAPPED=${T_WRAPS[i]} T_EXECNEWEST=""; fi
fi

[[ $T_EXEC == /* ]] || die "[$NAME] exec must be an absolute path or start with ~/"
# exec-newest: run the newest version in a versions/ folder. Claude Code's
# updater (and others like it) leaves a non-symlink launcher alone and only
# drops new versions there, so the renamed .ai-real-<tool> link would go stale.
REAL=""
if [[ -n $T_EXECNEWEST ]] && n=$(newest_of "$T_EXECNEWEST"); then
  REAL=$(readlink -f -- "$n")
fi
if [[ -z $REAL ]]; then REAL=$(readlink -f -- "$T_EXEC" 2>/dev/null) || REAL=""; fi
if [[ -z $REAL || ! -f $REAL || ! -x $REAL ]]; then
  if [[ -n $T_WRAPPED ]] && is_diverted "$T_WRAPPED"; then
    die "[$NAME] program not found: $T_EXEC — its Debian package was probably removed; clean up with: ai-sandbox-admin remove $NAME"
  fi
  die "[$NAME] program not found: $T_EXEC"
fi
if is_wrapper "$REAL"; then
  die "[$NAME] exec points at a sandbox wrapper (loop) — run: ai-sandbox-admin sync"
fi

BWRAP="$(command -v bwrap)" || die "bubblewrap is not installed"

# Electron "node mode": an Electron app's own CLI script (e.g. /usr/bin/cursor,
# which runs ELECTRON_RUN_AS_NODE=1 /usr/share/cursor/cursor cli.js "$@") calls
# the wrapped binary as plain Node. Keep that variable, skip the Electron-only
# `args`, and let the window that cli.js opens outlive cli.js (see section 4).
NODE_MODE=0
if [[ $T_TYPE == gui && -n ${ELECTRON_RUN_AS_NODE:-} ]]; then NODE_MODE=1; fi
ME="${USER:-$(id -un)}"
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# --- the project directory ---------------------------------------------------
if [[ -n ${AI_PROJECT:-} ]]; then PROJECT=$AI_PROJECT
elif [[ $T_PROJECT == cwd ]];  then PROJECT=$PWD
else PROJECT=$T_PROJECT
fi
PROJECT="$(readlink -f "$PROJECT")"
case "$PROJECT" in
  /|/home|/usr|/etc|/tmp|"$HOME")
    die "refusing to expose '$PROJECT'; cd into a project directory first" ;;
esac
START="$PROJECT"
case "$PWD/" in "$PROJECT"/*) START="$PWD" ;; esac   # stay in a subdir if we are in one

# conf_check_isolation only sees a FIXED project; a cwd project is known only
# now. Same rule: it may not be, contain or sit inside another tool's data
# (e.g. `cd ~/.config/Code && claude` while [code] has rw = ~/.config/Code).
if [[ -f $CONF/tools.conf ]]; then
  while IFS=$'\t' read -r owner path; do
    [[ $owner == "$NAME" ]] && continue
    rp=$(readlink -m -- "$path")
    if [[ $PROJECT == "$rp" || $PROJECT == "$rp"/* || $rp == "$PROJECT"/* ]]; then
      die "[$NAME] project '$PROJECT' would expose the data of [$owner] ($path) — refusing; a tool may only see its own data dir"
    fi
  done < <(conf_data_paths "$CONF/tools.conf")
fi

# --- never let a writable path expose the sandbox's own files ---------------
# (otherwise the tool could rewrite its rules, wrappers or your shell rc)
PROTECT=("$CONF" "$(act_state_dir)"
         "$HOME/.local/lib/ai-sandbox" "$HOME/.local/bin/ai-sandbox"
         "$HOME/.local/bin/ai-sandbox-admin" "$HOME/.zshrc" "$HOME/.bashrc")
if [[ -n $T_WRAPPED ]]; then PROTECT+=("$T_WRAPPED"); fi   # the wrapper at the original path
# every OTHER tool's wrapper too (rw = ~/.local/bin would let this tool
# overwrite them); grep is enough here, the config is already validated
while IFS= read -r w; do
  PROTECT+=("$(expand_home "$(trim "$w")")")
done < <(sed -n 's/#.*//; s/^[[:space:]]*wrapped[[:space:]]*=//p' "$CONF/tools.conf")
exposes() {            # exposes PATH -> prints the protected path it contains
  local w=$1 p
  for p in "${PROTECT[@]}"; do
    if [[ $p == "$w" || $p == "$w"/* ]]; then echo "$p"; return 0; fi
  done
  return 1
}
for w in "$PROJECT" "${T_RW[@]}" "${T_RWFILE[@]}"; do
  if p=$(exposes "$w"); then die "[$NAME] '$w' would be writable inside and contains $p — refusing"; fi
done

# --- never expose well-known secrets, whatever tools.conf says ---------------
# The list is <lib>/secrets.list (root-owned in a root install, never visible inside).
secrets_load "$LIB"     # <lib>/secrets.list + /etc/ai-sandbox/secrets.conf, or die
for w in "$PROJECT" "${T_RW[@]}" "${T_RWFILE[@]}" "${T_RO[@]}"; do
  if s=$(touches_secret "$w"); then die "[$NAME] '$w' would expose $s inside the sandbox — refusing"; fi
done

# --- helpers -----------------------------------------------------------------
ARGS=()
add()       { ARGS+=("$@"); }
bind_dir()  { act_mkdir "$1"; add --bind "$1" "$1"; }         # create on host if missing
bind_file() { [[ -e $1 ]] || act_write "$1" 600 </dev/null; add --bind "$1" "$1"; }
pass_env()  { local v; for v in "$@"; do if [[ -n ${!v:-} ]]; then add --setenv "$v" "${!v}"; fi; done; }

# =============================================================================
# 2. Common rules (every tool)
# =============================================================================
# New namespaces for everything except the network. bwrap sets no_new_privs:
# nothing inside can gain privileges (sudo/setuid stop working) or load a
# looser seccomp filter.
add --unshare-all --share-net
# launcher dies -> sandbox dies. Not in Electron node mode: there the launcher
# returns when the CLI part ends, and the sandbox lives on while its window does.
if [[ $NODE_MODE == 0 ]]; then add --die-with-parent; fi
add --cap-drop ALL

# Own session: blocks TIOCSTI (a program typing commands into your real
# terminal). Cost: CLI tools don't see terminal resizes. With aisup on,
# seccomp blocks TIOCSTI instead and AI_NEW_SESSION=0 is safe.
if [[ ${AI_NEW_SESSION:-1} == 1 ]]; then add --new-session; fi

# Read-only operating system (Debian 12 = merged /usr).
add --ro-bind /usr /usr
add --symlink usr/bin /bin --symlink usr/sbin /sbin
add --symlink usr/lib /lib --symlink usr/lib64 /lib64
add --ro-bind /etc /etc
add --ro-bind-try /run/systemd/resolve /run/systemd/resolve   # DNS
add --ro-bind-try /run/NetworkManager /run/NetworkManager

add --proc /proc --dev /dev --tmpfs /dev/shm --tmpfs /tmp

# Empty home: only what is bound below exists. Never visible: ~/.ssh,
# ~/.gnupg, ~/.aws, browser profiles, shell history, other tools' tokens,
# and the sandbox config itself.
add --tmpfs "$HOME"
add --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig"
add --ro-bind-try "$HOME/.config/git" "$HOME/.config/git"

add --bind "$PROJECT" "$PROJECT"
add --chdir "$START"

# Clean environment (no SSH_AUTH_SOCK, D-Bus address, random tokens...).
add --clearenv
add --setenv HOME "$HOME" --setenv USER "$ME" --setenv LOGNAME "$ME"
add --setenv PATH "$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
add --setenv SHELL /bin/bash
pass_env TERM COLORTERM LANG LANGUAGE LC_ALL EDITOR VISUAL

# =============================================================================
# 3. Per-tool rules (from tools.conf)
# =============================================================================
for d in "${T_RO[@]}";     do add --ro-bind-try "$d" "$d"; done
for d in "${T_RW[@]}";     do bind_dir "$d"; done
for f in "${T_RWFILE[@]}"; do bind_file "$f"; done

# the program itself (read-only), also under the name it was configured with
add --ro-bind "$REAL" "$REAL"
if [[ $T_EXEC != "$REAL" ]]; then add --ro-bind "$REAL" "$T_EXEC"; fi
# renamed tool: inside, the ORIGINAL path is the real program again (the
# wrapper only exists outside), so the tool can still call itself by name
if [[ -n $T_WRAPPED ]]; then add --ro-bind "$REAL" "$T_WRAPPED"; fi
# the tool's OTHER wrapped programs: same, so they can call each other
# (e.g. a CLI script that runs the app binary next to it)
ALSO=()
for j in "${!T_WRAPS[@]}"; do
  [[ ${T_WRAPS[j]} != "$T_WRAPPED" ]] || continue
  r=$(readlink -f -- "${T_EXECS[j]}" 2>/dev/null) || continue
  if [[ ! -f $r || ! -x $r ]] || is_wrapper "$r"; then
    warn "[$NAME] ${T_WRAPS[j]}: real program ${T_EXECS[j]} missing or a wrapper — not available inside"
    continue
  fi
  add --ro-bind "$r" "$r" --ro-bind "$r" "${T_WRAPS[j]}"
  if [[ ${T_EXECS[j]} != "$r" ]]; then add --ro-bind "$r" "${T_EXECS[j]}"; fi
  ALSO+=("$r" "${T_EXECS[j]}")
done

for kv in "${T_ENVSET[@]}"; do add --setenv "${kv%%=*}" "${kv#*=}"; done
pass_env "${T_ENVPASS[@]}"

if [[ $T_TYPE == gui ]]; then
  [[ -n ${WAYLAND_DISPLAY:-} ]] || die "[$NAME] is a gui tool and needs a Wayland session"
  # One shared runtime dir + /tmp per app, so a 2nd launch (e.g. the browser
  # login callback) finds the running window instead of fighting over locks.
  SHARED="$RT/ai-sandbox/$NAME"
  act_mkdir "$SHARED/run" 700; act_mkdir "$SHARED/tmp" 700; chmod 700 "$RT/ai-sandbox" "$SHARED"
  add --bind "$SHARED/tmp" /tmp
  add --bind "$SHARED/run" "$RT"
  # Wayland only. No X11 on purpose: any X client can read the keystrokes
  # and screen of every other X window.
  add --bind "$RT/$WAYLAND_DISPLAY" "$RT/$WAYLAND_DISPLAY"
  add --dev-bind-try /dev/dri /dev/dri          # GPU
  add --ro-bind /sys /sys                       # hardware detection (read-only)
  add --setenv XDG_RUNTIME_DIR "$RT" --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
  add --setenv XDG_SESSION_TYPE wayland
fi

if [[ $NODE_MODE == 1 ]]; then
  # cli.js prints/answers, then starts the window detached and exits. In a
  # PID namespace that exit would kill the window, so a tiny sh (pid 2) runs
  # it, reports its exit code, and then waits silently until it is the last
  # process left (pid 1 is bwrap's init; the loop test forks nothing).
  # Its stdout/stderr/exit code go through fifos that ONLY this sh opens (by
  # path): bwrap itself never holds your terminal or pipe, so `cursor .`,
  # `$(cursor --version)` and `cursor . | cat` all return when cli.js ends.
  ST=$(mktemp -d "$RT/ai-sandbox/.io.XXXXXX")
  mkfifo -m 600 "$ST/out" "$ST/err" "$ST/rc"
  add --bind "$ST" /run/ai-io
  add --setenv ELECTRON_RUN_AS_NODE "$ELECTRON_RUN_AS_NODE"
  CMD=(/bin/sh -c 'exec 3>/run/ai-io/rc >/run/ai-io/out 2>/run/ai-io/err
       "$@"; r=$?; exec </dev/null >/dev/null 2>&1; echo $r >&3; exec 3>&-
       while set -- /proc/[0-9]*; [ $# -gt 2 ]; do sleep 2; done' ai-sandbox "$REAL" "$@")
else
  CMD=("$REAL" "${T_ARGS[@]}" "$@")
fi

# =============================================================================
# 4. Launch (optionally under the seccomp exec supervisor)
# =============================================================================
FULL=("$BWRAP" "${ARGS[@]}" "${CMD[@]}")

USE_AISUP=0
if [[ ${AISUP:-0} == 1 || $T_AISUP == yes ]]; then
  USE_AISUP=1
  [[ -x $LIB/aisup ]] || die "aisup is not installed (apt install libseccomp-dev gcc, then ai-sandbox-admin install again)"
  act_mkdir "$HOME/.local/state"                # aisup writes its log here
fi
# Rules for this run = "the tool may start itself" + your policy.conf.
policy_for_this_run() {
  printf 'allow %s *\n' "$BWRAP"
  printf 'allow %s*\n' "$REAL" "$T_EXEC" "${ALSO[@]}"
  if [[ $NODE_MODE == 1 ]]; then printf 'allow /bin/sh -c *\nallow /usr/bin/sleep *\n'; fi
  local p; for p in "${T_EXECALLOW[@]}"; do printf 'allow %s\n' "$p"; done
  cat "$CONF/policy.conf"
}
launch() {   # launch [prefix...] — exec the sandbox, optionally under aisup
  if [[ $USE_AISUP == 1 ]]; then
    if [[ ${AI_DEBUG:-0} == 1 ]]; then printf '%q ' "$@" "$LIB/aisup" '<(policy)' "${FULL[@]}" >&2; echo >&2; fi
    export AISUP_NAME="$NAME"                   # shown in the approval dialog
    # The <(...) must be on the exec line itself: bash closes a process
    # substitution's pipe as soon as the command that created it ends.
    exec "$@" "$LIB/aisup" <(policy_for_this_run) "${FULL[@]}"
  fi
  if [[ ${AI_DEBUG:-0} == 1 ]]; then printf '%q ' "$@" "${FULL[@]}" >&2; echo >&2; fi
  exec "$@" "${FULL[@]}"
}

if [[ $NODE_MODE == 0 ]]; then launch; fi

# Electron node mode: the sandbox runs in its own session (closing the
# terminal doesn't kill the window). Relay cli.js's output and return its
# exit code; bwrap's own messages go to a file, shown if it fails to start.
exec 4<>"$ST/rc"
cat "$ST/out" & C1=$!
cat "$ST/err" >&2 & C2=$!
( exec 4>&-; launch setsid ) 0<&0 >/dev/null 2>"$ST/bwrap.log" &
BPID=$!
rc=""
until read -r -t 1 rc <&4; do
  if ! kill -0 "$BPID" 2>/dev/null; then            # sandbox failed to start
    kill "$C1" "$C2" 2>/dev/null; cat "$ST/bwrap.log" >&2; rm -rf "$ST"
    wait "$BPID" && exit 1 || exit $?
  fi
done
wait "$C1" "$C2" || true                             # rest of cli.js's output
if [[ ${AI_DEBUG:-0} == 1 ]]; then cat "$ST/bwrap.log" >&2; fi
rm -rf "$ST"
exit "${rc:-1}"
