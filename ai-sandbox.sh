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
CONF_HINTS=0   # "shared with [x]" hints: add/sync show them, not every start

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox"

# =============================================================================
# 0. Already inside a sandbox? Then don't build another one.
# =============================================================================
# A sandboxed tool may call another sandboxed tool (e.g. claude runs `cursor`,
# whose wrapper in /usr/bin is visible inside). The caller is already behind
# the walls, so run the real program right here, in the CURRENT sandbox: it
# gets the caller's walls (never more than that), not its own tools.conf entry
# (which is invisible in here anyway). No second bwrap, no nested namespaces.
#
# "Inside" = the marker dir that only this launcher creates (/run is root-owned
# on the host, so nobody can fake it there) AND pid 1 is bwrap. An env var
# alone would not do: anything could set it on the host to skip the sandbox.
inside_sandbox() {
  [[ -d /run/.ai-sandbox && $(cat /proc/1/comm 2>/dev/null) == bwrap ]]
}
# real_of_wrapper FILE NAME  ->  the "Real program:" line of FILE, if FILE is
# a wrapper that runs NAME
real_of_wrapper() {
  local w=$1 name=$2 line
  is_wrapper "$w" || return 1
  line=$(grep -m1 '^exec ' "$w") || return 1
  [[ $line =~ \ run\ (--via\ \'[^\']*\'\ )?$name\ \"\$@\"$ ]] || return 1
  sed -n 's/^# Real program: //p' "$w" | head -n1
}
run_nested() {   # run_nested [--via ORIG] <tool> [args...]
  local via="" name w real="" d
  if [[ ${1:-} == --via ]]; then via=${2:-}; shift 2 || die "usage: ai-sandbox run [--via ORIG] <tool> [args...]"; fi
  name=${1:-}
  [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "usage: ai-sandbox run <tool> [args...]"
  shift
  local outer=${AI_SANDBOX:-another tool}
  [[ $name != shell ]] || die "already inside the sandbox of [$outer]"
  # the wrapper that called us: --via names it; else look for it on PATH
  local -a cands=()
  if [[ -n $via ]]; then cands=("$via"); else
    IFS=: read -r -a dirs <<<"${PATH:-/usr/local/bin:/usr/bin:/bin}"
    for d in "${dirs[@]}" /usr/local/bin /usr/bin; do cands+=("$d/$name"); done
  fi
  for w in "${cands[@]}"; do
    if real=$(real_of_wrapper "$w" "$name") && [[ -n $real ]]; then break; fi
    real=""
  done
  [[ -n $real ]] || die "[$name] is not available inside the sandbox of [$outer] (its wrapper isn't visible here)"
  [[ -f $real && -x $real ]] && ! is_wrapper "$real" \
    || die "[$name] is not available inside the sandbox of [$outer] (real program $real isn't visible here)"
  if [[ ${AI_DEBUG:-0} == 1 ]]; then echo "ai-sandbox: inside [$outer], running $real directly" >&2; fi
  exec "$real" "$@"
}
if [[ ${1:-} == run ]] && inside_sandbox; then shift; run_nested "$@"; fi

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

# runs = B C ...: this tool starts those sandboxed tools (vscode -> copilot,
# a CLI -> a GUI app). They run inside THIS sandbox (see section 3), so it
# also gets their files, env and exec rules, and the GUI parts (Wayland, GPU)
# if one of them is a gui tool. All of it goes through the same checks below.
RUNS_GUI=0
for b in "${T_RUNS[@]}"; do
  [[ $b != "$NAME" ]] || continue
  if ! got=$(conf_load "$CONF/tools.conf" "$b" 2>/dev/null && {
        printf 'type\t%s\n' "$T_TYPE"
        for x in "${T_RW[@]}";        do printf 'rw\t%s\n' "$x"; done
        for x in "${T_RWFILE[@]}";    do printf 'rw-file\t%s\n' "$x"; done
        for x in "${T_RO[@]}";        do printf 'ro\t%s\n' "$x"; done
        for x in "${T_ENVSET[@]}";    do printf 'env-set\t%s\n' "$x"; done
        for x in "${T_ENVPASS[@]}";   do printf 'env-pass\t%s\n' "$x"; done
        for x in "${T_EXECALLOW[@]}"; do printf 'exec-allow\t%s\n' "$x"; done; }); then
    warn "[$NAME] runs = $b: no [$b] in tools.conf — ignored"; continue
  fi
  while IFS=$'\t' read -r k v; do
    case $k in
      type)       if [[ $v == gui ]]; then RUNS_GUI=1; fi ;;
      rw)         T_RW+=("$v") ;;
      rw-file)    T_RWFILE+=("$v") ;;
      ro)         T_RO+=("$v") ;;
      env-set)    T_ENVSET+=("$v") ;;
      env-pass)   T_ENVPASS+=("$v") ;;
      exec-allow) T_EXECALLOW+=("$v") ;;
    esac
  done <<<"$got"
