#!/usr/bin/env bash
# 10 - build the substitute kernel (host wrapper; build runs in container).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

log "10 - kernel build"
tools/drun.sh -- bash tools/stages/10_kernel.sh 2>&1 | tee -a "$LOG" \
  | grep -vE '^(  (CC|LD|AR|OBJCOPY|DTC|SYSHDR|UPD|GEN|CHK|HOSTCC))' \
  || die "kernel build failed - see logs/10_kernel.log"
log "10 done: work/qemu/Image"
