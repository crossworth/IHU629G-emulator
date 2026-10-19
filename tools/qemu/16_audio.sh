#!/usr/bin/env bash
# 16 - audio (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "16 - audio"
tools/drun.sh -- bash "tools/stages/16_audio.sh" 2>&1 | tee -a "$LOG"
log "16 done"
