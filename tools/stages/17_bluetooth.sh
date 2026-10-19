#!/usr/bin/env bash
# Stage 17 (in-container) - replace the MTK bluetooth HAL service with
# redroid's simulated bluetooth HAL (64-bit).
#
# Why: com.android.systemui crashes at layout inflate -
#   BluetoothAdapter.isEnabled() NPE, "Bluetooth binder is null"
# because com.android.bluetooth never publishes IBluetooth: its vendor HAL
# (bluetooth@1.0-service-mediatek) is MediaTek 32-bit (dead under
# qemu-user binder). SystemUI's death = black screen + system_server
# restart churn. redroid ships a bluetooth@1.0 SIMULATOR (arm64,
# era-matching deps) - no real chip needed, the stack just has to exist.
#
# Content swaps in vendor (names stay theirs - their rc: service
# bluetooth-1-0 /vendor/bin/hw/android.hardware.bluetooth@1.0-service-mediatek):
#   bin/hw/android.hardware.bluetooth@1.0-service-mediatek <- redroid sim
#   lib64/android.hardware.bluetooth@1.0.so                <- redroid (missing)
#   lib64/libchrome.so                                     <- redroid (the sim
#     service links it; it exists in system:/lib64 but vendor processes'
#     namespace only sees LLNDK system libs - must live in /vendor/lib64)
set -eu
cd /project
IMG=work/qemu/ex2.img
B=work/redroid-bt

for f in "$B/service.sim" "$B/android.hardware.bluetooth@1.0.so" "$B/libchrome.so"; do
  [ -s "$f" ] || { echo "missing $f - run tools/02_blobs.sh"; exit 1; }
done

sect=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="vendor"' | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
size=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="vendor"' | sed -n 's/.*size=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
V=work/qemu/vendor-mod.img
dd if="$IMG" of="$V" bs=512 skip="$sect" count="$size" conv=sparse status=none

LBL=$(debugfs -R "ea_list /bin/hw/android.hardware.bluetooth@1.0-service-mediatek" "$V" 2>/dev/null | grep -o 'u:object_r:[a-z_]*:s0' | head -1)
echo "  service label: ${LBL:-none}"

CMDS=$(mktemp)
{
  echo "cd /bin/hw"
  echo "rm android.hardware.bluetooth@1.0-service-mediatek"
  echo "write /project/$B/service.sim android.hardware.bluetooth@1.0-service-mediatek"
  echo "sif android.hardware.bluetooth@1.0-service-mediatek mode 0100755"
  echo "cd /lib64"
  echo "rm android.hardware.bluetooth@1.0.so"
  echo "write /project/$B/android.hardware.bluetooth@1.0.so android.hardware.bluetooth@1.0.so"
  echo "sif android.hardware.bluetooth@1.0.so mode 0100644"
  echo "rm libchrome.so"
  echo "write /project/$B/libchrome.so libchrome.so"
  echo "sif libchrome.so mode 0100644"
} > "$CMDS"
debugfs -w -f "$CMDS" "$V" 2>&1 | grep -E 'Allocated|Error' || true
rm -f "$CMDS"

[ -n "$LBL" ] && { printf '%s\0' "$LBL" > /tmp/lbl_s
  debugfs -w -R "ea_set -f /tmp/lbl_s /bin/hw/android.hardware.bluetooth@1.0-service-mediatek security.selinux" "$V" >/dev/null 2>&1; }
printf 'u:object_r:same_process_hal_file:s0\0' > /tmp/lbl_h
for p in /lib64/android.hardware.bluetooth@1.0.so /lib64/libchrome.so; do
  debugfs -w -R "ea_set -f /tmp/lbl_h $p security.selinux" "$V" >/dev/null 2>&1
done

echo "=== verify ==="
debugfs -R "ls -l /bin/hw" "$V" 2>/dev/null | grep "bluetooth@1.0-service"
debugfs -R "ea_list /bin/hw/android.hardware.bluetooth@1.0-service-mediatek" "$V" 2>/dev/null | grep -o 'u:object_r:[a-z_]*'

off=$(( sect * 512 ))
dd if="$V" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
