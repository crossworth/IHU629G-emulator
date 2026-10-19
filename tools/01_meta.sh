#!/usr/bin/env bash
# Stage 1 - firmware metadata (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh

log "stage 1 - metadata"
tools/drun.sh -- bash tools/stages/01_meta.sh 2>/dev/null | tee -a "$LOG"
log "stage 1 done"
