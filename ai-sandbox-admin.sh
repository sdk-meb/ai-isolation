#!/usr/bin/env bash
# =============================================================================
# ai-sandbox-admin — install the AI sandbox and manage YOUR sandboxed AI tools
#
#   install        install the programs:
#                    as root (preferred) -> /usr/local, root-owned
#                    as a normal user    -> ~/.local
#   uninstall      remove the programs (as root: system; as user: yours)
#
#   --- as your normal user; config: ~/.config/ai-sandbox/ ---
#   search <name>  find programs and menu launchers matching a name
#   add [name]     interactive: search, pick, answer a few questions
#   remove <name>  take a tool out of the sandbox (its data is kept)
#   list           show your sandboxed tools
#   sync           wrap every tool in tools.conf (asks before a first rename)
#   verify [-q]    re-wrap tools that an update replaced
#   reset          put every real program back (config kept)
#
# Every change is logged (root: /var/lib/ai-sandbox/actions.log, user:
# ~/.local/state/ai-sandbox/actions.log) with a backup of anything it
# overwrites or deletes. Reverse it with:  ai-sandbox-undo list | last | all
#
# How a tool is sandboxed: the real program <dir>/<tool> is moved to
# <dir>/<prefix><tool> and a tiny wrapper takes its place:
#     exec /usr/local/bin/ai-sandbox run <tool> "$@"
# So every caller (terminal, menu launcher, IDE, script, absolute path)
# gets the sandbox. No extra bin folder, no PATH tricks.
# =============================================================================
set -euo pipefail

SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# --- where the programs live ---------------------------------------------------
SYS_BIN=/usr/local/bin                SYS_LIB=/usr/local/lib/ai-sandbox     # root install
USR_BIN=$HOME/.local/bin              USR_LIB=$HOME/.local/lib/ai-sandbox   # user install

# --- per-user files (always in the user's home) --------------------------------
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox     # tools.conf, policy.conf
TOOLS=$CONF/tools.conf
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
# left over from the old PATH-wrapper design; only cleaned up now
OLD_WRAP=$DATA/ai-sandbox/bin
OLD_DBACK=$DATA/ai-sandbox/desktop-backup
APPS=$DATA/applications
MARK="# ai-sandbox: keep sandbox wrappers first in PATH"   # rc-file marker (kept for uninstall)

for l in "$SRC/lib.sh" "$SYS_LIB/lib.sh" "$USR_LIB/lib.sh"; do
  if [[ -f $l ]]; then source "$l"; break; fi
done
declare -F die >/dev/null || { echo "ai-sandbox-admin: lib.sh not found" >&2; exit 1; }

# which install is active (root install wins: it is the preferred one)
runner()        { if [[ -x $SYS_BIN/ai-sandbox ]]; then echo "$SYS_BIN/ai-sandbox"
                  elif [[ -x $USR_BIN/ai-sandbox ]]; then echo "$USR_BIN/ai-sandbox"
                  else return 1; fi; }
installed_lib() { if [[ -x $SYS_BIN/ai-sandbox ]]; then echo "$SYS_LIB"
                  elif [[ -x $USR_BIN/ai-sandbox ]]; then echo "$USR_LIB"
                  else echo "$SRC"; fi; }

need_user() {
  [[ $EUID -ne 0 ]] || die "run this as your normal user: the config is per user (~/.config/ai-sandbox)"
}

# -----------------------------------------------------------------------------
# small interactive helpers (always read the keyboard, even inside loops)
# -----------------------------------------------------------------------------
ask() {        # ask "question" "default"  -> prints the answer
  local a
  printf '%s [%s]: ' "$1" "$2" >/dev/tty; tty_read a
  printf '%s' "${a:-$2}"
}
ask_yn() {     # ask_yn "question" y|n  -> exit status (no terminal = NO)
  local a hint="y/N"
  [[ $2 == y ]] && hint="Y/n"
  # check for a terminal first; don't silence read's stderr, it carries the prompt
  if ! { : </dev/tty; } 2>/dev/null; then echo "$1 -> no (no terminal)" >&2; return 1; fi
  printf '%s [%s] ' "$1" "$hint" >/dev/tty; tty_read a || { echo "$1 -> no (no input)" >&2; return 1; }
  a=${a:-$2}
  [[ $a == [yY]* ]]
}
choose() {     # choose "prompt" item...  -> CHOICE_I (0-based)
  local prompt=$1 i=1 item n
  shift
  for item in "$@"; do printf '  %2d) %s\n' "$i" "$item"; i=$((i + 1)); done
  while :; do
    printf '%s' "$prompt" >/dev/tty; tty_read n
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )); then CHOICE_I=$((n - 1)); return 0; fi
    echo "  enter a number from 1 to $#"
  done
}

