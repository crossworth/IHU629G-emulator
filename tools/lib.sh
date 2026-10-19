#!/usr/bin/env bash
# Shared setup for host-side stage scripts. Sourced, not executed.
#
# Paths are macOS-host relative. Anything needing Linux tooling goes through
# tools/drun.sh.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$ROOT/firmware"          # key partitions copied from the car dump
DUMP="${EX2_DUMP:-$ROOT/dump}"   # full 51-partition dump
WORK="$ROOT/work"
OUT="$ROOT/out"
LOGS="$ROOT/logs"

SYSTEM_IMG="$FW/system.img"
VENDOR_IMG="$FW/vendor.img"
BOOT_IMG="$FW/boot.img"

mkdir -p "$WORK" "$OUT" "$LOGS"

# --- logging ---------------------------------------------------------------

STAGE="$(basename "${BASH_SOURCE[1]:-stage}" .sh)"
LOG="$LOGS/${STAGE}.log"
: > "$LOG"

log()  { printf '%s\n' "$*" | tee -a "$LOG"; }
head1() { log ""; log "=== $* ==="; }
warn() { printf '!! %s\n' "$*" | tee -a "$LOG" >&2; }
die()  { warn "$*"; exit 1; }

require() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
  done
}

# dbg <image> <debugfs-request> - runs debugfs inside the container
# (macOS has no debugfs). stderr is discarded: debugfs writes its banner there
# even on success.
dbg() {
  local img="$1"; shift
  tools/drun.sh -w /project -- debugfs -R "$*" "${img#$(pwd)/}" 2>/dev/null
}

for f in "$SYSTEM_IMG" "$VENDOR_IMG" "$BOOT_IMG"; do
[ -r "$f" ] || die "cannot read $f - copy partitions from the dump into firmware/"
done
