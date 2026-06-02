---
name: codex-cli-execution
description: Use when the user invokes /codex-cli-execution or asks Claude to drive Codex CLI's interactive yolo TUI as a worker via tmux while Claude supervises paste, polling, evaluation, and follow-up correction.
---

# codex-cli-execution

Drive Codex CLI's interactive `--yolo` TUI inside a tmux pane while Claude supervises. Codex is the worker; Claude is the supervisor. Claude shapes the prompt, pastes it, polls Codex's output, surfaces problems to the user, evaluates the result, and either delegates a correction back to Codex or — only as a last resort — takes over directly.

This skill exists because none of the other Codex paths (`codex:rescue`'s JSON-RPC, `codex-subagents`'s one-shot `codex e`) drive the interactive TUI. tmux is the integration surface here.

## Required / referenced skills

| Role | Skill | Use |
|---|---|---|
| REQUIRED | `tmux` (`~/.claude/skills/tmux/SKILL.md`) | All tmux primitives. Do not duplicate. |
| OPTIONAL | `iterm` (`~/.claude/skills/iterm/SKILL.md`) | macOS live monitoring window. Detect `osascript`; skip silently if missing. |
| REFERENCE | `codex:gpt-5-4-prompting` | Prompt-shaping conventions for Step 1. |
| REFERENCE | `codex:codex-result-handling` | Output preservation discipline for Step 7. |

## Mental model

- **Claude = supervisor (master).** Reads pane, reasons, decides, talks to user.
- **Codex `--yolo` TUI = worker (slave).** Executes blindly inside the tmux pane. Claude does **not** edit files Codex is responsible for.
- Take-over rule: only if Codex refuses, is stuck after **two** corrective follow-ups, or explicitly asks for the user.

## Pre-flight

```bash
command -v codex >/dev/null || echo "codex not in PATH"
command -v tmux  >/dev/null || echo "tmux not in PATH"
tmux -L agent.sock list-sessions 2>/dev/null | grep -E '^codex-exec-' || true
```

**Warn the user loudly that `codex --yolo` runs unsandboxed — it can read/write/delete anything reachable from the working directory.**

## Workflow

### Step 1 — Refine the prompt

