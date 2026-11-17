# lib.sh — shared helpers for ai-sandbox and ai-sandbox-admin.
# This file is SOURCED by both scripts, never run on its own.

die()  { echo "ai-sandbox: $*" >&2; exit 1; }
warn() { echo "ai-sandbox: warning: $*" >&2; }

# Remove spaces at both ends.
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# "~/x" -> "$HOME/x"  (HOME of whoever runs the tool)
expand_home() {
  local v=$1
  if   [[ $v == "~" ]];    then v=$HOME
  elif [[ $v == "~/"* ]];  then v="$HOME/${v:2}"
  fi
  printf '%s' "$v"
}

# "/home/<user>/x" -> "~/x"  so one config line works for every user
tildify() {
  if   [[ $1 =~ ^/home/[^/]+/(.*)$ ]]; then printf '~/%s' "${BASH_REMATCH[1]}"
  elif [[ $1 =~ ^/root/(.*)$ ]];       then printf '~/%s' "${BASH_REMATCH[1]}"
  else printf '%s' "$1"
  fi
}

# conf_tools FILE  ->  prints every [section] name, one per line
conf_tools() {
  sed -n 's/^[[:space:]]*\[\([A-Za-z0-9_-]*\)\][[:space:]]*$/\1/p' "$1"
}

