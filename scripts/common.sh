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

# Parse EIP allocation IDs safely (POSTMORTEM M1).
#
# Never `source` state.txt — a malformed file (e.g. leading whitespace in the
# value) causes bash to execute "eipalloc-xxx" as a command. Instead grep the
# literal tokens and echo them space-separated. Safe no matter how state.txt
# was written (leading spaces, quotes, empty file, missing file).
#
# Usage:
#   mapfile -t EIP_IDS < <(extract_eip_allocs "$STATE_FILE")
#   for a in "${EIP_IDS[@]}"; do aws ec2 release-address --allocation-id "$a"; done
extract_eip_allocs() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 0
  # Match only the canonical `eipalloc-<hex>` pattern; 8 or 17 hex chars.
  grep -oE 'eipalloc-[0-9a-f]{8,17}' "$file" 2>/dev/null | sort -u || true
}
