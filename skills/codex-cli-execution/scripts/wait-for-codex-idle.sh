#!/usr/bin/env bash
set -euo pipefail

# wait-for-codex-idle.sh
# Polls a Codex CLI TUI pane on the agent.sock socket until it appears idle.
#
# Idle decision (all evaluated on a pane whose content hash has been stable for
# `stability` consecutive polls):
#   - worker still running (--running-pattern visible) -> NOT done, keep waiting
#   - result marker present                            -> done (exit 0)
#   - marker gating disabled (--result-marker '')      -> done (exit 0)
#   - otherwise (quiet, no marker)                     -> unconfirmed (exit 5)
# A vanished session is detected and reported (exit 4) rather than mistaken for idle.
#
# Composes on top of ~/.claude/skills/tmux/scripts/wait-for-text.sh for the chrome wait.
# Implements the stability check inline with sha1.
#
# Exit codes:
#   0  idle AND result marker present (worker confirmed done)
#   1  timeout
#   2  error keyword detected in recent pane output (likely Codex denial / failure)
#   3  bad args / preconditions
#   4  target session/pane gone (worker crashed or session killed) -- NOT success
#   5  idle but result marker absent (pane quiet, completion unconfirmed)

usage() {
  cat <<'USAGE'
Usage: wait-for-codex-idle.sh -t target [options]

Wait until a Codex --yolo TUI pane goes idle.

Required:
  -t, --target       tmux target, e.g. codex-exec-093015:0.0

Options:
  -T, --timeout      total seconds to wait (default: 600)
  -p, --pattern      regex matching Codex input chrome
                     (default: '^›|gpt-[0-9]+\.[0-9]+ \w+|YOLO mode|▌ Send a message|esc to interrupt|tokens used|↑/↓ history')
  -s, --stability    consecutive stable polls required after chrome appears
                     (each poll is ~1s; default: 3). Independent of -i.
  -e, --error-regex  regex of failure keywords; if matched in recent output, exit 2
                     (default: 'error:|denied|permission denied|command failed|refused')
  -r, --running-pattern  regex that, while visible in a stable frame, means the worker
                     is still executing (e.g. a long silent subprocess), so a quiet pane
                     is NOT treated as done. Pass '' to disable. (default: 'esc to interrupt')
  -n, --error-scan-lines  only the last N lines are scanned for --error-regex, so a benign
                     keyword far up the scrollback can't abort a healthy run (default: 40)
  -l, --lines        history lines to capture (default: 2000)
  -i, --interval     poll interval seconds passed to wait-for-text.sh for phase 1
                     (default: 0.5). Phase 2 stability always polls at ~1s.
  -m, --result-marker regex of a result-block start line. Its presence in an idle (not
                     running) pane is the confirmed-done signal (exit 0), and the surfaced
                     tail starts from its last occurrence; its absence in an otherwise-idle
                     pane yields exit 5. Pass '' to disable marker gating.
                     (default: '=== CODEX RESULT ===')
  -q, --quiet        suppress info logging (errors still go to stderr)
  -h, --help         show this help

Notes:
  - Always uses the agent.sock private socket (`tmux -L agent.sock`).
  - Composes the tmux skill's wait-for-text.sh for the chrome match.
  - Surfaces the result block (from --result-marker) when present, else the last 80 lines,
    on every exit path -- so the caller reads dense signal, not a full scrollback dump.
    The surfaced tail always goes to stdout; diagnostics go to stderr. The 2000-line
    internal captures never leave this process.
  - exit 0 (done) requires the result marker in a non-running pane; exit 5 means the pane
    went quiet without it (worker may be done-without-marker, or blocked at a prompt).
USAGE
}

target=""
timeout=600
# Default sentinel covers Codex CLI v0.128+ chrome (`›` prompt arrow + `gpt-X.Y model`
# status line + boot-banner "YOLO mode") AND the older v0.x chrome strings, so the same
# helper works across builds. Override with -p if a future build changes things again.
pattern='^›|gpt-[0-9]+\.[0-9]+ \w+|YOLO mode|▌ Send a message|esc to interrupt|tokens used|↑/↓ history'
stability=3
error_regex='error:|denied|permission denied|command failed|refused'
running_pattern='esc to interrupt'
error_scan_lines=40
lines=2000
interval=0.5
result_marker='=== CODEX RESULT ==='
quiet=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)           target="${2-}"; shift 2 ;;
    -T|--timeout)          timeout="${2-}"; shift 2 ;;
    -p|--pattern)          pattern="${2-}"; shift 2 ;;
    -s|--stability)        stability="${2-}"; shift 2 ;;
    -e|--error-regex)      error_regex="${2-}"; shift 2 ;;
    -r|--running-pattern)  running_pattern="${2-}"; shift 2 ;;
    -n|--error-scan-lines) error_scan_lines="${2-}"; shift 2 ;;
    -l|--lines)            lines="${2-}"; shift 2 ;;
    -i|--interval)         interval="${2-}"; shift 2 ;;
    -m|--result-marker)    result_marker="${2-}"; shift 2 ;;
    -q|--quiet)            quiet=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 3 ;;
  esac
done

[[ -z "$target" ]] && { echo "target is required" >&2; usage; exit 3; }

for n in timeout stability lines error_scan_lines; do
  v="${!n}"
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "$n must be a non-negative integer (got: $v)" >&2; exit 3; }
done

