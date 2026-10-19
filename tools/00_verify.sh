#!/usr/bin/env bash
# Stage 0 - fingerprint the firmware (host wrapper; logic in tools/stages/).
set -uo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh

log "stage 0 - firmware verification"
log "  dump dir: $DUMP"

tools/drun.sh -- bash tools/stages/00_verify.sh 2>/dev/null | tee -a "$LOG"

log ""
log "stage 0 done"
