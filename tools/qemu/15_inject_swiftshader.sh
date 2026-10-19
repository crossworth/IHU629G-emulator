#!/usr/bin/env bash
# 15 - inject SwiftShader into vendor (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "15 - SwiftShader injection"
tools/drun.sh -- bash tools/stages/15_inject_swiftshader.sh 2>&1 | tee -a "$LOG"
log "15 done"
