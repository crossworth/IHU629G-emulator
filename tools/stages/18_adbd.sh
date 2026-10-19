#!/usr/bin/env bash
# Stage 18 (in-container) - replace the 32-bit adbd with the android-28
# GSI's 64-bit adbd (auth check neutralized, see tools/02_blobs.sh).
#
# Their adbd runs under qemu-arm (32-bit) and the ADB handshake never
# completes - qemu-user quirks. The GSI-28 adbd is arm64 and works; its
# ADB_AUTH gate is patched out because ro.adb.secure=1 in their build props
# and there is no host RSA flow that survives the emulator's boot props.
# Label adbd_exec preserved.
set -eu
cd /project
IMG=work/qemu/ex2.img

[ -s work/adbd-gsi ] || { echo "missing work/adbd-gsi - run tools/02_blobs.sh"; exit 1; }

sect=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="system"' | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
size=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="system"' | sed -n 's/.*size=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
S=work/qemu/system-mod.img
dd if="$IMG" of="$S" bs=512 skip="$sect" count="$size" conv=sparse status=none

CMDS=$(mktemp)
{
  echo "cd /bin"
  echo "rm adbd"
  echo "write /project/work/adbd-gsi adbd"
  echo "sif adbd mode 0100755"
} > "$CMDS"
debugfs -w -f "$CMDS" "$S" 2>&1 | grep -E 'Allocated|Error' || true
rm -f "$CMDS"

printf 'u:object_r:adbd_exec:s0\0' > /tmp/lbl
debugfs -w -R "ea_set -f /tmp/lbl /bin/adbd security.selinux" "$S" >/dev/null 2>&1

echo "=== verify ==="
debugfs -R "stat /bin/adbd" "$S" 2>/dev/null | grep -E "Size|Type"
debugfs -R "ea_list /bin/adbd" "$S" 2>/dev/null | grep -o 'u:object_r:[a-z_]*'

off=$(( sect * 512 ))
dd if="$S" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