choose_many() {  # choose_many "prompt" item...  -> CHOICES (0-based), e.g. "1 4" or "1,4"
  local prompt=$1 i=1 item n x ok
  shift
  for item in "$@"; do printf '  %2d) %s\n' "$i" "$item"; i=$((i + 1)); done
  while :; do
    printf '%s' "$prompt" >/dev/tty; tty_read n
    CHOICES=() ok=yes
    for x in ${n//,/ }; do
      if [[ $x =~ ^[0-9]+$ ]] && (( x >= 1 && x <= $# )); then CHOICES+=($((x - 1))); else ok=no; fi
    done
    if [[ $ok == yes ]] && (( ${#CHOICES[@]} )); then return 0; fi
    echo "  enter one or more numbers from 1 to $# (e.g. 1 or 1 3)"
  done
}

# -----------------------------------------------------------------------------
# search: executables and menu launchers whose name contains <q>
# (system folders + YOUR home only)
# -----------------------------------------------------------------------------
search_bins() {
  find -L /usr/bin /usr/sbin /usr/local/bin /usr/games /opt /usr/share /usr/lib /snap/bin \
       "$HOME/.local/bin" "$HOME/.local/share" "$HOME/Applications" "$HOME/bin" \
       "$HOME/.npm-global/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.deno/bin" \
       -maxdepth 3 -type f -perm /111 -iname "*$1*" 2>/dev/null \
    | grep -v -e '/ai-sandbox' -e '/\.ai-real-' -e '\.desktop$' | sort -u || true
}
search_desktop() {
  local f
  for f in /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop \
           "$APPS"/*.desktop; do
    [[ -f $f ]] || continue
    if grep -qx 'X-AI-Sandbox=true' "$f"; then continue; fi       # one of ours
    if grep -qiE "^(Name|Exec)=.*$1" "$f"; then echo "$f"; fi
  done
}

cmd_search() {
  local q=${1:-}
  [[ $q =~ ^[A-Za-z0-9._-]+$ ]] || die "usage: ai-sandbox-admin search <name>"
  echo "Programs:";       search_bins "$q"    | sed 's/^/  /'
  echo "Menu launchers:"; search_desktop "$q" | sed 's/^/  /'
}

# -----------------------------------------------------------------------------
# wrapping: <dir>/<tool> -> <dir>/<prefix><tool>  + a wrapper at <dir>/<tool>
#   tools.conf:  exec    = <dir>/<prefix><tool>   (the real program, renamed)
#                wrapped = <dir>/<tool>           (now the wrapper)
# -----------------------------------------------------------------------------
wrapper_text() {     # wrapper_text NAME PRE RUNNER [ORIG]  (ORIG = an extra program of the tool)
  local via=""
  [[ -z ${4:-} ]] || via="--via '$4' "
  cat <<EOF
#!/bin/sh
# ai-sandbox wrapper — runs '$1' sandboxed (made by ai-sandbox-admin).
# Real program: $2
# Undo: ai-sandbox-admin remove $1   (or: ai-sandbox-admin reset)
exec $3 run $via$1 "\$@"
EOF
}

# priv_for DIR MODE  ->  sets PRIV=() if DIR is writable, PRIV=(sudo) if not
# (never sudo in quiet mode: that runs at every shell start)
priv_for() {
  PRIV=()
  [[ -w $1 ]] && return 0
  if [[ $2 == quiet ]] || ! command -v sudo >/dev/null; then return 1; fi
  echo "note:       $1 is not writable by you, using sudo"
  sudo -v 2>/dev/null || return 1                       # password now, or give up cleanly
  PRIV=(sudo)
}

# wrap_original NAME ORIG PRE RUNNER MODE [extra]
#   MODE ask   = ask before the first rename (sync)
#        yes   = already confirmed (add)
#        quiet = only re-wrap something that was wrapped before (shell hook)
#   extra      = ORIG is not the tool's main program (its wrapper says --via ORIG)
wrap_original() {
  local name=$1 orig=$2 pre=$3 run=$4 mode=${5:-ask} want
  local -a PRIV=()
  if [[ ${6:-} == extra ]]; then want=$(wrapper_text "$name" "$pre" "$run" "$orig")
  else want=$(wrapper_text "$name" "$pre" "$run"); fi

  if is_wrapper "$orig" && [[ ! -e $pre && ! -L $pre ]]; then
    # the real program is gone: typically `apt remove` of a diverted package
    # (dpkg deletes the diverted file but knows nothing about our wrapper)
    warn "[$name] the real program $pre is gone (package removed?) — $orig is an orphan wrapper."
    warn "        clean up with:  ai-sandbox-admin remove $name"
    return 0
  fi
  if is_wrapper "$orig"; then
    [[ $(cat "$orig") != "$want" ]] || { [[ $mode == quiet ]] || echo "ok:         $orig"; return 0; }
  elif [[ -e $orig || -L $orig ]]; then
    if [[ -e $pre || -L $pre ]]; then
      echo "re-wrap:    $orig was replaced (update?)"
    elif [[ $mode == quiet ]]; then
      return 0                                           # never wrapped yet: sync/add decide
    elif [[ $mode == ask ]] && ! ask_yn "[$name] move $orig -> $pre and put a wrapper at $orig?" y; then
      warn "[$name] skipped: $orig still runs UNSANDBOXED"; return 0
    fi
  elif [[ ! -e $pre && ! -L $pre ]]; then
    [[ $mode == quiet ]] || warn "[$name] neither $orig nor $pre exists: nothing to wrap"
    return 0
  fi

  priv_for "$(dirname "$orig")" "$mode" \
    || { warn "[$name] can't write $(dirname "$orig"): run 'ai-sandbox-admin sync'"; return 0; }

  # Re-wrap after an update: the log already says "wrapper at $orig, real
  # program at $pre", and that is exactly what we restore. So this is NOT
  # logged as a change (undoing it would bring back the stale old version
  # and block undoing the install); only a note is logged. The old version
  # at $pre is obsolete (the update meant to replace it) and is dropped.
  local rewrap=no desc=$ACT_DESC
  if ! is_wrapper "$orig" && [[ -e $orig || -L $orig ]] && [[ -e $pre || -L $pre ]]; then
    rewrap=yes; ACT_DESC=""
  fi

  if ! is_wrapper "$orig" && [[ -e $orig || -L $orig ]]; then
    if [[ $rewrap == no && ! -L $orig ]] && pkg_owns "$orig" && command -v dpkg-divert >/dev/null; then
      # owned by a Debian package: dpkg moves it, and future upgrades of the
      # package install straight to $pre instead of over the wrapper
      act_divert "$orig" "$pre" \
        || { ACT_DESC=$desc; warn "[$name] dpkg-divert of $orig failed"; return 0; }
      echo "diverted:   $orig -> $pre (dpkg-divert: package upgrades go there)"
    else
      act_mv "$orig" "$pre" \
        || { ACT_DESC=$desc; warn "[$name] could not move $orig"; return 0; }   # a symlink is moved as a symlink
      echo "renamed:    $orig -> $pre"
    fi
  fi
  act_write "$orig" 755 <<<"$want" \
    || { ACT_DESC=$desc; warn "[$name] could not write the wrapper at $orig — real program is at $pre"; return 0; }
  ACT_DESC=$desc
  if [[ $rewrap == yes ]]; then _act_log note "re-wrapped $orig after an update; new real program at $pre"; fi
  echo "wrapper:    $orig  ->  $run run $name"
}

unwrap_original() {  # unwrap_original NAME ORIG PRE  -> put the real program back
  local name=$1 orig=$2 pre=$3
  local -a PRIV=()
  if is_wrapper "$orig"; then
    priv_for "$(dirname "$orig")" ask || { warn "[$name] can't write $(dirname "$orig")"; return 0; }
    if is_diverted "$orig"; then
      act_rm "$orig" && act_undivert "$orig" "$pre" \
        || { warn "[$name] could not undo the dpkg diversion of $orig"; return 0; }
      echo "restored:   $orig (dpkg diversion removed)"
    elif [[ -e $pre || -L $pre ]]; then
      act_mv "$pre" "$orig" || { warn "[$name] could not move $pre back"; return 0; }
      echo "restored:   $orig"
    else
      act_rm "$orig" || { warn "[$name] could not remove $orig"; return 0; }
      warn "[$name] $pre is missing; removed the wrapper only"
    fi
  elif [[ -e $pre || -L $pre ]]; then
    warn "[$name] $orig is not our wrapper (an update replaced it?); left as is. Old copy: $pre"
  fi
}

# follow_newest NAME PRE GLOB MODE — exec-newest: point the renamed real
# program at the newest version (an updater may only have added a new
# version to versions/). Not logged as a change, for the same reason as a
# re-wrap: undoing the install should leave the NEWEST version in place.
follow_newest() {
  local name=$1 pre=$2 n desc
  local -a PRIV=()
  [[ -L $pre ]] && n=$(newest_of "$3") || return 0
  [[ $(readlink -f -- "$pre") != "$(readlink -f -- "$n")" ]] || return 0
  priv_for "$(dirname "$pre")" "$4" || return 0
  desc=$ACT_DESC; ACT_DESC=""
  "${PRIV[@]}" ln -sfn -- "$n" "$pre"
  ACT_DESC=$desc
  _act_log note "pointed $pre at the newest version $n"
  echo "newer:      $pre -> $n"
}

# for_wrapped CALLBACK  ->  CALLBACK NAME ORIG PRE [extra]  for every `wrapped =`
# of every tool (the main program first, then its extra programs)
for_wrapped() {
  local name i
  for name in $(conf_tools "$TOOLS"); do
    conf_load "$TOOLS" "$name" || continue
    for i in "${!T_WRAPS[@]}"; do
      if (( i == 0 )); then "$1" "$name" "${T_WRAPS[i]}" "${T_EXECS[i]}"
      else "$1" "$name" "${T_WRAPS[i]}" "${T_EXECS[i]}" extra; fi
    done
  done
}

# remove what the old PATH-wrapper design generated (bin dir + menu launchers)
legacy_cleanup() {
  local f b
  if [[ -d $OLD_WRAP ]]; then act_rm "$OLD_WRAP"; echo "removed:    $OLD_WRAP (old PATH wrappers)"; fi
  for f in "$APPS"/*.desktop; do
    [[ -f $f ]] && grep -qx 'X-AI-Sandbox=true' "$f" || continue
    act_rm "$f"; echo "removed:    $f (old sandboxed launcher)"
    b="$OLD_DBACK/$(basename "$f")"
    if [[ -f $b ]]; then act_mv "$b" "$f"; echo "restored:   $f"; fi
  done
  if [[ -d $OLD_DBACK && -z $(ls -A "$OLD_DBACK") ]]; then act_rm "$OLD_DBACK"; fi
  update-desktop-database "$APPS" 2>/dev/null || true
}

cmd_verify() {       # quick check, run by shell-hook.sh at every shell start
  local quiet=${1:-} run
  if (( EUID == 0 )); then [[ $quiet == -q ]] && return 0; need_user; fi
  [[ -f $TOOLS ]] || return 0
  run=$(runner) || return 0
  local mode=ask; [[ $quiet == -q ]] && mode=quiet
  _verify_one() {
    wrap_original "$1" "$2" "$3" "$run" "$mode" "${4:-}"
    if [[ -n $T_EXECNEWEST && -z ${4:-} ]]; then follow_newest "$1" "$3" "$T_EXECNEWEST" "$mode"; fi
  }
  for_wrapped _verify_one
}

cmd_sync() {
  need_user
  local run name i
  run=$(runner) || die "not installed yet: run 'ai-sandbox-admin install' (as root preferred)"
  ensure_conf "$CONF" "$(installed_lib)"
  legacy_cleanup

  for name in $(conf_tools "$TOOLS"); do
    [[ $name != shell ]] || { warn "'shell' is reserved, skipped"; continue; }
    conf_load "$TOOLS" "$name" || die "fix [$name] in $TOOLS"
    if [[ -z $T_WRAPPED ]]; then
      warn "[$name] has no 'wrapped =' line, so nothing starts it sandboxed."
      warn "        set  exec = <dir>/.ai-real-<x>  +  wrapped = <dir>/<x>  (or: remove + add)"
      continue
    fi
    if (( ${#T_DESKTOP[@]} )); then
      warn "[$name] 'desktop =' is ignored now: launchers run $T_WRAPPED, which is the wrapper"
    fi
    wrap_original "$name" "$T_WRAPPED" "$T_EXEC" "$run" ask
    for i in "${!T_WRAPS[@]}"; do
      (( i == 0 )) || wrap_original "$name" "${T_WRAPS[i]}" "${T_EXECS[i]}" "$run" ask extra
    done
    if [[ -n $T_EXECNEWEST ]]; then follow_newest "$name" "$T_EXEC" "$T_EXECNEWEST" ask; fi
  done
}

cmd_reset() {
  need_user
  for_wrapped unwrap_original
  legacy_cleanup
  echo "Every real program is back in place (config kept in $CONF)."
}

# -----------------------------------------------------------------------------
# install / uninstall
# -----------------------------------------------------------------------------
add_hook() {         # add_hook RCFILE HOOKFILE
  [[ -f $1 ]] || return 0
  if ! grep -qF "$MARK" "$1"; then
    act_hook "$1" "$MARK" "[ -r $2 ] && . $2"
  fi
  echo "shell hook: $1"
}
# unhook RCFILE MARK -> the file without our block (MARK, the line after it,
# and the blank line add_hook put before it)
unhook() {
  awk -v m="$2" '{ L[NR] = $0 } END {
      for (i = 1; i <= NR; i++)
        if (L[i] == m) { if (i > 1 && L[i-1] == "") D[i-1] = 1; D[i] = 1; D[i+1] = 1; i++ }
      for (i = 1; i <= NR; i++) if (!(i in D)) print L[i]
    }' "$1"
}
remove_hook() {
  [[ -f $1 ]] && grep -qF "$MARK" "$1" || return 0
  act_write "$1" keep < <(unhook "$1" "$MARK")
  echo "cleaned:    $1"
}

# sets BIN LIBDIR RCS for the current mode
pick_mode() {
  if (( EUID == 0 )); then
    BIN=$SYS_BIN LIBDIR=$SYS_LIB RCS=(/etc/zsh/zshrc /etc/bash.bashrc)
  else
    BIN=$USR_BIN LIBDIR=$USR_LIB RCS=("$HOME/.zshrc" "$HOME/.bashrc")
  fi
}

cmd_install() {
  [[ -f $SRC/ai-sandbox.sh ]] || die "run install from the source folder (bash install.sh)"
  command -v bwrap >/dev/null || die "install bubblewrap first (as root: apt install bubblewrap)"
  local f rc
  pick_mode

  if (( EUID == 0 )); then
    echo "System install: programs root-owned in /usr/local (preferred)."
    if [[ -n ${SUDO_USER:-} ]]; then warn "sudo works, but a real root login (su -) is preferred"; fi
  else
    [[ ! -x $SYS_BIN/ai-sandbox ]] || die "root already installed it system-wide; just run: ai-sandbox-admin sync"
    warn "user install into ~/.local. It works, but a ROOT install is preferred"
    warn "(su -, then bash install.sh): the programs are then root-owned and"
    warn "nothing running as you can modify them."
  fi

  # FIRST, before any change: the undo tool next to the log. If this install
  # stops anywhere, `<state>/ai-sandbox-undo all` reverses what it did. It
  # stays there after an uninstall too (and does the final `purge`).
  _act_init
  install -m 755 "$SRC/undo.sh" "$(act_state_dir)/ai-sandbox-undo"
  echo "undo:       $(act_state_dir)/ai-sandbox-undo all    (reverses this install, even if it stops half-way)"

  act_mkdir "$BIN" 755
  act_mkdir "$LIBDIR" 755
  act_install "$SRC/ai-sandbox.sh"       "$BIN/ai-sandbox"       755
  act_install "$SRC/ai-sandbox-admin.sh" "$BIN/ai-sandbox-admin" 755
  act_install "$SRC/undo.sh"             "$BIN/ai-sandbox-undo"  755
  for f in lib.sh check.sh shell-hook.sh tools.conf policy.conf; do
    act_install "$SRC/$f" "$LIBDIR/$f" 644        # tools/policy.conf = defaults for new users
  done
  echo "programs:   $BIN/ai-sandbox, $BIN/ai-sandbox-admin, $BIN/ai-sandbox-undo, $LIBDIR/"

  # aisup (optional)
  if [[ -f /usr/include/seccomp.h ]] && command -v cc >/dev/null; then
    # built next to its place, as a logged temp file: a stop leaves nothing unknown
    local b=$LIBDIR/.aisup-build.ai-sandbox-tmp
    [[ -e $b ]] || _act_log tmp "$b"
    if cc -O2 -Wall -o "$b" "$SRC/aisup.c" -lseccomp && act_install "$b" "$LIBDIR/aisup" 755; then
      echo "built:      $LIBDIR/aisup"
    else
      warn "aisup build failed — tools with aisup=yes will refuse to start"
    fi
    rm -f "$b"
  else
    warn "aisup not built (apt install libseccomp-dev gcc, then install again) — tools with aisup=yes will refuse to start"
  fi

  for rc in "${RCS[@]}"; do add_hook "$rc" "$LIBDIR/shell-hook.sh"; done

  echo
  if (( EUID == 0 )); then
    echo "Done. Each user now runs once, as themselves:   ai-sandbox-admin sync"
    echo "(that creates ~/.config/ai-sandbox/ and wraps their tools)."
  else
    cmd_sync
    echo "Done."
  fi
}

cmd_uninstall() {
  local rc
  pick_mode
  if (( EUID == 0 )); then
    echo "Removing the system install. Users should first run:  ai-sandbox-admin reset"
    echo "(otherwise their wrapped tools point to a missing ai-sandbox and won't start)."
    ask_yn "Continue?" n || return 0
  else
    [[ -x $USR_BIN/ai-sandbox ]] || [[ ! -x $SYS_BIN/ai-sandbox ]] \
      || die "this is a system install: root removes it. To stop using it yourself: ai-sandbox-admin reset"
    for_wrapped unwrap_original
    legacy_cleanup
    act_rm "$DATA/ai-sandbox"
  fi

  for rc in "${RCS[@]}"; do remove_hook "$rc"; done
  act_rm "$LIBDIR"
  act_rm "$BIN/ai-sandbox"
  act_rm "$BIN/ai-sandbox-undo"

  if (( EUID != 0 )); then
    if ask_yn "Also delete your config in $CONF?" n; then act_rm "$CONF"; else echo "kept:       $CONF"; fi
  fi
  act_rm "$BIN/ai-sandbox-admin"
  echo "Uninstalled. The tools' own data (~/.claude, ~/.config/Cursor, ...) is untouched."
  echo "Changed your mind?  $(act_state_dir)/ai-sandbox-undo last"
}

# -----------------------------------------------------------------------------
# add: interactive
# -----------------------------------------------------------------------------
cmd_add() {
  need_user
  runner >/dev/null || die "not installed yet: run 'ai-sandbox-admin install' (as root preferred)"
  ensure_conf "$CONF" "$(installed_lib)"
  local q=${1:-}
  if [[ -z $q ]]; then printf 'AI tool to search for (e.g. claude, cursor, aider): ' >/dev/tty; tty_read q; fi
  [[ $q =~ ^[A-Za-z0-9._-]+$ ]] || die "use letters, digits, . _ - only"

  # --- 1. find the program(s) -----------------------------------------------
  # One tool can have several programs (e.g. a CLI script + the app binary):
  # pick them all; the FIRST one is the main program.
  echo "Searching for '$q' ..."
  local -a bins=() labels=() apps=() picks=() exes=() reals=()
  local b real i x
  mapfile -t bins < <(search_bins "$q")
  mapfile -t apps < <(search_desktop "$q")
  for b in "${bins[@]}"; do
    real=$(readlink -f "$b")
    if [[ $real != "$b" ]]; then labels+=("$b  ->  $real"); else labels+=("$b"); fi
  done
  labels+=("type a path by hand" "cancel")
  echo
  choose_many "Which program(s) belong to the AI tool? (one or more, e.g. 1 or 1 3; main one first) " "${labels[@]}"

  for i in "${CHOICES[@]}"; do
    if   (( i <  ${#bins[@]} )); then picks+=("${bins[i]}")
    elif (( i == ${#bins[@]} )); then
      printf 'Full path(s), separated by spaces: ' >/dev/tty; tty_read x
      read -ra x <<<"$x"; picks+=("${x[@]}")
    else echo "cancelled"; return 0
    fi
  done

  # check each one; two picks that are the SAME program (a symlink and its
  # target) are wrapped once: the target. Wrapping both would make the moved
  # symlink point at a wrapper (a sandbox inside a sandbox).
  local exe r j dup
  for exe in "${picks[@]}"; do
    exe=$(expand_home "$exe")
    [[ -f $exe && -x $exe ]] || die "'$exe' is not an executable file"
    [[ $exe != *"'"* ]] || die "'$exe': paths with a quote are not supported"
    ! is_wrapper "$exe" || die "'$exe' is already an ai-sandbox wrapper"
    r=$(readlink -f "$exe")
    ! is_wrapper "$r" || die "'$exe' leads to $r, which is already an ai-sandbox wrapper"
    dup=-1
    for j in "${!reals[@]}"; do if [[ ${reals[j]} == "$r" ]]; then dup=$j; fi; done
    if (( dup < 0 )); then exes+=("$exe"); reals+=("$r"); continue; fi
    if [[ ${exes[dup]} == "$exe" ]]; then continue; fi              # picked twice
    if [[ $exe == "$r" ]]; then                                     # keep the real file
      echo "note:       ${exes[dup]} is a symlink to $exe: wrapping $exe covers both"
      exes[dup]=$exe
    else
      echo "note:       $exe is a symlink to $r: wrapping ${exes[dup]} covers both"
    fi
  done
  exe=${exes[0]} real=${reals[0]}
  local appdir; appdir=$(dirname "$real")
  local electron=no
  for r in "${reals[@]}"; do [[ ! -e $(dirname "$r")/resources/app.asar ]] || electron=yes; done

  # --- 2. name + type + project ---------------------------------------------
  local def name type guess=cli proj_def=cwd project
  def=$(basename "$exe" | tr 'A-Z' 'a-z' | sed 's/\.appimage$//; s/[^a-z0-9_-]/-/g')
  name=$(ask "Profile name (its [section] in tools.conf)" "$def")
  [[ $name =~ ^[A-Za-z0-9_-]+$ && $name != shell ]] || die "bad name '$name'"
  if conf_tools "$TOOLS" | grep -qx -- "$name"; then die "'$name' already exists (remove it first)"; fi

  if (( ${#apps[@]} )) || [[ $electron == yes ]]; then guess=gui; fi
  type=$(ask "Type: cli (terminal) or gui (window)" "$guess")
  [[ $type == cli || $type == gui ]] || die "type must be cli or gui"

  if [[ $type == gui ]]; then proj_def="~/Workspace"; fi
  project=$(ask "Folder it may write (cwd = where it is started)" "$proj_def")

  # --- 2b. the rename ------------------------------------------------------
  # Each real program is moved aside and a wrapper takes its place, so EVERY
  # caller (shell, menu launcher, IDE, script, absolute path) is sandboxed.
  local prefix d
  local -a pres=()
  echo
  if (( ${#exes[@]} == 1 )); then
    echo "$exe will become a small wrapper that runs:  ai-sandbox run $name ..."
    echo "and the real program is moved next to it under a prefix."
  else
    echo "These ${#exes[@]} programs will become small wrappers that run:  ai-sandbox run $name ..."
    printf '  %s\n' "${exes[@]}"
    echo "and each real program is moved next to its wrapper under a prefix."
  fi
  prefix=$(ask "Prefix for the real program" ".ai-real-")
  [[ $prefix =~ ^[A-Za-z0-9._-]+$ ]] || die "bad prefix '$prefix'"
  for x in "${exes[@]}"; do
    d=$(dirname "$x")
    pres+=("$d/$prefix$(basename "$x")")
    [[ ! -e ${pres[-1]} && ! -L ${pres[-1]} ]] || die "${pres[-1]} already exists"
    if [[ ! -w $d ]]; then
      echo "Note: $d is not writable by you: the rename will use sudo."
      command -v sudo >/dev/null || die "sudo is not installed; ask root to make $d writable or run this as a user who can"
    fi
  done
  for i in "${!exes[@]}"; do echo "  ${exes[i]}  ->  ${pres[i]}"; done
  ask_yn "Move these and put the wrappers in their place?" y || { echo "cancelled"; return 0; }

  # --- 3. its own config / state in your home -------------------------------
  local -a ro=() rw=() rwfile=()
  local c rel ans
  echo
  echo "Things in your home that look like '$q' (its config/state):"
  while IFS= read -r c; do
    rel=$(tildify "$c")
    if [[ -d $c ]]; then
      ans=$(ask "  $rel/   w=read-write r=read-only n=skip" w)
      case $ans in w*) rw+=("$rel") ;; r*) ro+=("$rel") ;; esac
    else
      ans=$(ask "  $rel   w=read-write n=skip" w)
      case $ans in w*) rwfile+=("$rel") ;; esac
    fi
  done < <(find "$HOME" "$HOME/.config" "$HOME/.local/share" "$HOME/.cache" \
                -mindepth 1 -maxdepth 1 -iname "*$q*" ! -name 'ai-sandbox*' 2>/dev/null | sort)

  # program installed inside your home: its folder must be visible (read-only).
  # - an npm package needs its WHOLE package folder (vendor/, node_modules/),
  #   not just the bin/ folder its entry script sits in
  # - a versions/ folder (Claude Code style): new versions land there and the
  #   launcher is left alone, so also run the newest one (exec-newest)
  local newest=""
  if [[ $(basename "$appdir") == versions ]]; then newest="$(tildify "$appdir")/*"; fi
  local appdir_t covered p progdir
  for r in "${reals[@]}"; do
    [[ $r == "$HOME"/* ]] || continue
    covered=no progdir=$(dirname "$r")
    if [[ $r =~ ^(.*/node_modules/(@[^/]+/)?[^/]+)/ ]]; then progdir=${BASH_REMATCH[1]}; fi
    appdir_t=$(tildify "$progdir")
    for p in "${ro[@]}" "${rw[@]}"; do
      if [[ $appdir_t == "$p" || $appdir_t == "$p"/* ]]; then covered=yes; fi
    done
    if [[ $covered == no ]] && ask_yn "Give read-only access to the program folder $appdir_t ?" y; then
      ro+=("$appdir_t")
    fi
  done

  # --- 4. args, env, aisup ---------------------------------------------------
  # (menu launchers need nothing: they start the wrapped paths)

  local args_def="-" args envs aisup=no
  local -a allow=()
  if [[ $electron == yes ]]; then                         # Electron app
    args_def="--ozone-platform=wayland --password-store=basic"
  fi
  args=$(ask "Extra program arguments ('-' = none)" "$args_def")
  envs=$(ask "Env variables to pass in, e.g. API keys ('-' = none)" "-")
  if ask_yn "Ask before it runs unknown programs (aisup)?" n; then aisup=yes; fi
  if [[ $type == gui ]]; then                              # app's own helpers
    for r in "${reals[@]}"; do
      [[ $r != "$HOME"/* ]] || continue
      d="$(dirname "$r")/*"
      [[ " ${allow[*]} " == *" $d "* ]] || allow+=("$d")
    done
  fi

  # --- 5. show, confirm, save ------------------------------------------------
  local section
  section=$(
    printf '\n[%s]\n' "$name"
    printf '# added by ai-sandbox-admin on %s\n' "$(date +%F)"
    for i in "${!exes[@]}"; do
      if (( i == 1 )); then printf '# more programs of this tool (exec/wrapped pairs, in order)\n'; fi
      printf 'exec = %s\n'    "$(tildify "${pres[i]}")"   # the real program, renamed
      printf 'wrapped = %s\n' "$(tildify "${exes[i]}")"   # the original path, now the wrapper
    done
    [[ -z $newest ]] || printf 'exec-newest = %s\n' "$newest"   # always run the newest version
    printf 'type = %s\n' "$type"
    printf 'project = %s\n' "$project"
    for x in "${rw[@]}";     do printf 'rw = %s\n' "$x"; done
    for x in "${rwfile[@]}"; do printf 'rw-file = %s\n' "$x"; done
    for x in "${ro[@]}";     do printf 'ro = %s\n' "$x"; done
    [[ $args == - ]] || printf 'args = %s\n' "$args"
    [[ $envs == - ]] || printf 'env-pass = %s\n' "$envs"
    for x in "${allow[@]}";  do printf 'exec-allow = %s\n' "$x"; done
    printf 'aisup = %s\n' "$aisup"
  )
  echo
  echo "This will be added to $TOOLS:"
  echo "$section"
  echo
  # same checks as at every start (incl. "a tool may only see its own data dir")
  local tmp; tmp=$(mktemp)
  { cat "$TOOLS"; printf '%s\n' "$section"; } > "$tmp"
  if ! conf_load "$tmp" "$name"; then rm -f "$tmp"; die "[$name] refused (see above) — nothing saved"; fi
  rm -f "$tmp"
  ask_yn "Save?" y || { echo "nothing saved"; return 0; }
  act_write "$TOOLS" keep < <(cat "$TOOLS"; printf '%s\n' "$section")
  for i in "${!exes[@]}"; do
    if (( i == 0 )); then wrap_original "$name" "${exes[i]}" "${pres[i]}" "$(runner)" yes
    else wrap_original "$name" "${exes[i]}" "${pres[i]}" "$(runner)" yes extra; fi
  done
  echo "Done. ${exes[*]} now start(s) sandboxed, from anywhere."
}

cmd_remove() {
  need_user
  local name=${1:-}
  if [[ -z $name ]]; then list_tools "$TOOLS"; printf 'Tool to remove: ' >/dev/tty; tty_read name; fi
  conf_tools "$TOOLS" | grep -qx -- "$name" || die "'$name' is not configured"
  # rename mode: put the real program back first
  conf_load "$TOOLS" "$name" || true
  local i
  for i in "${!T_WRAPS[@]}"; do unwrap_original "$name" "${T_WRAPS[i]}" "${T_EXECS[i]}"; done
  # keep every line except those from "[name]" up to the next "[section]"
  act_write "$TOOLS" keep < <(awk -v sec="[$name]" '
    { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
    t ~ /^\[.*\]$/ { skip = (t == sec) }
    !skip
  ' "$TOOLS")
  echo "removed [$name] (undo: ai-sandbox-undo last)"
  echo "Its data is untouched; '$name' now runs unsandboxed again."
}

# -----------------------------------------------------------------------------
act_begin "ai-sandbox-admin $*"
case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  search)    shift; cmd_search "${1:-}" ;;
  add)       shift; cmd_add "${1:-}" ;;
  remove)    shift; cmd_remove "${1:-}" ;;
  list)      list_tools "$TOOLS" ;;
  sync)      cmd_sync ;;
  verify)    shift; cmd_verify "${1:-}" ;;
  reset)     cmd_reset ;;
  *) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
