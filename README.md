# codex-cli-execution

A Claude Code skill + slash command that lets **Claude supervise [Codex CLI](https://github.com/openai/codex) running in interactive `--yolo` mode inside a tmux pane**, with bidirectional control: Claude shapes the prompt, pastes it, polls the TUI, surfaces problems, evaluates the result, and either delegates a corrective follow-up to Codex or — only as a last resort — takes over directly.

> Claude = supervisor (master). Codex `--yolo` TUI = worker (slave) that executes blindly. The integration surface is a private tmux socket.

This is a different mechanism from OpenAI's existing Codex Claude Code plugin paths:

| Path | Mechanism | What it can do |
|---|---|---|
| `codex:rescue` (OpenAI plugin) | JSON-RPC `codex app-server` | One-shot programmatic call; no TUI |
| `codex-subagents` MCP | One-shot `codex e` exec mode | Parallel one-shots; no TUI |
| **this skill** | **tmux-driven interactive `codex --yolo`** | **Live conversation with Codex; multi-turn corrections** |

## Why?

Sometimes you want the *interactive* Codex experience — multi-turn back-and-forth, tool denials surfaced in real time, the ability to nudge Codex mid-task — but you also want Claude orchestrating it: shaping prompts, watching for failures, sending follow-ups, and reporting back. This skill packages that pattern as a single slash command.

## How it works

1. **Refine** — Claude reviews your raw prompt, tightens it (workspace path, success criteria, file scope, write/read mode) using the `codex:gpt-5-4-prompting` XML conventions, and asks you to approve / edit / skip before pasting.
2. **Spawn** — A unique `codex-exec-HHMMSS` session is created on the private `agent.sock` socket. Claude prints the live monitor + kill commands immediately.
3. **Launch** — `codex --yolo` is started in the pane. Claude waits for the input chrome to appear before pasting (via the `wait-for-codex-idle.sh` helper).
4. **Paste** — Multi-line content goes through `tmux load-buffer | paste-buffer` — never raw `send-keys` — so quoting and triple-backticks survive intact.
5. **Supervise** — A poller waits for two conditions before declaring Codex idle: input chrome visible *and* pane content hash stable for ≥3 s. Errors / denials / refusals are surfaced to the user immediately. For runs likely to exceed ~5 minutes, Claude switches to `ScheduleWakeup(270 s)` to stay inside the prompt-cache TTL.
6. **Evaluate** — Claude reads the pane tail, cross-checks Codex's claims with `git status` / `git diff --stat`, and decides success / partial / failure.
7. **Follow up** — Default = **delegate**: Claude composes a corrective prompt and pastes it back into the same Codex session. Take-over is the exception, not the default.
8. **Teardown** — Default = **leave the session running** so you can inspect the pane afterwards. Re-prints the kill command. Only kills on explicit confirmation.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex` on `PATH`)
- `tmux` (1.9+ recommended) and `bash` 4+
- `shasum` *or* `sha1sum` (macOS ships `shasum`; most Linux distros ship `sha1sum`)
- The [`tmux` skill](https://github.com/anthropics/skills) for Claude Code installed at `~/.claude/skills/tmux/` — the helper script in this repo composes on top of `~/.claude/skills/tmux/scripts/wait-for-text.sh`. If your `wait-for-text.sh` lives elsewhere, set the env var `WAIT_FOR_TEXT=/path/to/wait-for-text.sh`.

Optional:

- The `iterm` skill (macOS only) — used silently if present to open a visible window attached to the agent's tmux session.
- The `codex:gpt-5-4-prompting` and `codex:codex-result-handling` skills from OpenAI's Codex plugin — referenced for prompt shaping and output discipline, not required.

## Installation

### Option A — installer (recommended)

```bash
git clone https://github.com/shamrai-nikita/codex-cli-execution.git
cd codex-cli-execution
./install.sh
```

The installer copies the three files into `~/.claude/`, preserves the executable bit on the helper script, and refuses to clobber pre-existing files unless you pass `--force`.

### Option B — manual

```bash
mkdir -p ~/.claude/skills/codex-cli-execution/scripts ~/.claude/commands
cp commands/codex-cli-execution.md ~/.claude/commands/
cp skills/codex-cli-execution/SKILL.md ~/.claude/skills/codex-cli-execution/
cp skills/codex-cli-execution/scripts/wait-for-codex-idle.sh \
   ~/.claude/skills/codex-cli-execution/scripts/
chmod +x ~/.claude/skills/codex-cli-execution/scripts/wait-for-codex-idle.sh
```

### Option C — symlink (for development)

If you'd like to hack on the skill in place:

```bash
git clone https://github.com/shamrai-nikita/codex-cli-execution.git
ln -s "$PWD/codex-cli-execution/commands/codex-cli-execution.md" \
      ~/.claude/commands/codex-cli-execution.md
ln -s "$PWD/codex-cli-execution/skills/codex-cli-execution" \
      ~/.claude/skills/codex-cli-execution
```

## Usage

In a Claude Code session:

```
/codex-cli-execution write a failing test for the date-parsing edge case in src/parser.ts then make it pass
```

What happens next:

1. Claude shows you a refined version of the prompt and asks approve / edit / skip.
2. On approve, you'll see something like:

   ```
   Codex session: codex-exec-093015
     Watch live:  tmux -L agent.sock attach -t codex-exec-093015
     Snapshot:    tmux -L agent.sock capture-pane -p -J -t codex-exec-093015:0.0 -S -200
     Kill:        tmux -L agent.sock kill-session -t codex-exec-093015
   ```

3. Codex runs. Claude polls in the background and surfaces any errors, denials, or refusals to you in real time.
4. When Codex goes idle, Claude reads the result, spot-checks the diff, and either reports success or delegates a corrective follow-up.
5. Session is left running on completion so you can inspect it. Run the kill command yourself when you're done.

You can also just say *"drive Codex via tmux to do X"* — the skill is model-invocable, so Claude will pick it up from intent.

### Open multiple Codex workers

Each invocation gets a unique session name, so calling the slash command twice in a row spawns two independent Codex workers you can supervise in parallel. (For full multi-worker pool orchestration with state tracking, see [icon-orchestrator-v2](#related-prior-art) — out of scope here.)

## Configuration

The helper accepts these flags (full list: `wait-for-codex-idle.sh -h`):

| Flag | Default | Purpose |
|---|---|---|
| `-t` | required | tmux target, e.g. `codex-exec-093015:0.0` |
| `-T` | `600` | total seconds before timeout |
| `-p` | `▌ Send a message\|esc to interrupt\|tokens used\|↑/↓ history` | input-chrome regex |
| `-s` | `3` | seconds the pane hash must stay stable |
| `-e` | `error:\|denied\|permission\|command failed\|refused` | error-keyword regex (exit 2 on match) |
| `-l` | `2000` | history lines to capture |
| `-i` | `0.5` | poll interval (passed through to `wait-for-text.sh`) |

**Sentinel regex may need tightening on first run.** Codex versions can change the TUI chrome. If detection misfires:

```bash
# capture the pane right after `codex --yolo` boots and find a stable line
tmux -L agent.sock capture-pane -p -J -t codex-exec-XXXXXX:0.0 -S -200
```

Then override the SKILL.md default by editing `skills/codex-cli-execution/SKILL.md` Step 5 to pass your own `-p`.

`WAIT_FOR_TEXT` env var overrides the path to the upstream `wait-for-text.sh` helper.

## Caveats

- **`codex --yolo` is unsandboxed.** It can read, write, and delete anything reachable from the working directory. The skill prints a loud warning at spawn time, but you should still launch it in a directory where that's acceptable.
- **macOS-only iTerm composition** — the live-window step is skipped silently on Linux / when `osascript` isn't available. Headless tmux supervision works everywhere.
- **TUI alt-screen scrollback** — Codex's TUI uses an alt-screen by default, which can hide earlier output when the pane scrolls. The skill captures `-S -2000` for evaluation. If you need full scrollback, launch Codex with `--no-alt-screen` (trade-off: less clean rendering).
- **No session resume** in v1. Each `/codex-cli-execution` spawns a fresh session. Resume is on the roadmap.

## Files in this repo

```
.
├── README.md
├── LICENSE                                              # MIT
├── install.sh                                           # idempotent installer
├── commands/
│   └── codex-cli-execution.md                          # slash command entry
└── skills/
    └── codex-cli-execution/
        ├── SKILL.md                                     # the playbook
        └── scripts/
            └── wait-for-codex-idle.sh                  # idle-detection helper
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `wait-for-text.sh not executable at ...` | tmux skill not installed at the expected path | Install the [tmux skill](https://github.com/anthropics/skills), or set `WAIT_FOR_TEXT` env var |
| Helper exits 1 immediately | Codex never showed input chrome (e.g. auth error) | Attach to the session: `tmux -L agent.sock attach -t <session>` and look at the actual pane |
| Helper exits 2 mid-run | Caught a default error keyword (`error:` / `denied` / etc.) | Read the last 80 lines printed; check whether it's a real failure or a benign log line, override `-e` if needed |
| Multi-line prompt arrived mangled | Something used `send-keys` instead of `load-buffer | paste-buffer` | Skill should never do this; if it did, please open an issue |
| `tmux: server not found` errors | Stale `agent.sock` socket | `tmux -L agent.sock kill-server` and retry |

## Related / prior art

- **[OpenAI's Codex Claude Code plugin](https://github.com/openai/codex)** — provides `codex:rescue`, `codex:setup`, and the `codex-companion` JSON-RPC runtime. Different mechanism (no TUI).
- **`codex-subagents`** ([codex-as-mcp](https://github.com/shyamz-22/codex-as-mcp) and forks) — orchestrates parallel Codex subagents via one-shot `codex e`. Useful when you need fan-out, not interactive.
- **`icon-orchestrator-v2`** — a multi-worker pool variant with `state.json`, `cycle.sh`, and `ScheduleWakeup(240s)`-paced supervision. The reusable mental model behind this skill, scaled down to single-session.

## Contributing

Issues and PRs welcome. The skill follows the [superpowers writing-skills](https://github.com/obra/superpowers) TDD discipline — if you change behavior, please describe the failing test scenario you observed without your change.

## License

MIT — see [LICENSE](LICENSE).
