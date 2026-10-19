#!/usr/bin/env bash
# Stage 21 (in-container) - neutralize the MTK AEE crash hook in the system
# image so native crashes take the stock Android 9 path.
#
# The AEE daemons refuse QEMU ("debuggerd the chip dismatch") and their hook
# (LD_PRELOAD libdirect-coredump.so + kernel core_pattern pipe to
# aee_core_forwarder) swallows every native crash without a trace: no
# "Fatal signal" line, no backtrace, no tombstone. The stock path
# (bionic handler -> crash_dump64 -> tombstoned) is fully present and
# healthy in this image. Replace init.aee.rc with a stub that keeps the
# harmless mkdirs and drops: the LD_PRELOAD export, the core_pattern pipe
# writes, the aee_aed service starts, and the import of the non-existent
# /init.preload.rc.
set -eu
cd /project
IMG=work/qemu/ex2.img

sect=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="system"' | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
size=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="system"' | sed -n 's/.*size=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
S=work/qemu/system-mod.img
dd if="$IMG" of="$S" bs=512 skip="$sect" count="$size" conv=sparse status=none

TMP=$(mktemp -d)
cat > "$TMP/init.aee.rc" <<'EOF'
# ex2emu: AEE neutralized - the MTK AEE daemons refuse QEMU ("chip dismatch")
# and their crash hook (LD_PRELOAD libdirect-coredump.so + core_pattern pipe
# to aee_core_forwarder) eats every native crash without a trace. With this
# stub, crashes take the stock Android 9 path: bionic handler -> crash_dump64
# -> tombstoned -> tombstone in /data/tombstones + DEBUG backtrace in logcat.
on post-fs-data
    mkdir /data/dumpsys 0775 system system
    mkdir /data/core 0775 system system
    mkdir /data/misc/aee_interim 0775 system system

on init
    write /proc/self/coredump_filter 39
EOF

CMDS=$(mktemp)
{
  # keep the original once, for reference and idempotent re-runs
  if ! debugfs -R "stat /etc/init/hw/init.aee.rc.bak" "$S" >/dev/null 2>&1; then
    echo "cd /etc/init/hw"
    echo "rm init.aee.rc.bak"
    echo "write /etc/init/hw/init.aee.rc init.aee.rc.bak"
  fi
  echo "cd /etc/init/hw"
  echo "rm init.aee.rc"
  echo "write $TMP/init.aee.rc init.aee.rc"
} > "$CMDS"
debugfs -w -f "$CMDS" "$S" >/dev/null 2>&1
rm -f "$CMDS"

for f in init.aee.rc init.aee.rc.bak; do
  printf 'u:object_r:system_file:s0\0' > /tmp/lbl
  debugfs -w -R "ea_set -f /tmp/lbl /etc/init/hw/$f security.selinux" "$S" >/dev/null 2>&1
done

echo "=== verify ==="
debugfs -R "cat /etc/init/hw/init.aee.rc" "$S" 2>/dev/null | head -3
debugfs -R "ea_list /etc/init/hw/init.aee.rc" "$S" 2>/dev/null | grep -o 'u:object_r:[a-z_]*'

off=$(( sect * 512 ))
dd if="$S" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
rm -rf "$TMP"
