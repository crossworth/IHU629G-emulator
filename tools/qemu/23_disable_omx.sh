#!/usr/bin/env bash
# 23 - disable vendor OMX HAL service (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "23 - disable vendor OMX service (tombstone loop)"
tools/drun.sh -- bash tools/stages/23_disable_omx.sh 2>&1 | tee -a "$LOG"
log "23 done"
