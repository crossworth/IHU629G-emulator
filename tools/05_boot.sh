#!/usr/bin/env bash
# Stage 5 - unpack their boot image (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh

log "stage 5 - boot image"
tools/drun.sh -- bash tools/stages/05_boot.sh 2>/dev/null | tee -a "$LOG"
log "stage 5 done"
