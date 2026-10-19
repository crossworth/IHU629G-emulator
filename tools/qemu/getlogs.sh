#!/usr/bin/env bash
# - extract the guest's /log (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "guest logs"
tools/drun.sh -- bash tools/stages/21_getlogs.sh 2>&1 | tee -a "$LOG"
log "done: out/guestlogs/"
