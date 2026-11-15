#!/usr/bin/env bash
# =============================================================================
# ai-sandbox-undo — reverse what ai-sandbox / ai-sandbox-admin did, using the
#                   action log they write
#
#   ai-sandbox-undo list              runs that can still be undone
#   ai-sandbox-undo show [RUN|last]   the changes one run made
#   ai-sandbox-undo last              undo the newest run
#   ai-sandbox-undo run RUN           undo one run (by id from `list`)
#   ai-sandbox-undo all               undo everything, newest first
#   ai-sandbox-undo log               print the raw log
#   ai-sandbox-undo prune [DAYS]      free backup space: drop the backups of
#                                     undone runs (+ runs older than DAYS)
#   ai-sandbox-undo purge             the very last step, after `all`: delete the
#                                     log, backups, this tool, aisup.log and the
#                                     empty folders the sandbox created — your
#                                     home is then as before the install
#
# Options (before the command):
#   -n   dry run: only print what would happen
#   -f   force: undo even what was changed again since (by you or an update);
#        the current version is saved to backups/forced-* first
#   -y   don't ask for confirmation
#
# Log: root -> /var/lib/ai-sandbox/actions.log
#      user -> ~/.local/state/ai-sandbox/actions.log
# A copy of this script stays next to the log (…/ai-sandbox/ai-sandbox-undo),
# even after an uninstall or after undoing the install.
#      AI_SANDBOX_STATE=/dir  reads another one
#
# Every change is checked before it is reversed: a file is only deleted or
# restored if it still has the content the log recorded. Changed things are
# skipped (and reported) unless -f is given. A non-empty folder is never
# deleted, even with -f: it holds data that is not ours.
#
# Safe to stop and re-run: changes are logged BEFORE they are made, so a
# script that stopped half-way left only logged changes; one that never
# happened is recognised ("not done"). An undo that stopped half-way just
# continues where it stopped when run again.
#
# Self-contained on purpose (no lib.sh): it must still work after an
# uninstall removed everything else.
# =============================================================================
set -euo pipefail

die()  { echo "ai-sandbox-undo: $*" >&2; exit 1; }
warn() { echo "ai-sandbox-undo: warning: $*" >&2; }

if (( EUID == 0 )); then STATE=/var/lib/ai-sandbox
else STATE=${XDG_STATE_HOME:-$HOME/.local/state}/ai-sandbox; fi
STATE=${AI_SANDBOX_STATE:-$STATE}
LOG=$STATE/actions.log

DRY=0 FORCE=0 YES=0
while [[ ${1:-} == -* ]]; do
  case $1 in
    -n) DRY=1 ;; -f) FORCE=1 ;; -y) YES=1 ;;
    -nf|-fn) DRY=1 FORCE=1 ;; -fy|-yf) FORCE=1 YES=1 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

hash_of() {             # same format as act_hash in lib.sh
  if   [[ -L $1 ]]; then printf 'link:%s' "$(readlink "$1")"
  elif [[ -d $1 ]]; then printf dir
  elif [[ -e $1 ]]; then { sha256sum < "$1" | cut -c1-64; } 2>/dev/null || printf '?'
  else printf none
  fi
}
exists() { [[ -e $1 || -L $1 ]]; }
same() {                # same BACKUP PATH -> 0 if PATH has exactly the backup's content
  if [[ -L $1 || -L $2 ]]; then [[ -L $1 && -L $2 && $(readlink "$1") == "$(readlink "$2")" ]]
  elif [[ -d $1 && -d $2 ]]; then "${P[@]}" diff -rq --no-dereference "$1" "$2" >/dev/null 2>&1
  elif [[ -f $1 && -f $2 ]]; then "${P[@]}" cmp -s "$1" "$2"
  else return 1; fi
}

# -----------------------------------------------------------------------------
# read the log
# -----------------------------------------------------------------------------
declare -a RUNS=()                       # run ids, oldest first
declare -A R_TIME=() R_USER=() R_DESC=() R_N=() LINE=() DONE=()

load() {
  [[ -f $LOG ]] || die "no action log at $LOG (nothing was changed yet?)"
  local line
  local -a F
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    IFS=$'\t' read -ra F <<<"$line"
    case ${F[0]} in
      RUN)  RUNS+=("${F[1]}"); R_TIME[${F[1]}]=${F[2]:-}; R_USER[${F[1]}]=${F[3]:-}
            R_DESC[${F[1]}]=${F[4]:-}; R_N[${F[1]}]=0 ;;
      UNDO) DONE[${F[1]}:${F[2]}]=1 ;;
      *)    LINE[${F[0]}:${F[1]}]=$line
            if (( F[1] > ${R_N[${F[0]}]:-0} )); then R_N[${F[0]}]=${F[1]}; fi ;;
    esac
  done < "$LOG"
}

