#!/usr/bin/env bash
# Shared helpers. Source this from other scripts.
set -euo pipefail

COLOR_RED=$'\033[31m'
COLOR_GRN=$'\033[32m'
COLOR_YLW=$'\033[33m'
COLOR_BLU=$'\033[34m'
COLOR_RST=$'\033[0m'

log()  { printf '%s[INFO]%s %s\n'  "$COLOR_BLU" "$COLOR_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$COLOR_GRN" "$COLOR_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$COLOR_YLW" "$COLOR_RST" "$*"; }
err()  { printf '%s[ERR ]%s %s\n'  "$COLOR_RED" "$COLOR_RST" "$*" >&2; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { err "missing binary: $bin"; exit 1; }
  done
}

# confirm "prompt" — exits non-zero if user does not type YES
confirm() {
  local prompt="${1:-Proceed?}"
  printf '%s%s [type YES to proceed]:%s ' "$COLOR_YLW" "$prompt" "$COLOR_RST"
  read -r answer
  [[ "$answer" == "YES" ]] || { err "aborted by user"; exit 1; }
}

# dry-run marker; override with DRY_RUN=0 to actually run
: "${DRY_RUN:=1}"
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s[DRY]%s %s\n' "$COLOR_YLW" "$COLOR_RST" "$*"
  else
    printf '%s[RUN]%s %s\n' "$COLOR_GRN" "$COLOR_RST" "$*"
    eval "$@"
  fi
}
