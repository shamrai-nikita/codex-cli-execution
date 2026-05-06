#!/usr/bin/env bash
set -euo pipefail

# wait-for-codex-idle.sh
# Polls a Codex CLI TUI pane on the agent.sock socket until it appears idle.
#
# Idle = (a) the input chrome regex is visible, AND
#        (b) the pane content hash is stable across two captures `-s` seconds apart.
#
# Composes on top of ~/.claude/skills/tmux/scripts/wait-for-text.sh for (a).
# Implements stability check (b) inline with sha1.
#
# Exit codes:
#   0  idle (Codex returned to its input chrome and pane is quiet)
#   1  timeout
#   2  error keyword detected in pane (likely Codex denial / failure)
#   3  bad args / preconditions

usage() {
  cat <<'USAGE'
Usage: wait-for-codex-idle.sh -t target [options]

Wait until a Codex --yolo TUI pane goes idle.

Required:
  -t, --target       tmux target, e.g. codex-exec-093015:0.0

Options:
  -T, --timeout      total seconds to wait (default: 600)
  -p, --pattern      regex matching Codex input chrome
                     (default: '▌ Send a message|esc to interrupt|tokens used|↑/↓ history')
  -s, --stability    seconds the pane hash must stay constant after chrome appears (default: 3)
  -e, --error-regex  regex of failure keywords; if matched, exit 2
                     (default: 'error:|denied|permission|command failed|refused')
  -l, --lines        history lines to capture (default: 2000)
  -i, --interval     poll interval seconds passed to wait-for-text.sh (default: 0.5)
  -q, --quiet        suppress info logging (errors still go to stderr)
  -h, --help         show this help

Notes:
  - Always uses the agent.sock private socket (`tmux -L agent.sock`).
  - Composes the tmux skill's wait-for-text.sh for the chrome match.
  - Prints the last 80 lines of the pane to stdout on success so the caller
    can read what Codex finished with.
USAGE
}

target=""
timeout=600
pattern='▌ Send a message|esc to interrupt|tokens used|↑/↓ history'
stability=3
error_regex='error:|denied|permission|command failed|refused'
lines=2000
interval=0.5
quiet=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)      target="${2-}"; shift 2 ;;
    -T|--timeout)     timeout="${2-}"; shift 2 ;;
    -p|--pattern)     pattern="${2-}"; shift 2 ;;
    -s|--stability)   stability="${2-}"; shift 2 ;;
    -e|--error-regex) error_regex="${2-}"; shift 2 ;;
    -l|--lines)       lines="${2-}"; shift 2 ;;
    -i|--interval)    interval="${2-}"; shift 2 ;;
    -q|--quiet)       quiet=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 3 ;;
  esac
done

[[ -z "$target" ]] && { echo "target is required" >&2; usage; exit 3; }

for n in timeout stability lines; do
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

# Resolve the tmux skill's wait-for-text.sh helper.
WAIT_FOR_TEXT="${WAIT_FOR_TEXT:-$HOME/.claude/skills/tmux/scripts/wait-for-text.sh}"
[[ -x "$WAIT_FOR_TEXT" ]] || { echo "wait-for-text.sh not executable at $WAIT_FOR_TEXT" >&2; exit 3; }

start_epoch=$(date +%s)
deadline=$((start_epoch + timeout))

capture() {
  tmux -L agent.sock capture-pane -p -J -t "$target" -S "-${lines}" 2>/dev/null || true
}

remaining() { echo $(( deadline - $(date +%s) )); }

check_error() {
  local txt="$1"
  if printf '%s\n' "$txt" | grep -E -- "$error_regex" >/dev/null 2>&1; then
    log "error keyword matched: $error_regex"
    printf '%s\n' "$txt" | tail -n 80
    exit 2
  fi
}

# Phase 1: wait for input chrome to appear.
rem=$(remaining)
(( rem > 0 )) || { echo "timeout before chrome wait started" >&2; exit 1; }
log "phase 1/2: waiting up to ${rem}s for Codex input chrome..."

if ! "$WAIT_FOR_TEXT" -t "$target" -p "$pattern" -T "$rem" -i "$interval" -l "$lines" >/dev/null 2>&1; then
  txt="$(capture)"
  echo "timeout: Codex input chrome not detected within ${timeout}s" >&2
  printf '%s\n' "$txt" | tail -n 80 >&2
  exit 1
fi

# Phase 2: stability — pane content hash must be unchanged for `stability` seconds.
log "phase 2/2: confirming pane stability for ${stability}s..."
prev=""
quiet_for=0
while true; do
  txt="$(capture)"
  check_error "$txt"

  cur="$(printf '%s' "$txt" | hash_cmd | awk '{print $1}')"

  if [[ "$cur" == "$prev" && -n "$cur" ]]; then
    quiet_for=$(( quiet_for + 1 ))
    if (( quiet_for >= stability )); then
      log "idle confirmed."
      printf '%s\n' "$txt" | tail -n 80
      exit 0
    fi
  else
    quiet_for=0
  fi
  prev="$cur"

  now=$(date +%s)
  if (( now >= deadline )); then
    echo "timeout: pane never stabilized within ${timeout}s" >&2
    printf '%s\n' "$txt" | tail -n 80 >&2
    exit 1
  fi

  sleep 1
done