Take `$ARGUMENTS` (or the user's intent) and shape it for Codex using the `codex:gpt-5-4-prompting` XML-block conventions. Add at minimum:

- `<task>` — concrete job + relevant repo/failure context
- workspace path (`pwd`)
- success criteria ("done when X")
- target file scope and write/read mode
- `<verification_loop>` if Codex must self-check before stopping
- **A required final result block** so the supervisor reads dense signal instead of capturing scrollback. Instruct Codex to end its run by printing exactly:

  ```
  === CODEX RESULT ===
  verdict: success|partial|failure
  touched: <files>
  verified: <how / pass|fail>
  notes: <1–2 lines>
  === END ===
  ```

Show the refined prompt to the user. Ask: **approve / edit / skip**. Only proceed once they approve.

### Step 2 — Spawn the session

```bash
SESSION="codex-exec-$(date +%H%M%S)"
tmux -L agent.sock new -d -s "$SESSION" -n codex
```

Optionally compose the `iterm` skill to open a visible window attached to `$SESSION` (skip silently if not on macOS / `osascript` missing).

**Immediately print to the user** (per the tmux skill's monitor-command rule):

```
Codex session: $SESSION
  Watch live:  tmux -L agent.sock attach -t $SESSION
  Snapshot:    tmux -L agent.sock capture-pane -p -J -t $SESSION:0.0 -S -200
  Kill:        tmux -L agent.sock kill-session -t $SESSION
```

### Step 3 — Launch Codex

```bash
tmux -L agent.sock send-keys -t "$SESSION":0.0 -l -- "codex --yolo"
tmux -L agent.sock send-keys -t "$SESSION":0.0 Enter
```

Wait for the input chrome to appear (Step 5 helper handles this). Do **not** paste before chrome is verified — early input is dropped or fed to a startup splash.

### Step 4 — Paste the refined prompt

Multi-line content MUST go through buffer paste, never raw `send-keys`:

```bash
printf '%s' "$REFINED_PROMPT" | tmux -L agent.sock load-buffer -
tmux -L agent.sock paste-buffer -t "$SESSION":0.0
```

Verify the prompt landed:

```bash
tmux -L agent.sock capture-pane -p -J -t "$SESSION":0.0 -S -200 | tail -n 40
```

If it looks right, submit:

```bash
tmux -L agent.sock send-keys -t "$SESSION":0.0 Enter
```

### Step 5 — Supervise

Run the bundled helper as a **background Bash task** (`run_in_background: true`) — never as a blocking foreground call:

```bash
bash "$HOME/.claude/skills/codex-cli-execution/scripts/wait-for-codex-idle.sh" \
  -t "$SESSION":0.0 -T 600 --result-marker '=== CODEX RESULT ==='
```

It composes the tmux skill's `wait-for-text.sh` for the input-chrome regex and adds a SHA-stability check. Exit codes: `0` idle / `1` timeout / `2` error keyword detected / `3` bad args.

**Why background:** the helper polls `capture-pane` internally (2000 lines/poll) but those captures stay inside the bash process — only its final output (≤80 lines, or the `=== CODEX RESULT ===` block) ever reaches Claude. Run in the *foreground* it gets killed by the Bash tool's 2-min default timeout (the status-line regex matches instantly, so the helper sits in the stability loop, and the pane never stabilizes while Codex works), which forces you into ad-hoc `capture-pane` polling that floods the context. Background-launched, the helper owns its own `-T` lifetime and the harness re-invokes you with its output **once, on exit**.

- **Do NOT manually `capture-pane` while the helper is running** — it is the only progress signal. Repeated live-TUI captures are the single biggest context sink.
- **Do NOT `ScheduleWakeup`-poll your own helper:** background Bash is harness-tracked, so the harness notifies you automatically when it exits. (A long wait costs one prompt-cache miss on re-invoke — a latency/cost cost, not a context cost, and far cheaper than the captures it replaces.) Reserve `ScheduleWakeup` for genuinely external waits; if ever used, its status check must be a bounded grepped/tailed capture, never a raw dump.
- **On exit:** `0` → idle, read the surfaced result block; `1` → timeout: if Codex is still active, relaunch the background helper (each relaunch surfaces ≤80 lines; raise `-T` for known-long tasks); `2` → error keyword: surface to the user immediately.

The helper surfaces any line matching `error:|denied|permission|command failed|refused` on its error-exit path — relay those to the user; don't paper over.

### Step 6 — Detect completion

The helper's exit `0` (delivered via the background-task completion notification) is the completion signal: input chrome visible AND pane content stable for ≥3s. The helper surfaces the `=== CODEX RESULT ===` block when present, else the last 80 lines — reason about what Codex did from that, not from a fresh capture.

### Step 7 — Evaluate

Evaluate from **ground truth + the result block the helper already surfaced** — do not re-capture the pane. Cross-check Codex's claims:

```bash
git status --porcelain
git diff --stat
```

(add `git diff` when you need a closer look). If — and only if — you must re-read scrollback (e.g. to find an early denial the result block omitted), filter it so only relevant lines surface; never pull a raw 2000-line dump into context:

```bash
tmux -L agent.sock capture-pane -p -J -t "$SESSION":0.0 -S -2000 \
  | grep -E 'error:|denied|permission|command failed|refused' | tail -n 30
```

Apply `codex:codex-result-handling` discipline: preserve Codex's verdict/findings/touched-files structure when reporting back to the user; don't auto-apply fixes from a review-style output.

Decide: **success / partial / failure**.

### Step 8 — Follow up

Default = **delegate**. Compose a corrective prompt and loop back to Step 4 (paste + submit again) on the **same** session. After the second failed correction, surface the situation to the user and ask whether to take over manually. Take-over is the exception, not the default.

### Step 9 — Teardown

**Default: leave the session running.** Re-print the monitor + kill commands from Step 2. Only run `tmux -L agent.sock kill-session -t "$SESSION"` after explicit user confirmation.

## Hard constraints

1. Always `tmux -L agent.sock`. Never the default socket.
2. Never edit files Codex is responsible for. Delegate corrections, don't intervene.
3. Never paste before the input chrome is verified.
4. Never raw `send-keys` for multi-line content — always `load-buffer` + `paste-buffer`.
5. Always print the monitor command at spawn AND at end of turn.
6. Run the Step 5 supervise helper as a background Bash task (`run_in_background`) and rely on the harness completion notification. Never busy-poll the pane while it runs, and never `ScheduleWakeup`-poll your own background helper.
7. Surface Codex denials / errors / refusals to the user immediately.
8. Don't `capture-pane` outside Steps 4 (paste verify) and 7 (evaluate). Never `capture-pane` while the Step 5 helper runs — the background helper is the only progress signal. Step 7 scrollback reads must be `grep`/`tail`-filtered.
9. Per-invocation session names (`codex-exec-HHMMSS`) — never collide with existing sessions.

## Codex TUI sentinel regex

The helper's default `-p` covers both modern and legacy Codex CLI chrome:

```
^›|gpt-[0-9]+\.[0-9]+ \w+|YOLO mode|▌ Send a message|esc to interrupt|tokens used|↑/↓ history
```

The first three alternatives (the input-arrow `›`, the `gpt-X.Y <variant>` status line, and the `YOLO mode` boot banner) match Codex CLI v0.128+. The remainder preserves compatibility with older v0.x chrome. If a future build replaces these too, capture the pane post-boot and override via `-p`.

## Common mistakes

| Mistake | Fix |
|---|---|
| Raw `send-keys` for multi-line prompt | Always pipe through `load-buffer` then `paste-buffer`. |
| Paste before Codex's input is ready | Wait via the helper script first. |
| Blocking/foreground supervise call, or busy-polling the pane | Launch the Step 5 helper with `run_in_background`; the harness notifies you on exit. Never `ScheduleWakeup`-poll your own helper. |
| Manually `capture-pane` to watch progress while the helper runs | Forbidden — the background helper is the only progress signal; repeated live-TUI captures are the #1 context sink. |
| Claude jumping in to edit files Codex was meant to handle | Delegate a follow-up paste instead; take-over only after 2 failures. |
| Killing the session before user inspects | Default to leave-running; require explicit confirmation to kill. |
| Skipping monitor-command print at spawn | tmux-skill rule — always print it, twice. |
| Capturing scrollback with `-S -200` and missing earlier denials | Capture `-S -2000` but always pipe through `grep`/`tail`; never surface a raw 2000-line dump into context. Or launch Codex with `--no-alt-screen` if the build supports it (trade-off: TUI renders less cleanly). |

## Out of scope (v1)

- Resuming a prior Codex thread (each invocation = fresh session). Future work: an optional `--resume` flag on the slash command.
- Multi-worker pool orchestration (parallel Codex workers under one supervisor with shared state). Single-session only.
