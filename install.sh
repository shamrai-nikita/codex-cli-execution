#!/usr/bin/env bash
set -euo pipefail

# install.sh — copy the codex-cli-execution skill + slash command into ~/.claude/
#
# Verifies system prerequisites (and auto-installs tmux on macOS / common Linux
# distros if it's missing) before copying skill files.
#
# Idempotent. Refuses to clobber existing files unless --force is passed.
# Run from the repo root.

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

  --force              overwrite existing files at the destination
  --prefix DIR         install into DIR/.claude instead of $HOME/.claude
  --symlink            install as symlinks (good for development; tracks repo edits)
  --no-install-deps    don't auto-install tmux if it's missing; print the
                       install command and exit 1 instead
  --skip-deps          skip dependency checks entirely (advanced; you accept
                       responsibility that everything is in place)
  -h, --help           show this help

By default the installer:
  1. Verifies prerequisites (codex CLI, tmux, shasum/sha1sum).
  2. Auto-installs tmux via Homebrew (macOS) or apt/dnf/yum/pacman/apk/zypper
     (Linux) if it's missing. sudo will be invoked if you're not root.
  3. Copies the skill, the bundled tmux skill, and the slash command into
     ~/.claude/ (or $PREFIX/.claude if --prefix is given).
USAGE
}

force=0
symlink=0
prefix="$HOME"
install_deps=1
check_deps=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)            force=1; shift ;;
    --symlink)          symlink=1; shift ;;
    --prefix)           prefix="${2-}"; shift 2 ;;
    --no-install-deps)  install_deps=0; shift ;;
    --skip-deps)        check_deps=0; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

# ---------- dependency handling ----------

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "other" ;;
  esac
}

detect_linux_pm() {
  for pm in apt-get dnf yum pacman apk zypper; do
    if command -v "$pm" >/dev/null 2>&1; then
      echo "$pm"; return 0
    fi
  done
  return 1
}

run_priv() {
  # Run a command as root (or via sudo if we're not root and sudo exists).
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    err "need root or sudo to run: $*"
    return 1
  fi
}

tmux_install_command() {
  case "$(detect_os)" in
    macos) echo "brew install tmux" ;;
    linux)
      local pm; pm="$(detect_linux_pm)" || { echo ""; return 1; }
      case "$pm" in
        apt-get) echo "apt-get update && apt-get install -y tmux" ;;
        dnf|yum) echo "$pm install -y tmux" ;;
        pacman)  echo "pacman -S --noconfirm tmux" ;;
        apk)     echo "apk add tmux" ;;
        zypper)  echo "zypper --non-interactive install tmux" ;;
      esac
      ;;
    *) echo "" ;;
  esac
}

install_tmux_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    err "tmux is missing and Homebrew (brew) is not installed."
    err "Install Homebrew (https://brew.sh) and re-run, or install tmux another way."
    return 1
  fi
  log "Installing tmux via Homebrew..."
  brew install tmux
}

install_tmux_linux() {
  local pm
  if ! pm="$(detect_linux_pm)"; then
    err "no supported package manager found (tried apt-get, dnf, yum, pacman, apk, zypper)"
    err "install tmux manually and re-run with --skip-deps"
    return 1
  fi
  case "$pm" in
    apt-get)
      log "Installing tmux via apt-get..."
      run_priv apt-get update
      run_priv apt-get install -y tmux ;;
    dnf|yum)
      log "Installing tmux via $pm..."
      run_priv "$pm" install -y tmux ;;
    pacman)
      log "Installing tmux via pacman..."
      run_priv pacman -S --noconfirm tmux ;;
    apk)
      log "Installing tmux via apk..."
      run_priv apk add tmux ;;
    zypper)
      log "Installing tmux via zypper..."
      run_priv zypper --non-interactive install tmux ;;
  esac
}

ensure_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    log "  tmux:    $(command -v tmux) ($(tmux -V 2>/dev/null || echo unknown))"
    return 0
  fi
  if (( ! install_deps )); then
    local cmd; cmd="$(tmux_install_command || true)"
    err "tmux is missing and --no-install-deps was passed."
    if [[ -n "$cmd" ]]; then
      err "Run this and re-execute the installer:"
      err "  $cmd"
    else
      err "Install tmux via your package manager and re-execute the installer."
    fi
    return 1
  fi
  case "$(detect_os)" in
    macos) install_tmux_macos ;;
    linux) install_tmux_linux ;;
    *)
      err "tmux is missing on an unsupported OS ($(uname -s))."
      err "Install it manually and re-run with --skip-deps."
      return 1 ;;
  esac
  command -v tmux >/dev/null 2>&1 || { err "tmux install attempt did not put tmux on PATH."; return 1; }
  log "  tmux:    $(command -v tmux) ($(tmux -V 2>/dev/null || echo unknown))"
}

ensure_hash_tool() {
  if command -v shasum >/dev/null 2>&1; then
    log "  shasum:  $(command -v shasum)"
    return 0
  fi
  if command -v sha1sum >/dev/null 2>&1; then
    log "  sha1sum: $(command -v sha1sum)"
    return 0
  fi
  err "neither shasum nor sha1sum found in PATH."
  err "Install one (most distros ship coreutils with sha1sum) and re-run."
  return 1
}

ensure_codex() {
  if command -v codex >/dev/null 2>&1; then
    log "  codex:   $(command -v codex)"
    return 0
  fi
  err "codex CLI not found in PATH. The skill cannot run without it."
  err "Install Codex CLI from https://github.com/openai/codex and re-run."
  err "(Pass --skip-deps to install skill files anyway.)"
  return 1
}

check_claude() {
  if command -v claude >/dev/null 2>&1; then
    log "  claude:  $(command -v claude)"
  else
    warn "claude CLI not found in PATH. Skill files will install, but the slash"
    warn "command can only be invoked from inside Claude Code."
  fi
}

if (( check_deps )); then
  log "Checking dependencies..."
  check_claude
  ensure_codex
  ensure_tmux
  ensure_hash_tool
  log
fi

# ---------- file install ----------

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
echo "Done."
echo
echo "Restart any open Claude Code sessions so the new slash command and skills"
echo "are picked up, then try:"
echo
echo "  /codex-cli-execution write a failing test for X then make it pass"