open_count() {          # open_count RUN -> number of changes not undone yet
  local run=$1 s n=0
  for ((s = 1; s <= ${R_N[$run]:-0}; s++)); do [[ -n ${DONE[$run:$s]:-} ]] || n=$((n + 1)); done
  echo "$n"
}

open_runs() {           # newest first
  local i
  for ((i = ${#RUNS[@]} - 1; i >= 0; i--)); do
    (( $(open_count "${RUNS[i]}") > 0 )) && echo "${RUNS[i]}"
  done
  return 0
}

pick_run() {            # pick_run RUN|last -> run id
  local r=${1:-last}
  if [[ $r == last ]]; then
    r=$(open_runs | head -1)
    [[ -n $r ]] || die "nothing left to undo"
  fi
  [[ -n ${R_N[$r]+x} ]] || die "no run '$r' in $LOG (see: ai-sandbox-undo list)"
  echo "$r"
}

describe() {            # describe OP A B -> what undoing it will do
  case $1 in
    mkdir)   echo "remove folder (if empty)   $2" ;;
    new)     echo "delete                     $2" ;;
    replace) echo "restore the old            $2" ;;
    remove)  echo "put back                   $2" ;;
    mv)      echo "move back                  $3  ->  $2" ;;
    divert)  echo "remove dpkg diversion      $2  (file back from $3)" ;;
    undivert) echo "re-add dpkg diversion      $2  ->  $3" ;;
    hook)    echo "remove our 2 lines from    $2" ;;
    tmp)     echo "delete leftover temp file  $2" ;;
    note)    echo "(note, nothing to undo)    $2" ;;
    *)       echo "?? unknown action '$1'     $2" ;;
  esac
}

# -----------------------------------------------------------------------------
# undo one change. Returns 0 = done (or nothing to do), 1 = skipped
# -----------------------------------------------------------------------------
P=()
restore() {             # restore BACKUP PATH
  "${P[@]}" rm -rf "$2" && "${P[@]}" mkdir -p "$(dirname "$2")" && "${P[@]}" cp -a "$1" "$2"
}
# (undo_one runs inside `if`, where set -e is off: every command checks itself)
fail() { warn "$1 failed — skipped"; return 1; }

# -f over something that changed since: keep a copy of the current version
FORCED_N=0
save_current() {        # save_current PATH
  exists "$1" || return 0
  FORCED_N=$((FORCED_N + 1))   # unique: one undo can save the same file several times in a second
  local c="$STATE/backups/forced-$(date +%Y%m%d-%H%M%S)-$$-$FORCED_N-$(basename "$1")"
  (( DRY )) || "${P[@]}" cp -a "$1" "$c" || return 1
  echo "  saved:    current $1 -> $c"
}

