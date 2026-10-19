#!/usr/bin/env bash
# 19 - display (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "19 - display"
tools/drun.sh -- bash "tools/stages/19_display.sh" 2>&1 | tee -a "$LOG"
log "19 done"
