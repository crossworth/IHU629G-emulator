#!/usr/bin/env bash
# 17 - bluetooth (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "17 - bluetooth"
tools/drun.sh -- bash "tools/stages/17_bluetooth.sh" 2>&1 | tee -a "$LOG"
log "17 done"
