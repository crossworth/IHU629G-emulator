#!/usr/bin/env bash
# 21 - AEE stub (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "21 - AEE stub (stock crash dumps)"
tools/drun.sh -- bash tools/stages/21_aee_stub.sh 2>&1 | tee -a "$LOG"
log "21 done"