done
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
# marker: "this is an ai-sandbox" (see section 0); a nested wrapper call then
# runs the real program here instead of building a sandbox in the sandbox
add --dir /run/.ai-sandbox

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
add --setenv AI_SANDBOX "$NAME"                 # informational only, never trusted
pass_env TERM COLORTERM LANG LANGUAGE LC_ALL EDITOR VISUAL

# =============================================================================
# 3. Per-tool rules (from tools.conf)
# =============================================================================
for d in "${T_RO[@]}";     do add --ro-bind-try "$d" "$d"; done
for d in "${T_RW[@]}";     do bind_dir "$d"; done
for f in "${T_RWFILE[@]}"; do bind_file "$f"; done

# The OTHER sandboxed tools in your tools.conf: their real programs, read-only,
# under their original names. A tool that runs another one (claude -> copilot)
# then just runs the original program, inside THIS sandbox: no second box,
# and it gets this tool's walls, never more. Its own files come along only if
# this tool lists it in `runs =`; else it may have to log in (or use GH_TOKEN...).
# A script in your home (e.g. an npm package's index.js) also gets its folder,
# read-only, unless that folder is your home, a secret, the project or one of
# this tool's writable paths. Their data: only with `runs = <tool>` (section 1).
other_programs() {   # -> "real|exec|wrapped|dir (\x1f-separated: a tab
                     # would merge empty fields in `read`)" per program
  local n j e r d
  for n in $(conf_tools "$CONF/tools.conf"); do
    [[ $n != "$NAME" ]] || continue
    ( conf_load "$CONF/tools.conf" "$n" 2>/dev/null || exit 0
      for j in "${!T_EXECS[@]}"; do
        e=${T_EXECS[j]} r=""
        if (( j == 0 )) && [[ -n $T_EXECNEWEST ]] && r=$(newest_of "$T_EXECNEWEST"); then r=$(readlink -f -- "$r"); fi
        [[ -n $r ]] || r=$(readlink -f -- "$e" 2>/dev/null) || continue
        [[ -f $r && -x $r ]] && ! is_wrapper "$r" || continue
        d=""
        if [[ $r == "$HOME"/* && $(head -c 2 "$r" 2>/dev/null) == '#!' ]]; then d=$(dirname "$r"); fi
        printf '%s\x1f%s\x1f%s\x1f%s\n' "$r" "$e" "${T_WRAPS[j]:-}" "$d"
      done )
  done
}
overlaps() {   # overlaps A B -> A is, contains or sits inside B
  local a b; a=$(readlink -m -- "$1"); b=$(readlink -m -- "$2")
  [[ $a == "$b" || $a == "$b"/* || $b == "$a"/* ]]
}
dir_ok() {     # dir_ok DIR -> safe to show read-only
  local d=$1 p
  [[ $(readlink -m -- "$d") != "$(readlink -m -- "$HOME")" ]] || return 1
  if touches_secret "$d" >/dev/null; then return 1; fi
  if overlaps "$d" "$PROJECT"; then return 1; fi
  # a read-only mount over one of this tool's writable paths would break it
  for p in "${T_RW[@]}" "${T_RWFILE[@]}"; do if overlaps "$d" "$p"; then return 1; fi; done
  return 0
}
OTHER=() ALSO=()
while IFS= read -r l; do OTHER+=("$l"); done < <(other_programs)
# folders first, then the programs: a later folder mount would hide a program
# bound into it earlier (e.g. ~/.local/bin would bring back a wrapper)
SHOWN=()
for l in "${OTHER[@]}"; do
  IFS=$'\x1f' read -r r e w d <<<"$l"
  [[ -n $d ]] || continue
  if dir_ok "$d"; then add --ro-bind "$d" "$d"; SHOWN+=("$d")
  else warn "[$NAME] other tool's program $r: its folder $d can't be shown inside — it may not run there"; fi
done
in_shown() { local s; for s in "${SHOWN[@]}"; do if [[ $1 == "$s"/* ]]; then return 0; fi; done; return 1; }
# from_host PATH -> PATH comes from the host inside (outside the empty home,
# or under the project / an ro / rw / shown folder), i.e. it already exists
# there exactly as it does outside
from_host() {
  local s
  [[ $1 == "$HOME"/* ]] || return 0
  for s in "$PROJECT" "${T_RO[@]}" "${T_RW[@]}" "${SHOWN[@]}"; do
    if [[ $1 == "$s"/* ]]; then return 0; fi
  done
  return 1
}
# put_prog MODE REAL PATH: make PATH run REAL inside.
# - PATH comes from the host and is a SYMLINK (e.g. /usr/bin/.ai-real-x ->
#   /usr/share/...): leave it, it already leads to REAL. bwrap can't mount
#   onto it anyway: it resolves absolute links before the new root exists
#   ("Can't create file at ..."). If it leads elsewhere (an older version),
#   REAL is mounted over that target instead.
# - PATH comes from the host as a file (a wrapper): REAL is mounted over it.
# - PATH is in the empty home: MODE=link makes a SYMLINK to REAL, as on the
#   host (npm-style scripts find their modules through it); MODE=bind mounts.
put_prog() {
  local mode=$1 real=$2 p=$3 t
  if from_host "$p"; then
    if [[ -L $p ]]; then
      t=$(readlink -f -- "$p" 2>/dev/null) || t=""
      if [[ -n $t && $t != "$real" && -f $t ]]; then add --ro-bind "$real" "$t"; fi
    else
      add --ro-bind "$real" "$p"
    fi
  elif [[ $mode == link ]]; then add --symlink "$real" "$p"
  else add --ro-bind "$real" "$p"; fi
}
for l in "${OTHER[@]}"; do
  IFS=$'\x1f' read -r r e w d <<<"$l"
  if [[ -z $d ]] || ! in_shown "$r"; then add --ro-bind "$r" "$r"; fi
  if [[ $e != "$r" ]]; then put_prog link "$r" "$e"; fi
  if [[ -n $w ]]; then put_prog link "$r" "$w"; fi
  ALSO+=("$r" "$e" ${w:+"$w"})
done

# the program itself (read-only), also under the name it was configured with
add --ro-bind "$REAL" "$REAL"
if [[ $T_EXEC != "$REAL" ]]; then put_prog bind "$REAL" "$T_EXEC"; fi
# renamed tool: inside, the ORIGINAL path is the real program again (the
# wrapper only exists outside), so the tool can still call itself by name
if [[ -n $T_WRAPPED ]]; then put_prog bind "$REAL" "$T_WRAPPED"; fi
# the tool's OTHER wrapped programs: same, so they can call each other
# (e.g. a CLI script that runs the app binary next to it)
for j in "${!T_WRAPS[@]}"; do
  [[ ${T_WRAPS[j]} != "$T_WRAPPED" ]] || continue
  r=$(readlink -f -- "${T_EXECS[j]}" 2>/dev/null) || continue
  if [[ ! -f $r || ! -x $r ]] || is_wrapper "$r"; then
    warn "[$NAME] ${T_WRAPS[j]}: real program ${T_EXECS[j]} missing or a wrapper — not available inside"
    continue
  fi
  add --ro-bind "$r" "$r"; put_prog bind "$r" "${T_WRAPS[j]}"
  if [[ ${T_EXECS[j]} != "$r" ]]; then put_prog bind "$r" "${T_EXECS[j]}"; fi
  ALSO+=("$r" "${T_EXECS[j]}")
done

for kv in "${T_ENVSET[@]}"; do add --setenv "${kv%%=*}" "${kv#*=}"; done
pass_env "${T_ENVPASS[@]}"

if [[ $T_TYPE != gui && $RUNS_GUI == 1 && -z ${WAYLAND_DISPLAY:-} ]]; then
  warn "[$NAME] runs a gui tool, but there is no Wayland session: its windows won't open"
  RUNS_GUI=0
fi
if [[ $T_TYPE == gui || $RUNS_GUI == 1 ]]; then
  [[ -n ${WAYLAND_DISPLAY:-} ]] || die "[$NAME] is a gui tool and needs a Wayland session"
  # One shared runtime dir + /tmp per app, so a 2nd launch (e.g. the browser
  # login callback) finds the running window instead of fighting over locks.
  SHARED="$RT/ai-sandbox/$NAME"
  act_mkdir "$SHARED/run" 700; act_mkdir "$SHARED/tmp" 700; chmod 700 "$RT/ai-sandbox" "$SHARED"
  # a CLI that only RUNS a gui tool keeps its own fresh /tmp
  if [[ $T_TYPE == gui ]]; then add --bind "$SHARED/tmp" /tmp; fi
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