command -v tmux  >/dev/null 2>&1 || { echo "tmux not in PATH" >&2; exit 3; }
command -v shasum >/dev/null 2>&1 || command -v sha1sum >/dev/null 2>&1 \
  || { echo "shasum or sha1sum required" >&2; exit 3; }

hash_cmd() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 1; else sha1sum; fi
}

log() { (( quiet )) || echo "[wait-for-codex-idle] $*" >&2; }

# True iff $2 (a regex) is non-empty AND matches somewhere in $1.
has_pat() {
  [[ -n "$2" ]] || return 1
  printf '%s\n' "$1" | grep -qE -- "$2"
}

# Surface dense signal to the caller (always on stdout -- it is the payload): if the
# result-block marker is present, print from its LAST occurrence to the end (capped at
# 120 lines); otherwise fall back to the last 80 lines. Last-occurrence handling means
# the worker's real final block wins over the marker template echoed in the pasted
# prompt. The full 2000-line capture never leaves here.
surface() {
  local txt="$1" start=""
  if [[ -n "$result_marker" ]]; then
    # `|| true`: grep exits 1 when the marker is absent; without this, pipefail +
    # set -e would kill the script before the tail-n-80 fallback can run.
    start="$(printf '%s\n' "$txt" | grep -nE -- "$result_marker" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)"
  fi
  if [[ -n "$start" ]]; then
    printf '%s\n' "$txt" | tail -n "+${start}" | tail -n 120
  else
    printf '%s\n' "$txt" | tail -n 80
  fi
}

# Resolve the tmux skill's wait-for-text.sh helper.
WAIT_FOR_TEXT="${WAIT_FOR_TEXT:-$HOME/.claude/skills/tmux/scripts/wait-for-text.sh}"
[[ -x "$WAIT_FOR_TEXT" ]] || { echo "wait-for-text.sh not executable at $WAIT_FOR_TEXT" >&2; exit 3; }

# Session name from the target (strip :window.pane). Used to detect a dead session so a
# vanished pane (empty capture) is never mistaken for a stable/idle one.
target_session="${target%%:*}"
session_alive() { tmux -L agent.sock has-session -t "$target_session" 2>/dev/null; }

session_alive || { echo "session gone: $target_session does not exist" >&2; exit 4; }

start_epoch=$(date +%s)
deadline=$((start_epoch + timeout))

capture() {
  tmux -L agent.sock capture-pane -p -J -t "$target" -S "-${lines}" 2>/dev/null || true
}

remaining() { echo $(( deadline - $(date +%s) )); }

check_error() {
  local txt="$1"
  # Only scan the most recent lines: a benign 'error:'/'denied' far up the scrollback
  # (test output, a log, docs) must not abort a healthy run.
  if printf '%s\n' "$txt" | tail -n "$error_scan_lines" | grep -E -- "$error_regex" >/dev/null 2>&1; then
    log "error keyword matched in last ${error_scan_lines} lines: $error_regex"
    surface "$txt"
    exit 2
  fi
}

# Phase 1: wait for input chrome to appear.
rem=$(remaining)
(( rem > 0 )) || { echo "timeout before chrome wait started" >&2; exit 1; }
log "phase 1/2: waiting up to ${rem}s for Codex input chrome..."

if ! "$WAIT_FOR_TEXT" -L agent.sock -t "$target" -p "$pattern" -T "$rem" -i "$interval" -l "$lines" >/dev/null 2>&1; then
  txt="$(capture)"
  echo "timeout: Codex input chrome not detected within ${timeout}s" >&2
  surface "$txt"
  exit 1
fi

# Phase 2: stability -- pane content hash unchanged for `stability` polls, the worker not
# still running, and (for exit 0) the result marker present.
log "phase 2/2: confirming pane stability for ${stability} polls..."
prev=""
quiet_for=0
while true; do
  if ! session_alive; then
    echo "session gone: $target_session no longer exists (worker crashed or session killed)" >&2
    exit 4
  fi

  txt="$(capture)"
  check_error "$txt"

  cur="$(printf '%s' "$txt" | hash_cmd | awk '{print $1}')"

  if [[ -n "$txt" && "$cur" == "$prev" ]]; then
    quiet_for=$(( quiet_for + 1 ))
    if (( quiet_for >= stability )); then
      # Order matters: check "still running" FIRST. While the worker executes, the pane
      # already contains the result-marker TEMPLATE echoed from the pasted prompt, so a
      # naive marker check would declare done prematurely. The running indicator gates
      # that out; only once it clears do we trust the marker as the worker's real block.
      if has_pat "$txt" "$running_pattern"; then
        quiet_for=0
      elif has_pat "$txt" "$result_marker"; then
        log "idle confirmed (result marker present)."
        surface "$txt"
        exit 0
      elif [[ -z "$result_marker" ]]; then
        log "idle confirmed (marker gating disabled)."
        surface "$txt"
        exit 0
      else
        log "pane quiet but result marker absent; completion unconfirmed."
        surface "$txt"
        exit 5
      fi
    fi
  else
    quiet_for=0
  fi
  prev="$cur"

  now=$(date +%s)
  if (( now >= deadline )); then
    echo "timeout: pane never reached a confirmed-idle state within ${timeout}s" >&2
    surface "$txt"
    exit 1
  fi

  sleep 1
done
