---
name: tmux
description: "Remote control tmux sessions for interactive CLIs (python, gdb, ssh, kubectl exec, etc.) by sending keystrokes and scraping pane output."
---

# tmux Skill

Use tmux as a programmable terminal multiplexer for interactive work. Works on Linux and macOS with stock tmux; avoid custom config by using a private socket.

## Quickstart (isolated socket)

```bash
# use slug-like session names; avoid spaces; make each session unique
SESSION=agent-python

# always use send-keys to run commands, never pass inline commands to new-session
tmux -L agent.sock new -d -s "$SESSION" -n shell
tmux -L agent.sock send-keys -t "$SESSION":0.0 -- 'python3 -q' Enter

# watch output
tmux -L agent.sock capture-pane -p -J -t "$SESSION":0.0 -S -200

# clean up
tmux -L agent.sock kill-session -t "$SESSION"
```

After starting a session ALWAYS tell the user how to monitor the session by giving them a command to copy paste:

```
To monitor this session yourself:
  tmux -L agent.sock attach -t agent-python

Or to capture the output once:
  tmux -L agent.sock capture-pane -p -J -t agent-python:0.0 -S -200
```

This must ALWAYS be printed right after a session was started and once again at the end of the tool loop. But the earlier you send it, the happier the user will be.

## Socket convention

- Agents MUST use `tmux -L agent.sock` so we can check/clean agent sessions.

## Targeting panes and naming

- Target format: `{session}:{window}.{pane}`, defaults to `:0.0` if omitted. Keep names short (e.g., `agent-py`, `agent-gdb`).
- Use `-L agent.sock` consistently to stay on the private socket path. If you need user config, drop `-f /dev/null`; otherwise `-f /dev/null` gives a clean config.
- Inspect: `tmux -L agent.sock list-sessions`, `tmux -L agent.sock list-panes -a`.

## Finding sessions

- List sessions on your active socket with metadata: `tmux -L agent.sock list-sessions`.

## Sending input safely

- Prefer literal sends to avoid shell splitting: `tmux -L agent.sock send-keys -t target -l -- "$cmd"`. In case you need to append control keys afterwards - combine commands via `&&`: `tmux -L agent.sock send-keys -t target -l -- "$cmd" && tmux -L agent.sock send-keys -t target Enter`.
- When composing inline commands, use single quotes or ANSI C quoting to avoid expansion: `tmux -L agent.sock send-keys -t target -- $'python3 -m http.server 8000'`.
- To send control keys: `tmux -L agent.sock send-keys -t target C-c`, `C-d`, `C-z`, `Escape`, etc.

## Watching output

- Capture recent history (joined lines to avoid wrapping artifacts): `tmux -L agent.sock capture-pane -p -J -t target -S -200`.
- For continuous monitoring, poll with the helper script (below) instead of `tmux wait-for` (which does not watch pane output).
- You can also temporarily attach to observe: `tmux -L agent.sock attach -t "$SESSION"`; detach with `Ctrl+b d`.
- When giving instructions to a user, **explicitly print a copy/paste monitor command** alongside the action don't assume they remembered the command.

## Spawning Processes

Some special rules for processes:

- when asked to debug, use lldb by default
- when starting a python interactive shell, always set the `PYTHON_BASIC_REPL=1` environment variable. This is very important as the non-basic console interferes with your send-keys.

## Synchronizing / waiting for prompts

- Use timed polling to avoid races with interactive tools. Example: wait for a Python prompt before sending code:
  ```bash
  ./scripts/wait-for-text.sh -t "$SESSION":0.0 -p '^>>>' -T 15 -l 4000
  ```
- For long-running commands, poll for completion text (`"Type quit to exit"`, `"Program exited"`, etc.) before proceeding.

## Interactive tool recipes

- **Python REPL**: `tmux -L agent.sock send-keys -- 'python3 -q' Enter`; wait for `^>>>`; send code with `-l`; interrupt with `C-c`. Always with `PYTHON_BASIC_REPL`.
- **gdb**: `tmux -L agent.sock send-keys -- 'gdb --quiet ./a.out' Enter`; disable paging `tmux -L agent.sock send-keys -- 'set pagination off' Enter`; break with `C-c`; issue `bt`, `info locals`, etc.; exit via `quit` then confirm `y`.
- **Other TTY apps** (ipdb, psql, mysql, node, bash, ssh): same pattern—start the program, poll for its prompt, then send literal text and Enter.

## Cleanup

- Kill a session when done: `tmux -L agent.sock kill-session -t "$SESSION"`.
- Kill all sessions on a socket: `tmux -L agent.sock list-sessions -F '#{session_name}' | xargs -r -n1 tmux -L agent.sock kill-session -t`.
- Remove everything on the private socket: `tmux -L agent.sock kill-server`.

## Helper: wait-for-text.sh

`./scripts/wait-for-text.sh` polls a pane for a regex (or fixed string) with a timeout. Works on Linux/macOS with bash + tmux + grep.

```bash
./scripts/wait-for-text.sh -t session:0.0 -p 'pattern' [-F] [-T 20] [-i 0.5] [-l 2000]
```

- `-t`/`--target` pane target (required)
- `-p`/`--pattern` regex to match (required); add `-F` for fixed string
- `-T` timeout seconds (integer, default 15)
- `-i` poll interval seconds (default 0.5)
- `-l` history lines to search from the pane (integer, default 1000)
- Exits 0 on first match, 1 on timeout. On failure prints the last captured text to stderr to aid debugging.