undo_one() {            # undo_one PRIV OP A B C
  local priv=$1 op=$2 a=${3:-} b=${4:-} h=${5:-}
  P=(); if [[ $priv == sudo && $EUID -ne 0 ]]; then P=(sudo); fi

  case $op in
    mkdir)
      if [[ ! -d $a ]]; then echo "  gone:     $a"; return 0; fi
      if [[ -n $(ls -A "$a" 2>/dev/null) ]]; then
        local sp
        for sp in "${SKIPPED[@]}"; do          # not empty only because of a skipped step?
          if [[ $sp == "$a"/* ]]; then
            warn "$a still holds skipped $sp — kept for now"; return 1
          fi
        done
        echo "  kept:     $a (not empty: holds data that is not ours)"; return 0
      fi
      (( DRY )) || "${P[@]}" rmdir "$a" || { fail "rmdir $a"; return 1; }
      echo "  removed:  $a/" ;;

    new)
      if ! exists "$a"; then echo "  gone:     $a"; return 0; fi
      if [[ $(hash_of "$a") != "$h" ]] && (( ! FORCE )); then
        warn "$a changed since it was created — skipped (-f to delete anyway)"; return 1
      fi
      if [[ $(hash_of "$a") != "$h" ]]; then save_current "$a" || { fail "saving $a"; return 1; }; fi
      (( DRY )) || "${P[@]}" rm -rf "$a" || { fail "rm $a"; return 1; }
      echo "  deleted:  $a" ;;

    replace)
      exists "$b" || { warn "backup of $a is gone ($b) — skipped"; return 1; }
      if exists "$a" && same "$b" "$a"; then echo "  same:     $a has its old content (never replaced, or already restored)"; return 0; fi
      if exists "$a" && [[ $(hash_of "$a") != "$h" ]] && (( ! FORCE )); then
        warn "$a changed since — skipped (-f to restore the old one anyway)"; return 1
      fi
      if exists "$a" && [[ $(hash_of "$a") != "$h" ]]; then save_current "$a" || { fail "saving $a"; return 1; }; fi
      (( DRY )) || restore "$b" "$a" || { fail "restore $a"; return 1; }
      echo "  restored: $a" ;;

    remove)
      exists "$b" || { warn "backup of $a is gone ($b) — skipped"; return 1; }
      if exists "$a" && same "$b" "$a"; then echo "  same:     $a is there with its old content (never removed, or already put back)"; return 0; fi
      if exists "$a" && (( ! FORCE )); then
        warn "$a exists again — skipped (-f to overwrite it with the old one)"; return 1
      fi
      save_current "$a" || { fail "saving $a"; return 1; }
      (( DRY )) || restore "$b" "$a" || { fail "restore $a"; return 1; }
      echo "  put back: $a" ;;

    mv)                 # was: a -> b
      if exists "$b" && ! exists "$a"; then
        (( DRY )) || "${P[@]}" mv -T "$b" "$a" || { fail "mv $b $a"; return 1; }
        echo "  moved:    $b -> $a"
      elif exists "$a" && ! exists "$b"; then
        echo "  already:  $a is back"
      elif exists "$a" && exists "$b"; then
        if (( FORCE )); then
          save_current "$a" || { fail "saving $a"; return 1; }
          (( DRY )) || "${P[@]}" mv -fT "$b" "$a" || { fail "mv $b $a"; return 1; }
          echo "  moved:    $b -> $a (overwrote)"
        else
          warn "both $a and $b exist — skipped (-f to move $b over $a)"; return 1
        fi
      else
        warn "neither $a nor $b exists — skipped"; return 1
      fi ;;

    divert)             # was: dpkg-divert --add --rename  a -> b
      if [[ -z $(dpkg-divert --listpackage "$a" 2>/dev/null) ]]; then echo "  gone:     diversion of $a"; return 0; fi
      if exists "$a"; then warn "$a exists — remove it first (skipped)"; return 1; fi
      (( DRY )) || "${P[@]}" dpkg-divert --quiet --local --rename --divert "$b" --remove "$a" \
        || { fail "dpkg-divert --remove $a"; return 1; }
      echo "  undiverted: $a (package file back in place)" ;;

    undivert)           # was: dpkg-divert --remove --rename  (b -> a)
      if [[ -n $(dpkg-divert --listpackage "$a" 2>/dev/null) ]]; then echo "  already:  $a diverted"; return 0; fi
      (( DRY )) || "${P[@]}" dpkg-divert --quiet --local --rename --divert "$b" --add "$a" \
        || { fail "dpkg-divert --add $a"; return 1; }
      echo "  diverted: $a -> $b" ;;

    hook)               # a = rc file, b = marker line, h = nl|nonl (did it end with a newline)
      if ! exists "$a" || ! grep -qxF -- "$b" "$a"; then echo "  gone:     hook in $a"; return 0; fi
      if (( ! DRY )); then
        local t=$a.ai-sandbox-undo-tmp total last
        total=$(wc -l < "$a"); last=$(grep -nxF -- "$b" "$a" | tail -1 | cut -d: -f1)
        awk -v m="$b" '{ L[NR] = $0 } END {
            for (i = 1; i <= NR; i++)
              if (L[i] == m) { if (i > 1 && L[i-1] == "") D[i-1] = 1; D[i] = 1; D[i+1] = 1; i++ }
            for (i = 1; i <= NR; i++) if (!(i in D)) print L[i]
          }' "$a" | { if [[ $h == nonl && $((last + 1)) -ge $total ]]; then head -c -1; else cat; fi; } \
          | "${P[@]}" tee "$t" >/dev/null || { "${P[@]}" rm -f "$t"; fail "hook in $a"; return 1; }
        "${P[@]}" chmod --reference="$a" "$t" && "${P[@]}" mv -fT "$t" "$a" || { fail "hook in $a"; return 1; }
      fi
      echo "  unhooked: $a (only our lines; your own edits stay)" ;;

    tmp)
      [[ $a == *.ai-sandbox-tmp ]] || { warn "odd temp file name $a — skipped"; return 1; }
      if ! exists "$a"; then return 0; fi
      (( DRY )) || "${P[@]}" rm -f "$a" || { fail "rm $a"; return 1; }
      echo "  deleted:  leftover $a" ;;

    note) echo "  note:     $a"; return 0 ;;

    *) warn "unknown action '$op' — skipped"; return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
SKIPPED=()              # paths of steps skipped in this undo (across runs)
TEST_N=0
undo_run() {            # undo_run RUN  -> returns number of skipped changes
  local run=$1 s skipped=0
  local -a F
  echo "== undo $run  (${R_TIME[$run]}  ${R_DESC[$run]})"
  for ((s = ${R_N[$run]}; s >= 1; s--)); do       # newest change first
    [[ -z ${DONE[$run:$s]:-} ]] || continue
    IFS=$'\t' read -ra F <<<"${LINE[$run:$s]}"
    if undo_one "${F[2]}" "${F[3]}" "${F[4]:-}" "${F[5]:-}" "${F[6]:-}"; then
      TEST_N=$((TEST_N + 1))      # test only (vm-test 98): stop after the change, before logging it
      if [[ ${AI_SANDBOX_TEST_CRASH_AFTER:-0} == "$TEST_N" ]]; then kill -KILL $$; fi
      if (( ! DRY )); then
        printf 'UNDO\t%s\t%s\t%s\n' "$run" "$s" "$(date '+%F %T')" >> "$LOG"
        DONE[$run:$s]=1
      fi
    else
      skipped=$((skipped + 1))
      SKIPPED+=("${F[4]:-}"); [[ ${F[3]} != mv ]] || SKIPPED+=("${F[5]:-}")
    fi
  done
  return "$skipped"
}

show_run() {
  local run=$1 s
  local -a F
  printf '%s  %s  %s  %s\n' "$run" "${R_TIME[$run]}" "${R_USER[$run]}" "${R_DESC[$run]}"
  for ((s = ${R_N[$run]}; s >= 1; s--)); do
    IFS=$'\t' read -ra F <<<"${LINE[$run:$s]}"
    [[ ${F[3]} != tmp ]] || continue                 # internal, not worth showing
    local tag="    "; [[ -z ${DONE[$run:$s]:-} ]] || tag="done"
    local su=""; [[ ${F[2]} != sudo ]] || su=" (sudo)"
    printf '  %s %3d  %s%s\n' "$tag" "$s" "$(describe "${F[3]}" "${F[4]:-}" "${F[5]:-}")" "$su"
  done
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

confirm() {
  (( YES || DRY )) && return 0
  local a=""
  # only the tty check is silenced: read -p prints its prompt on stderr, so
  # hiding stderr around read would hide the question and look like a hang
  { : </dev/tty; } 2>/dev/null || die "no terminal to confirm: use -y"
  printf '%s [y/N] ' "$1" >/dev/tty
  tty_read a || true
  [[ $a == [yY]* ]]
}

do_undo() {             # do_undo RUN...
  local run total=0 rc
  for run in "$@"; do show_run "$run"; echo; done
  if (( DRY )); then
    echo "(dry run: nothing is changed. With several runs, steps that depend on"
    echo " an earlier step may show as skipped, because that step isn't really done.)"
  fi
  confirm "Undo the changes above (newest first)?" || { echo "nothing done"; return 0; }
  for run in "$@"; do
    rc=0; undo_run "$run" || rc=$?
    total=$((total + rc))
  done
  if (( total )); then
    echo; echo "$total change(s) skipped (see warnings). They stay in 'list'."
    echo "Force them (the current versions are saved first):  $STATE/ai-sandbox-undo -f last"
    return 1
  fi
  (( DRY )) || echo "Done."
}

cmd_prune() {
  local days=${1:-} cut="" run s
  local -a F
  if [[ -n $days ]]; then
    [[ $days =~ ^[0-9]+$ ]] || die "DAYS must be a number"
    cut=$(date -d "-$days days" +%Y%m%d-%H%M%S)
  fi
  local freed=0
  for run in "${RUNS[@]}"; do
    if (( $(open_count "$run") > 0 )) && [[ -z $cut || ! $run < $cut ]]; then continue; fi
    for ((s = 1; s <= ${R_N[$run]}; s++)); do
      IFS=$'\t' read -ra F <<<"${LINE[$run:$s]}"
      case ${F[3]} in replace|remove) ;; *) continue ;; esac
      local b=${F[5]:-}
      [[ $b == "$STATE/backups/"* ]] && exists "$b" || continue
      P=(); if [[ ${F[2]} == sudo && $EUID -ne 0 ]]; then P=(sudo); fi
      if (( DRY )); then echo "would delete $b"; else "${P[@]}" rm -rf "$b"; fi
      freed=$((freed + 1))
    done
  done
  echo "$freed backup(s) removed."
  [[ -z $days ]] || echo "Runs older than $days days can no longer restore the files they overwrote or deleted."
}

cmd_purge() {
  local run s n=0 d
  local -a F dirs=()
  for run in "${RUNS[@]}"; do n=$((n + $(open_count "$run"))); done
  if (( n && ! FORCE )); then
    die "$n change(s) are not undone yet. Run 'ai-sandbox-undo all' first (or -f to forget them)."
  fi
  # empty folders the sandbox created (their mkdir was undone or kept as "not
  # ours"), and the parents of the state folder itself
  for run in "${RUNS[@]}"; do
    for ((s = 1; s <= ${R_N[$run]:-0}; s++)); do
      IFS=$'\t' read -ra F <<<"${LINE[$run:$s]}"
      if [[ ${F[3]} == mkdir && -n ${DONE[$run:$s]:-} ]]; then dirs+=("${F[2]}"$'\t'"${F[4]}"); fi
    done
  done
  if [[ -f $STATE/created-dirs ]]; then
    while IFS= read -r d; do dirs+=("-"$'\t'"$d"); done < "$STATE/created-dirs"
  fi
  local alog=""
  if (( EUID != 0 )); then alog=${XDG_STATE_HOME:-$HOME/.local/state}/aisup.log; fi
  echo "Will delete: $STATE (log, backups, this undo tool)${alog:+ and $alog}"
  echo "and then every EMPTY folder the sandbox created. After this, undo is no longer possible."
  confirm "Purge?" || { echo "nothing done"; return 0; }
  (( DRY )) && return 0
  [[ -z $alog || ! -f $alog ]] || { rm -f "$alog"; echo "  deleted:  $alog"; }
  rm -rf "$STATE"; echo "  deleted:  $STATE"
  # deepest first
  while IFS=$'\t' read -r priv d; do
    [[ -n $d && -d $d && ! -L $d ]] || continue
    P=(); if [[ $priv == sudo && $EUID -ne 0 ]]; then P=(sudo); fi
    if "${P[@]}" rmdir "$d" 2>/dev/null; then echo "  removed:  $d/"; fi
  done < <(printf '%s\n' "${dirs[@]}" | awk -F'\t' '{ print split($2, a, "/") "\t" $0 }' | sort -rn | uniq | cut -f2-)
  echo "Purged."
}

# -----------------------------------------------------------------------------
cmd=${1:-}; shift || true
case $cmd in
  list)
    load
    printf '%-24s %-19s %-8s %s\n' RUN TIME CHANGES COMMAND
    found=0
    while IFS= read -r run; do
      [[ -n $run ]] || continue
      found=1
      printf '%-24s %-19s %-8s %s\n' "$run" "${R_TIME[$run]}" \
        "$(open_count "$run")/${R_N[$run]}" "${R_DESC[$run]}"
    done < <(open_runs)
    (( found )) || echo "(nothing left to undo)"
    ;;
  show) load; show_run "$(pick_run "${1:-last}")" ;;
  last) load; do_undo "$(pick_run last)" ;;
  run)  load; [[ -n ${1:-} ]] || die "usage: ai-sandbox-undo run RUN"; do_undo "$(pick_run "$1")" ;;
  all)
    load
    mapfile -t todo < <(open_runs)
    (( ${#todo[@]} )) || { echo "nothing left to undo"; exit 0; }
    do_undo "${todo[@]}"
    ;;
  log)   [[ -f $LOG ]] || die "no log at $LOG"; cat "$LOG" ;;
  prune) load; cmd_prune "${1:-}" ;;
  purge) load; cmd_purge ;;
  *) usage ;;
esac
