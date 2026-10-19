#!/usr/bin/env bash
# 12 - build the guest device tree.
#
# Their first-stage init reads /firmware/android/fstab from the device tree.
# QEMU generates the virt DTB; we inject the fstab node pointing at our
# virtio disk's by-name paths. Their init then mounts our disks believing
# they are eMMC - no patch to any of their binaries.
#
# Rerun after changing -cpu/-smp/-m in machine.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
source tools/qemu/machine.sh

require "$QEMU"

log "12 - guest device tree"

RAW_DTB="$QDIR/virt-raw.dtb"
OUT_DTB="$QDIR/virt-android.dtb"
BYNAME="${BYNAME:-/dev/block/platform/a003e00.virtio_mmio/by-name}"

rm -f "$RAW_DTB"
$QEMU $(qemu_machine_args "dumpdtb=$RAW_DTB") -nographic >/dev/null 2>&1 || true
[ -s "$RAW_DTB" ] || die "QEMU did not produce a DTB"
log "  raw DTB: $(stat -f %z "$RAW_DTB") bytes"

tools/drun.sh -- bash tools/stages/12_dtb_inject.sh \
  work/qemu/virt-raw.dtb work/qemu/virt-android.dtb "$BYNAME" 2>/dev/null \
  | tee -a "$LOG" || die "DTB build failed"

[ -s "$OUT_DTB" ] || die "missing $OUT_DTB"
log "12 done: $OUT_DTB"
