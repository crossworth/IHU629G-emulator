#!/usr/bin/env bash
# 13 - build the modified ramdisk (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
source tools/qemu/machine.sh

log "13 - ramdisk"
tools/drun.sh -- bash tools/stages/13_ramdisk.sh 2>&1 | tee -a "$LOG" \
  || die "ramdisk build failed"
log "13 done: work/qemu/ramdisk-mod.img"
