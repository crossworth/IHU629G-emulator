#!/usr/bin/env bash
# 40 - build patched qemu-arm (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "40 - qemu-arm (binder passthrough)"
tools/drun.sh -- bash tools/stages/40_build_qemu_arm.sh 2>&1 | tee -a "$LOG" \
  || die "qemu-arm build failed - see logs/40_build_qemu_arm.log"
log "40 done: work/qemu-arm-binder-bin"
