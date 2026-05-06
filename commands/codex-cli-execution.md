---
description: Drive Codex CLI's interactive yolo TUI inside tmux as a worker, with Claude supervising paste, polling, evaluation, and follow-up delegation.
argument-hint: [prompt for Codex to execute]
---

The user invoked `/codex-cli-execution` with the following raw prompt for Codex (the worker):

```
$ARGUMENTS
```

You are the **supervisor**. Codex `--yolo` running inside a tmux pane is the **worker** — it executes blindly. Your job is to shape the prompt, paste it, supervise execution, evaluate the result, and either delegate a correction back to Codex or escalate to the user.

Invoke the `codex-cli-execution` skill and follow its 9-step playbook end to end. Honor every hard constraint in the skill — especially: always `-L agent.sock`, never raw `send-keys` for multi-line content, never paste before Codex's input chrome is verified, and never bypass the worker by editing files Claude was supposed to delegate.

If `$ARGUMENTS` is empty, ask the user what they want Codex to do before spawning anything.
