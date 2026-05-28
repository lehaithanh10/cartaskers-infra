#!/usr/bin/env bash
# scripts/lib/prompt.sh — shared shell helpers for bootstrap & other scripts.
# Sourced, not executed: `source "$(dirname "$0")/lib/prompt.sh"`

# Stay compatible with stock macOS bash 3.2 — no associative arrays, no [[ ... ]]
# unless necessary.

# Colors (no-op when stdout is not a TTY, e.g. piped to a file or CI)
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

# --- Logging ---

info()    { printf "%s[i]%s %s\n" "$C_BLUE"   "$C_RESET" "$*"; }
ok()      { printf "%s[✓]%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn()    { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf "%s[x]%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
section() { printf "\n%s== %s ==%s\n" "$C_BOLD" "$*" "$C_RESET"; }
dim()     { printf "%s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }

# Abort with a message. Use `die "reason"` after a check fails.
die() { err "$*"; exit 1; }

# --- Tooling checks ---

# require_cmd <command> [install-hint]
# Exits if the command isn't on PATH.
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Required command not found: $cmd"
    [ -n "$hint" ] && dim "    Install: $hint"
    exit 1
  fi
}

# --- Prompts ---

# prompt_value <var-name> <prompt-text> [default]
# Reads visible input into the named variable. Reuses an existing value if
# the variable is already set (allows env-var pre-population for non-interactive runs).
prompt_value() {
  local var="$1" text="$2" default="${3:-}"
  local current
  eval "current=\${$var:-}"
  if [ -n "$current" ]; then
    dim "    using existing \$$var"
    return 0
  fi
  local input
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$text" "$default"
  else
    printf "%s: " "$text"
  fi
  IFS= read -r input
  if [ -z "$input" ] && [ -n "$default" ]; then
    input="$default"
  fi
  eval "$var=\$input"
}

# prompt_secret <var-name> <prompt-text>
# Reads input WITHOUT echoing it to the terminal.
prompt_secret() {
  local var="$1" text="$2"
  local current
  eval "current=\${$var:-}"
  if [ -n "$current" ]; then
    dim "    using existing \$$var"
    return 0
  fi
  local input
  printf "%s (hidden): " "$text"
  # -s = silent, -r = raw (no backslash interpretation)
  IFS= read -rs input
  printf "\n"
  eval "$var=\$input"
}

# confirm <prompt-text>
# Returns 0 for yes, 1 for no. Default = no.
confirm() {
  local text="$1"
  local reply
  printf "%s [y/N]: " "$text"
  IFS= read -r reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}
