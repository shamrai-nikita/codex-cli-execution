#!/usr/bin/env bash
set -euo pipefail

# install.sh — copy the codex-cli-execution skill + slash command into ~/.claude/
#
# Idempotent. Refuses to clobber existing files unless --force is passed.
# Run from the repo root.

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--force] [--prefix DIR] [--symlink]

  --force        overwrite existing files at the destination
  --prefix DIR   install into DIR/.claude instead of $HOME/.claude
  --symlink      install as symlinks (good for development; tracks repo edits)
  -h, --help     show this help
USAGE
}

force=0
symlink=0
prefix="$HOME"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   force=1; shift ;;
    --symlink) symlink=1; shift ;;
    --prefix)  prefix="${2-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src_cmd="$repo_root/commands/codex-cli-execution.md"
src_skill_dir="$repo_root/skills/codex-cli-execution"
src_tmux_dir="$repo_root/skills/tmux"

claude_dir="$prefix/.claude"
dst_cmd="$claude_dir/commands/codex-cli-execution.md"
dst_skill_dir="$claude_dir/skills/codex-cli-execution"
dst_tmux_dir="$claude_dir/skills/tmux"

# Sanity checks
[[ -f "$src_cmd" ]]       || { echo "missing: $src_cmd"       >&2; exit 1; }
[[ -d "$src_skill_dir" ]] || { echo "missing: $src_skill_dir" >&2; exit 1; }
[[ -d "$src_tmux_dir" ]]  || { echo "missing: $src_tmux_dir"  >&2; exit 1; }

mkdir -p "$claude_dir/commands" "$claude_dir/skills"

install_one() {
  local src="$1" dst="$2"
  if [[ -e "$dst" || -L "$dst" ]]; then
    if (( force )); then
      rm -rf "$dst"
    else
      echo "skip (exists): $dst"
      echo "  pass --force to overwrite"
      return 0
    fi
  fi
  if (( symlink )); then
    ln -s "$src" "$dst"
    echo "linked: $dst -> $src"
  else
    if [[ -d "$src" ]]; then
      cp -R "$src" "$dst"
    else
      cp "$src" "$dst"
    fi
    echo "copied: $dst"
  fi
}

install_one "$src_cmd"       "$dst_cmd"
install_one "$src_skill_dir" "$dst_skill_dir"
install_one "$src_tmux_dir"  "$dst_tmux_dir"

# Ensure helpers are executable (cp -R preserves mode but be explicit)
for helper in \
  "$dst_skill_dir/scripts/wait-for-codex-idle.sh" \
  "$dst_tmux_dir/scripts/wait-for-text.sh"
do
  [[ -e "$helper" ]] && chmod +x "$helper" 2>/dev/null || true
done

echo
echo "Done. In Claude Code, try:"
echo "  /codex-cli-execution write a failing test for X then make it pass"
