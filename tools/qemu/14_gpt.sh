#!/usr/bin/env bash
# 14 - build the partitioned disk (host wrapper; runs in container).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
source tools/qemu/machine.sh

log "14 - GPT disk"
tools/drun.sh -- bash tools/stages/14_gpt.sh "$@" 2>&1 | tee -a "$LOG" \
  || die "GPT build failed"
log "14 done: work/qemu/ex2.img"
