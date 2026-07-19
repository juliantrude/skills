#!/usr/bin/env bash
# One run of the advance-goal chain. Fired by the one-shot scheduler
# (hustle-scheduler.sh) or started manually to kick the chain off.
#
# Lifecycle:
#   1. take the run lock (portable mkdir lock — no flock on macOS)
#   2. disarm the one-shot that fired us (self-deleting "cron")
#   3. make sure the monitor dashboard is up
#   4. run ONE headless increment of /advance-goal
#      -> the skill itself arms the NEXT one-shot before exiting
#   5. publish status.json for the monitor
#   6. safety net: stop if goal complete; re-arm +15m if nothing is scheduled
#
# All state lives in <project>/.hustle/ + <project>/GOAL.md; a missed or
# crashed run is harmless — the next start resumes from GOAL.md.
set -uo pipefail

HUSTLE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$HUSTLE_HOME/config"

BIN="$HUSTLE_HOME/bin"
LOG="$HUSTLE_HOME/run.log"
STATUS_JSON="$HUSTLE_HOME/status.json"
LOCKDIR="$HUSTLE_HOME/lock"
RUN_OUT="$HUSTLE_HOME/run.out"

log(){ echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG"; }

# --- peer chains ------------------------------------------------------------
# Every chain on this machine draws on the same Claude subscription. Two of
# them running at once burn the budget twice as fast and race each other into
# the session limit, so a run yields to a peer that is already working.
#
# Peers are discovered from their own files rather than a shared registry: a
# registry outlives the crashes it is supposed to describe, and stale entries
# are exactly the failure we are trying to avoid. run.pid answers "is it
# working", status.json answers "is it finished" — both already exist.
# list-unit-files, not list-units: an idle chain's oneshot unit is not loaded
# between runs, so list-units would only ever report chains that happen to be
# awake. The monitor units are skipped — their ExecStart is the interpreter,
# not the project.
peer_homes() {
  systemctl --user list-unit-files 'hustle-*.service' --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | grep -v '^hustle-monitor-' | while read -r unit; do
        systemctl --user show "$unit" -p ExecStart --value 2>/dev/null \
          | grep -oE 'path=[^ ;]+' | cut -d= -f2- | sed -n 's#/bin/hustle-session\.sh$##p'
      done | sort -u | grep -v "^${HUSTLE_HOME}$"
}

peer_phase() {
  sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/status.json" 2>/dev/null | head -1
}

peer_running() {
  local pid; pid="$(cat "$1/run.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Retire what a finished chain left behind: its monitor keeps holding a port
# long after the work is done (that is how a stale dashboard ends up being the
# one you are looking at).
retire_peer() {
  local home="$1" slug mpid
  slug="$(sed -n 's/^HUSTLE_SLUG="\(.*\)"$/\1/p' "$home/config" 2>/dev/null | head -1)"
  [ -n "$slug" ] && systemctl --user stop "hustle-monitor-${slug}.service" >/dev/null 2>&1
  mpid="$(cat "$home/monitor.pid" 2>/dev/null)"
  [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null && kill "$mpid" 2>/dev/null
  # monitor.pid records the pid at launch and goes stale the moment systemd
  # restarts the unit, so match on the path the process was started from too.
  # Scoped to that project's own bin directory: it cannot hit anyone else.
  pkill -f "^python3 ${home}/bin/hustle-monitor\.py" 2>/dev/null
  return 0
}

# 0 = clear to run, 3 = a peer is actively working.
check_peers() {
  local home phase blocked=0
  while read -r home; do
    [ -n "$home" ] && [ -d "$home" ] || continue
    phase="$(peer_phase "$home")"
    if peer_running "$home"; then
      log "[peer] active chain in ${home%/.hustle} — yielding"
      blocked=1
    elif [ "$phase" = "complete" ]; then
      log "[peer] finished chain in ${home%/.hustle} — retiring its leftovers"
      retire_peer "$home"
    fi
  done < <(peer_homes)
  [ "$blocked" -eq 0 ] || return 3
}

# `--check-peers` lets the interactive /hustle skill ask the same question
# before igniting, where there is a human to answer it.
if [ "${1:-}" = "--check-peers" ]; then
  if check_peers; then echo "clear"; exit 0; else echo "blocked"; exit 3; fi
fi

# --- portable single-flight lock (mkdir is atomic everywhere) ---------------
take_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then echo $$ > "$LOCKDIR/pid"; return 0; fi
  local holder; holder="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    return 1                       # a live run holds the lock
  fi
  rm -rf "$LOCKDIR"                # stale lock from a dead run
  mkdir "$LOCKDIR" 2>/dev/null && echo $$ > "$LOCKDIR/pid"
}
release_lock(){ rm -f "$HUSTLE_HOME/run.pid"; rm -rf "$LOCKDIR"; }

if ! take_lock; then log "[skip] previous run still active"; exit 0; fi
trap release_lock EXIT
echo $$ > "$HUSTLE_HOME/run.pid"

# --- 2. self-delete the one-shot that launched us ---------------------------
"$BIN/hustle-scheduler.sh" disarm >/dev/null 2>&1 || true

# --- 2b. yield to a peer chain ----------------------------------------------
# Blocked runs are parked, not cancelled: the peer is usually minutes from
# finishing, and a chain that quietly died because another one happened to be
# busy is worse than one that waits.
if ! check_peers; then
  log "[peer] parking this run — retrying in 5 min"
  "$BIN/hustle-scheduler.sh" arm --in 300 >> "$LOG" 2>&1 || log "[error] peer re-arm failed"
  exit 0
fi

# --- 3. ensure the monitor is running ---------------------------------------
# Linux: the monitor MUST run as its own systemd unit. A nohup'ed child of this
# script lives in the oneshot service's cgroup and gets killed the moment the
# run ends (KillMode=control-group) — it would only ever live during a run.
# macOS: no cgroups; a detached nohup daemon survives fine.
if [ "$(uname -s)" != "Darwin" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user start "hustle-monitor-${HUSTLE_SLUG}.service" 2>/dev/null \
    || log "[monitor] could not start hustle-monitor-${HUSTLE_SLUG}.service"
else
  mpid="$(cat "$HUSTLE_HOME/monitor.pid" 2>/dev/null || true)"
  if [ -z "$mpid" ] || ! kill -0 "$mpid" 2>/dev/null; then
    nohup python3 "$BIN/hustle-monitor.py" >> "$HUSTLE_HOME/monitor.log" 2>&1 &
    echo $! > "$HUSTLE_HOME/monitor.pid"
    log "[monitor] started (pid $!)"
  fi
fi

cd "$HUSTLE_PROJECT" || { log "[error] cd $HUSTLE_PROJECT failed"; exit 1; }

# --- 4. one headless increment ----------------------------------------------
perm_flag=""
[ "${HUSTLE_SKIP_PERMISSIONS:-true}" = "true" ] && perm_flag="--dangerously-skip-permissions"
log "[start] advance-goal run (model=${HUSTLE_MODEL:-sonnet} effort=${HUSTLE_EFFORT:-high})"
claude -p "/advance-goal" --model "${HUSTLE_MODEL:-sonnet}" --effort "${HUSTLE_EFFORT:-high}" \
  $perm_flag > "$RUN_OUT" 2>&1
rc=$?
cat "$RUN_OUT" >> "$LOG"
log "[end] exit=${rc}"

# --- 5. publish status for the dashboard ------------------------------------
status_field(){ echo "$1" | grep -oE "$2=[^|]*" | head -1 | cut -d= -f2- ; }
SLINE="$(grep -a 'STATUS|' "$RUN_OUT" | tail -1 || true)"
next_fire(){ "$BIN/hustle-scheduler.sh" next 2>/dev/null; }
write_status(){ # phase note
  local phase="$1" note="$2"
  note="${note//\\/}"; note="${note//\"/\'}"
  cat > "$STATUS_JSON" <<EOF
{
  "updated": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "phase": "${phase:-unknown}",
  "session_pct": "$(status_field "$SLINE" session)",
  "week_pct": "$(status_field "$SLINE" week)",
  "reset": "$(status_field "$SLINE" reset)",
  "next_fire": "$(next_fire)",
  "last_exit": ${rc:-0},
  "note": "${note}"
}
EOF
}

# --- 6a. goal finished -> stop the chain ------------------------------------
if grep -qE '^STATUS: *COMPLETE' "$HUSTLE_PROJECT/GOAL.md" 2>/dev/null; then
  log "[done] GOAL complete — chain stops"
  write_status "complete" "goal reached"
  exit 0
fi

# --- 6b. self-heal: arm a fallback unless a future fire is scheduled --------
if [ -z "$(next_fire)" ]; then
  log "[safety-net] no future run scheduled — fallback +15m"
  "$BIN/hustle-scheduler.sh" arm --in 900 >> "$LOG" 2>&1 || log "[error] fallback arm failed"
fi

write_status "$(status_field "$SLINE" phase)" "$(status_field "$SLINE" note)"
exit 0