# conf_load FILE NAME  ->  fills the T_* variables from section [NAME]
#   returns 0 = found, 1 = no such section, 2 = syntax error
conf_load() {
  local file=$1 want=$2 line key val section="" found=1
  local -a words

  # defaults
  # exec/wrapped may repeat (several programs of one tool), paired in order:
  # T_EXECS[i] is the real program behind the wrapper at T_WRAPS[i].
  # T_EXEC/T_WRAPPED = the first pair (the main program).
  T_EXEC="" T_TYPE=cli T_PROJECT=cwd T_AISUP=no T_WRAPPED="" T_EXECNEWEST=""
  T_EXECS=() T_WRAPS=() T_ARGS=() T_RO=() T_RW=() T_RWFILE=() T_ENVSET=() T_ENVPASS=() T_EXECALLOW=() T_DESKTOP=()

  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "${line%%#*}")                     # drop comments + spaces
    [[ -z $line ]] && continue

    if [[ $line =~ ^\[([A-Za-z0-9_-]+)\]$ ]]; then  # [section]
      section=${BASH_REMATCH[1]}
      if [[ $section == "$want" ]]; then found=0; fi
      continue
    fi
    [[ $section == "$want" ]] || continue

    if [[ $line != *=* ]]; then echo "tools.conf [$want]: bad line: $line" >&2; return 2; fi
    key=$(trim "${line%%=*}")
    val=$(expand_home "$(trim "${line#*=}")")

    case $key in
      exec)       T_EXECS+=("$val"); [[ -n $T_EXEC ]] || T_EXEC=$val ;;
      type)       T_TYPE=$val ;;
      project)    T_PROJECT=$val ;;
      aisup)      T_AISUP=$val ;;
      wrapped)    T_WRAPS+=("$val"); [[ -n $T_WRAPPED ]] || T_WRAPPED=$val ;;
      exec-newest) T_EXECNEWEST=$val ;;
      args)       read -ra words <<<"$val"; T_ARGS+=("${words[@]}") ;;
      env-pass)   read -ra words <<<"$val"; T_ENVPASS+=("${words[@]}") ;;
      ro)         T_RO+=("$val") ;;
      rw)         T_RW+=("$val") ;;
      rw-file)    T_RWFILE+=("$val") ;;
      env-set)    T_ENVSET+=("$val") ;;
      exec-allow) T_EXECALLOW+=("$val") ;;
      desktop)    T_DESKTOP+=("$val") ;;
      *) echo "tools.conf [$want]: unknown key '$key'" >&2; return 2 ;;
    esac
  done < "$file"
  if (( found == 0 && (${#T_EXECS[@]} > 1 || ${#T_WRAPS[@]} > 1) && ${#T_EXECS[@]} != ${#T_WRAPS[@]} )); then
    echo "tools.conf [$want]: ${#T_EXECS[@]} 'exec' but ${#T_WRAPS[@]} 'wrapped' lines — each wrapped program needs its own exec" >&2
    return 2
  fi
  if (( found == 0 )); then conf_check_isolation "$file" "$want" || return 2; fi
  return $found
}

# =============================================================================
# Secrets that are never exposed inside the sandbox, whatever tools.conf says.
# Used by the launcher (refuses) and by `ai-sandbox-admin add` (hints).
#   <lib>/secrets.list            the built-in list (data, not code), installed
#                                 root-owned 644 next to lib.sh
#   /etc/ai-sandbox/secrets.conf  admin additions/exceptions (root-owned;
#                                 created empty by a root install)
#   ~/.config/ai-sandbox/secrets.conf  your own additions (created by sync):
#                                 root install: 'deny' only (it is yours, so
#                                 it may only ADD secrets); user install:
#                                 'deny' and 'allow'
# All are only trusted if safe: see secrets_file_safe. FAIL CLOSED: if the
# list is missing, unsafe, empty or has a line we don't understand, nothing
# starts (a missing list must never mean "no secrets").
# =============================================================================
SECRETS_ROOT_LIB=/usr/local/lib/ai-sandbox
SECRETS_CONF=/etc/ai-sandbox/secrets.conf
SECRETS_USER_CONF=${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/secrets.conf

# secrets_file_safe FILE STRICT  ->  prints why FILE can't be trusted (exit 1),
# or nothing (exit 0). Safe = a regular file (after resolving symlinks), owned
# by root (STRICT=yes) or by root/you (STRICT=no), not group/world-writable,
# and so is every folder above it (a sticky root-owned folder like /tmp is ok).
secrets_file_safe() {
  local f d owner mode ok_owner
  f=$(readlink -f -- "$1" 2>/dev/null) || { echo "$1: cannot resolve"; return 1; }
  [[ -f $f ]] || { echo "$1: missing or not a regular file"; return 1; }
  d=$f
  while :; do
    read -r owner mode < <(stat -c '%u %a' -- "$d") || { echo "$d: cannot stat"; return 1; }
    ok_owner=no
    if (( owner == 0 )); then ok_owner=yes
    elif [[ $2 == no ]] && (( owner == EUID )); then ok_owner=yes; fi
    [[ $ok_owner == yes ]] || { echo "$d is owned by uid $owner, not root"; return 1; }
    if (( (8#$mode & 8#022) != 0 )); then
      if [[ -d $d ]] && (( (8#$mode & 8#1000) != 0 && owner == 0 )); then :   # sticky root dir
      else echo "$d is writable by group/others (mode $mode)"; return 1; fi
    fi
    [[ $d == / ]] && break
    d=$(dirname -- "$d")
  done
  return 0
}

# secrets_parse FILE WORDS  ->  applies "deny PATH" / "allow PATH" lines of
# FILE to SECRETS. WORDS = the words FILE may use ("deny" or "deny allow").
# Any other line is an error (exit 1, message on stderr).
secrets_parse() {
  local file=$1 words=" $2 " n=0 line verb path s
  local -a keep
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=$(trim "${line%%#*}")
    [[ -n $line ]] || continue
    verb=${line%%[[:space:]]*}
    path=$(trim "${line#"$verb"}")
    if [[ $words != *" $verb "* || -z $path ]]; then
      echo "ai-sandbox: $file line $n: not understood: '$line' (use:${words% })" >&2; return 1
    fi
    path=$(expand_home "$path")
    [[ $path == /* ]] || { echo "ai-sandbox: $file line $n: '$path' is not a full path (use ~/... or /...)" >&2; return 1; }
    case $verb in
      deny)  SECRETS+=("$path") ;;
      allow) keep=(); for s in "${SECRETS[@]}"; do [[ $s == "$path" ]] || keep+=("$s"); done
             SECRETS=("${keep[@]}") ;;
    esac
  done < "$file"
}

# secrets_load LIBDIR  ->  fills SECRETS (global array), or dies.
# STRICT (only root may own the files) for a root install; a user install or
# the source folder may also be owned by you (and so is NOT protected).
secrets_load() {
  local lib=$1 strict=no why
  [[ $(readlink -m -- "$lib") == "$SECRETS_ROOT_LIB" ]] && strict=yes
  SECRETS=()
  why=$(secrets_file_safe "$lib/secrets.list" "$strict") \
    || die "refusing to start: the secrets list can't be trusted: $why (reinstall: bash install.sh)"
  secrets_parse "$lib/secrets.list" deny || die "refusing to start: fix $lib/secrets.list"
  (( ${#SECRETS[@]} )) || die "refusing to start: $lib/secrets.list has no 'deny' lines"
  # yours first, the admin's last: /etc has the final word
  if [[ -e $SECRETS_USER_CONF || -L $SECRETS_USER_CONF ]]; then
    why=$(secrets_file_safe "$SECRETS_USER_CONF" no) \
      || die "refusing to start: $SECRETS_USER_CONF can't be trusted: $why (chmod 600 it)"
    if [[ $strict == yes ]]; then
      secrets_parse "$SECRETS_USER_CONF" deny \
        || die "refusing to start: fix $SECRETS_USER_CONF (root install: it may only add 'deny' lines; exceptions go in $SECRETS_CONF)"
    else
      secrets_parse "$SECRETS_USER_CONF" "deny allow" || die "refusing to start: fix $SECRETS_USER_CONF"
    fi
  fi
  if [[ -e $SECRETS_CONF || -L $SECRETS_CONF ]]; then
    why=$(secrets_file_safe "$SECRETS_CONF" yes) \
      || die "refusing to start: $SECRETS_CONF can't be trusted: $why (it must be root-owned, not group/world-writable)"
    secrets_parse "$SECRETS_CONF" "deny allow" || die "refusing to start: fix $SECRETS_CONF"
  fi
  return 0
}

# secrets_conf_template etc|user-root|user  ->  the commented starting text of
# a secrets.conf (no rules: an untouched template changes nothing)
secrets_conf_template() {
  local words="deny PATH | allow PATH"
  [[ $1 == user-root ]] && words="deny PATH"
  printf '%s\n' \
    "# secrets.conf — your own additions to the built-in secrets list" \
    "# (<lib>/secrets.list, replaced on every reinstall; this file never is)." \
    "# Paths here are NEVER visible inside the sandbox, whatever tools.conf says." \
    "#" \
    "# One rule per line:  $words      (~ = the home of whoever runs the tool)" \
    "#   deny ~/.config/mytool     hide this too"
  case $1 in
    etc)  printf '%s\n' "#   allow ~/.pki              un-hide a built-in entry (exact path only)" \
            "#" "# Must stay root-owned and not group/world-writable, or NO tool starts." ;;
    user) printf '%s\n' "#   allow ~/.pki              un-hide a built-in entry (exact path only)" \
            "#" "# User install: this file is yours, so anything running as you can edit it." ;;
    user-root) printf '%s\n' "#" "# Root install: this file is yours, so it may only ADD secrets ('deny')." \
            "# To un-hide a built-in entry, ask root to put 'allow PATH' in $SECRETS_CONF." ;;
  esac
  printf '%s\n' "# If this file has a line it doesn't understand, NO tool starts." ""
}

# ensure_secrets_conf FILE KIND MODE  ->  creates FILE from the template if it
# doesn't exist yet (never overwrites: it is yours)
ensure_secrets_conf() {
  [[ -e $1 || -L $1 ]] && return 0
  secrets_conf_template "$2" | act_write "$1" "$3" || return 1
  echo "created:    $1" >&2
}

touches_secret() {     # touches_secret PATH -> prints the secret it would expose
  local w s
  w=$(readlink -m -- "$1")
  for s in "${SECRETS[@]}"; do
    if [[ $w == "$s" || $w == "$s"/* || $s == "$w"/* ]]; then echo "$s"; return 0; fi
  done
  return 1
}

# conf_data_paths FILE  ->  "section<TAB>path" for every rw, rw-file and ro
# line: the data dirs each tool owns
conf_data_paths() {
  local line key section=""
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "${line%%#*}")
    [[ -z $line ]] && continue
    if [[ $line =~ ^\[([A-Za-z0-9_-]+)\]$ ]]; then section=${BASH_REMATCH[1]}; continue; fi
    [[ -n $section && $line == *=* ]] || continue
    key=$(trim "${line%%=*}")
    case $key in
      rw|rw-file|ro) printf '%s\t%s\n' "$section" "$(expand_home "$(trim "${line#*=}")")" ;;
    esac
  done < "$1"
}

# conf_check_isolation FILE NAME  ->  AI tool data is isolated per tool: a tool
# may only see its own data dir. Refuses if any rw, rw-file, ro or fixed
# project of [NAME] is, contains or sits inside a path another tool lists as
# rw, rw-file or ro (e.g. [claude] rw = ~/.copilot). Symlinks are resolved
# first. No exception list: neither `ai-sandbox-admin add` nor secrets.conf
# can turn this off. Uses the T_* variables conf_load just filled.
conf_check_isolation() {
  local file=$1 want=$2 w rw owner path rp
  local -a mine=("${T_RW[@]}" "${T_RWFILE[@]}" "${T_RO[@]}")
  if [[ -n $T_PROJECT && $T_PROJECT != cwd ]]; then mine+=("$T_PROJECT"); fi
  while IFS=$'\t' read -r owner path; do
    [[ $owner == "$want" ]] && continue
    rp=$(readlink -m -- "$path")
    for w in "${mine[@]}"; do
      rw=$(readlink -m -- "$w")
      if [[ $rw == "$rp" || $rw == "$rp"/* || $rp == "$rw"/* ]]; then
        echo "tools.conf [$want]: '$w' would expose the data of [$owner] ($path) — refusing; a tool may only see its own data dir" >&2
        return 1
      fi
    done
  done < <(conf_data_paths "$file")
  return 0
}

# is_wrapper FILE  ->  true if FILE is a wrapper script written by ai-sandbox-admin
# (reads only the first 256 bytes, so it is cheap even on big binaries)
is_wrapper() {
  [[ -f $1 && ! -L $1 ]] || return 1
  local head
  head=$(head -c 256 "$1" 2>/dev/null | tr -d '\0')
  [[ $head == *"# ai-sandbox wrapper"* ]]
}

# ensure_conf CONF_DIR DEFAULTS_DIR  ->  create the user's config from the
# defaults the first time (private: only the user can read/write it)
ensure_conf() {
  local conf=$1 defs=$2 f
  act_mkdir "$conf" 700
  for f in tools.conf policy.conf; do
    if [[ ! -f $conf/$f ]]; then
      [[ -f $defs/$f ]] || die "default $f not found in $defs"
      act_install "$defs/$f" "$conf/$f" 600
      echo "created:    $conf/$f" >&2
    fi
  done
  local kind=user
  [[ $(readlink -m -- "$defs") == "$SECRETS_ROOT_LIB" ]] && kind=user-root
  ensure_secrets_conf "$conf/secrets.conf" "$kind" 600
}

# list_tools FILE  ->  "name  type  exec" table (paths shown with ~)
list_tools() {
  local n
  for n in $(conf_tools "$1"); do
    ( HOME='~'; conf_load "$1" "$n" || exit 0
      more=""; (( ${#T_EXECS[@]} < 2 )) || more="  (+$(( ${#T_EXECS[@]} - 1 )) more)"
      printf '  %-12s %-4s %s%s\n' "$n" "$T_TYPE" "$T_EXEC" "$more" ) || true
  done
}

# =============================================================================
# Action log — every change on disk goes through an act_* function, so that
# `ai-sandbox-undo` can reverse it later. Anything overwritten or deleted is
# copied to backups/ first.
#   root:  /var/lib/ai-sandbox/{actions.log,backups/}
#   user:  ~/.local/state/ai-sandbox/{actions.log,backups/}   (never visible inside)
#
# WRITE-AHEAD: each change is logged BEFORE it is made. If a script stops
# anywhere (Ctrl-C, crash, power loss, a failing command), every change it
# made is in the log; a logged change that never happened is recognised by
# undo and skipped quietly ("not done").
#
# actions.log, tab-separated, one RUN header per command that changed something:
#   RUN    <run-id> <time> <user> <command>
#   <run-id> <seq> <-|sudo> tmp     FILE                  (temp file; deleted if left)
#   <run-id> <seq> <-|sudo> mkdir   DIR
#   <run-id> <seq> <-|sudo> new     FILE  -       HASH    (created; HASH = content)
#   <run-id> <seq> <-|sudo> replace FILE  BACKUP  HASH    (overwritten; old copy)
#   <run-id> <seq> <-|sudo> remove  PATH  BACKUP          (deleted; old copy)
#   <run-id> <seq> <-|sudo> mv      SRC   DST             (renamed)
#   <run-id> <seq> <-|sudo> divert  ORIG  DIVERTED        (dpkg-divert --add --rename)
#   <run-id> <seq> <-|sudo> undivert ORIG DIVERTED        (dpkg-divert --remove --rename)
#   <run-id> <seq> <-|sudo> hook    RCFILE MARK  nl|nonl  (2 lines appended to a shell rc;
#                                                          undo removes exactly those)
#   <run-id> <seq> <-|sudo> note    TEXT                  (information only)
#   UNDO   <run-id> <seq> <time>                          (written by ai-sandbox-undo)
#
# Test only: AI_SANDBOX_TEST_CRASH_AFTER=N kills the script (SIGKILL) right
# after the N-th log entry, i.e. before that change is made (vm-test 98).
# =============================================================================
PRIV=()                 # (sudo) while a caller works in a root-owned folder
ACT_DESC="" ACT_RUN="" ACT_SEQ=0 ACT_DIR="" _ACT_TOTAL=0

act_state_dir() {
  if (( EUID == 0 )); then echo /var/lib/ai-sandbox
  else echo "${XDG_STATE_HOME:-$HOME/.local/state}/ai-sandbox"; fi
}

# act_begin "command line"  ->  start logging (the RUN header is written lazily,
# on the first real change, so commands that change nothing leave no trace)
act_begin() { ACT_DESC=$*; ACT_RUN=""; ACT_SEQ=0; ACT_DIR=$(act_state_dir); }

# the state folder itself; the parents it had to create are remembered in
# created-dirs, so `ai-sandbox-undo purge` can remove them at the very end
_act_state_mk() {
  local d=$ACT_DIR p
  local -a made=()
  [[ -d $d/backups ]] && return 0
  p=$d
  while [[ ! -e $p ]]; do made=("$p" "${made[@]}"); p=$(dirname "$p"); done
  mkdir -p "$d/backups"; chmod 700 "$d" "$d/backups"
  for p in "${made[@]}"; do [[ $p == "$d" ]] || printf '%s\n' "$p" >> "$d/created-dirs"; done
}

_act_init() {
  [[ -n $ACT_DESC && -z $ACT_RUN ]] || return 0
  _act_state_mk
  # keep a copy of the undo tool next to the log: it must work even after
  # an uninstall (or after undoing the install) removed the installed one
  local u
  for u in /usr/local/bin/ai-sandbox-undo "$HOME/.local/bin/ai-sandbox-undo"; do
    if [[ -f $u ]]; then
      cmp -s "$u" "$ACT_DIR/ai-sandbox-undo" || install -m 755 "$u" "$ACT_DIR/ai-sandbox-undo"
      break
    fi
  done
  ACT_RUN="$(date +%Y%m%d-%H%M%S)-$$"
  printf 'RUN\t%s\t%s\t%s\t%s\n' "$ACT_RUN" "$(date '+%F %T')" "$(id -un)" \
    "$(tr '\t\n' '  ' <<<"$ACT_DESC")" >> "$ACT_DIR/actions.log"
}

_act_ok() {             # paths with a tab or newline would break the log
  local x
  for x in "$@"; do [[ $x != *[$'\t\n']* ]] || die "refusing path with tab/newline: $x"; done
}

_act_log() {            # _act_log OP ARG...   (call it BEFORE making the change)
  [[ -n $ACT_DESC ]] || return 0
  _act_init
  ACT_SEQ=$((ACT_SEQ + 1))
  local priv=- IFS=$'\t'
  (( ${#PRIV[@]} == 0 )) || priv=sudo
  printf '%s\n' "$ACT_RUN$IFS$ACT_SEQ$IFS$priv$IFS$*" >> "$ACT_DIR/actions.log"
  _ACT_TOTAL=$((_ACT_TOTAL + 1))
  if [[ ${AI_SANDBOX_TEST_CRASH_AFTER:-0} == "$_ACT_TOTAL" ]]; then kill -KILL $$; fi
}

_act_backup() {         # _act_backup PATH -> prints the backup path (call _act_init first)
  [[ -n $ACT_DESC ]] || { printf -- -; return 0; }
  local b="$ACT_DIR/backups/$ACT_RUN-$((ACT_SEQ + 1))-$(basename "$1")"
  "${PRIV[@]}" rm -rf "$b"                       # a half-made copy from a stopped run
  "${PRIV[@]}" cp -a "$1" "$b" || return 1
  printf '%s' "$b"
}

act_hash() {            # act_hash PATH -> short description of its content
  if   [[ -L $1 ]]; then printf 'link:%s' "$(readlink "$1")"
  elif [[ -d $1 ]]; then printf dir
  elif [[ -e $1 ]]; then { sha256sum < "$1" | cut -c1-64; } 2>/dev/null || printf '?'
  else printf none
  fi
}

act_mkdir() {           # act_mkdir DIR [MODE]  (like mkdir -p; logs each new level)
  local d=$1 mode=${2:-} p
  local -a made=()
  _act_ok "$d"
  p=$d
  while [[ ! -e $p && ! -L $p ]]; do made=("$p" "${made[@]}"); p=$(dirname "$p"); done
  for p in "${made[@]}"; do
    _act_log mkdir "$p"
    "${PRIV[@]}" mkdir "$p" || return 1
  done
  [[ -z $mode ]] || "${PRIV[@]}" chmod "$mode" "$d"
}

# _act_tmp FILE [MODE|keep] < content -> sets ACT_TMP: the temp file next to FILE
# (same folder = atomic rename; logged first, so a stop leaves nothing unknown).
# Not called in $(...): its log entry must count in this shell.
ACT_TMP=""
_act_tmp() {
  local f=$1 mode=${2:-644}
  ACT_TMP=$1.ai-sandbox-tmp
  [[ $mode != keep ]] || mode=$(stat -c %a "$f" 2>/dev/null || echo 644)
  if [[ ! -e $ACT_TMP && ! -L $ACT_TMP ]]; then _act_log tmp "$ACT_TMP"; fi
  "${PRIV[@]}" tee "$ACT_TMP" >/dev/null || return 1
  "${PRIV[@]}" chmod "$mode" "$ACT_TMP" || return 1
}

act_write() {           # act_write FILE [MODE|keep]  < content   (atomic; no-op if same)
  local f=$1 mode=${2:-644} tmp b
  _act_ok "$f"
  [[ $mode != keep ]] || mode=$(stat -c %a "$f" 2>/dev/null || echo 644)
  if [[ -e $f && ! -L $f ]]; then
    # unchanged content: nothing to log, nothing to write
    tmp=$(mktemp); cat > "$tmp"
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; "${PRIV[@]}" chmod "$mode" "$f"; return 0; fi
    local fd new
    exec {fd}<"$tmp"; rm -f "$tmp"          # unlinked now: a stop leaves nothing in /tmp
    _act_init
    b=$(_act_backup "$f") || { exec {fd}<&-; return 1; }
    _act_tmp "$f" "$mode" <&"$fd" || { exec {fd}<&-; return 1; }
    exec {fd}<&-
    _act_log replace "$f" "$b" "$(act_hash "$ACT_TMP")"
    "${PRIV[@]}" mv -fT "$ACT_TMP" "$f" || return 1
  elif [[ -L $f ]]; then
    _act_init
    b=$(_act_backup "$f") || return 1
    _act_tmp "$f" "$mode" || return 1
    _act_log replace "$f" "$b" "$(act_hash "$ACT_TMP")"
    "${PRIV[@]}" mv -fT "$ACT_TMP" "$f" || return 1
  else
    _act_tmp "$f" "$mode" || return 1
    _act_log new "$f" - "$(act_hash "$ACT_TMP")"
    "${PRIV[@]}" mv -fT "$ACT_TMP" "$f" || return 1
  fi
}

act_install() { act_write "$2" "${3:-644}" < "$1"; }   # act_install SRC DST [MODE]

act_rm() {              # act_rm PATH  (file, link or whole folder; backed up first)
  local p=$1 b
  [[ -e $p || -L $p ]] || return 0
  _act_ok "$p"; _act_init
  b=$(_act_backup "$p") || return 1
  _act_log remove "$p" "$b"
  "${PRIV[@]}" rm -rf "$p" || return 1
}

act_mv() {              # act_mv SRC DST  (DST, if present, is removed via act_rm first)
  _act_ok "$1" "$2"
  if [[ -e $2 || -L $2 ]]; then act_rm "$2" || return 1; fi
  _act_log mv "$1" "$2"
  "${PRIV[@]}" mv -T "$1" "$2" || return 1
}

# act_hook RCFILE MARK LINE — append "MARK\nLINE" to a shell rc file. Logged as
# its own kind of change: undo removes exactly these lines, so your own later
# edits of the file are kept.
act_hook() {
  local f=$1 nl=nl tmp
  _act_ok "$f"
  if [[ -s $f && $(tail -c1 "$f" | od -An -tx1) != *0a* ]]; then nl=nonl; fi
  _act_tmp "$f" keep < <(cat "$f"; printf '\n%s\n%s\n' "$2" "$3") || return 1
  _act_log hook "$f" "$2" "$nl"
  "${PRIV[@]}" mv -fT "$ACT_TMP" "$f" || return 1
}

# act_divert ORIG DIVERTED  — a file owned by a Debian package: let dpkg itself
# move it aside (dpkg-divert --rename), so package upgrades install the new
# version at DIVERTED and never overwrite the wrapper at ORIG.
act_divert() {
  _act_ok "$1" "$2"
  _act_log divert "$1" "$2"
  "${PRIV[@]}" dpkg-divert --quiet --local --rename --divert "$2" --add "$1" || return 1
}
act_undivert() {        # act_undivert ORIG DIVERTED  (ORIG must not exist)
  _act_ok "$1" "$2"
  _act_log undivert "$1" "$2"
  "${PRIV[@]}" dpkg-divert --quiet --local --rename --divert "$2" --remove "$1" || return 1
}
is_diverted() {         # is_diverted ORIG -> true if a local diversion exists
  command -v dpkg-divert >/dev/null && [[ -n $(dpkg-divert --listpackage "$1" 2>/dev/null) ]]
}
pkg_owns() {            # pkg_owns PATH -> true if a Debian package ships PATH
  command -v dpkg-query >/dev/null && dpkg-query -S "$1" 2>/dev/null | grep -q "^[^:]*: $1\$"
}

# newest_of GLOB  ->  the highest-versioned executable file matching GLOB
# (exec-newest: tools whose updater drops new versions into a versions/ dir)
newest_of() {
  local m
  local -a all=()
  while IFS= read -r m; do
    if [[ -f $m && -x $m ]]; then all+=("$m"); fi
  done < <(compgen -G "$1")
  (( ${#all[@]} )) || return 1
  printf '%s\n' "${all[@]}" | sort -V | tail -1
}

# tty_read VAR: read one line from the keyboard, one key at a time, so it
# ends on Enter whatever the terminal sends: \n, or a bare \r (^M) when a
# crashed TUI left the terminal without CR->NL. Backspace works.
tty_read() {
  local _c _l="" _rc=0
  while :; do
    IFS= read -rsn1 _c </dev/tty || { _rc=1; break; }
    case $_c in
      ""|$'\n'|$'\r') break ;;
      $'\177'|$'\b') if [[ -n $_l ]]; then _l=${_l%?}; printf '\b \b' >/dev/tty; fi ;;
      $'\003') _rc=130; break ;;
      *) _l+=$_c; printf '%s' "$_c" >/dev/tty ;;
    esac
  done
  printf '\n' >/dev/tty
  printf -v "$1" '%s' "$_l"
  return $_rc
}
