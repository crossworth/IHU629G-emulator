#!/usr/bin/env bash
# 22 - USB public volume (host wrapper).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
log "22 - USB public volume (fstab path + sdcard shim)"
tools/drun.sh -- bash tools/stages/22_usb_public_volume.sh 2>&1 | tee -a "$LOG"
log "22 done"
