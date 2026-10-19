#!/usr/bin/env bash
# 18 - adbd (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "18 - adbd"
tools/drun.sh -- bash "tools/stages/18_adbd.sh" 2>&1 | tee -a "$LOG"
log "18 done"
