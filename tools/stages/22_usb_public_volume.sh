#!/usr/bin/env bash
# Stage 22 (in-container) - make QEMU-attached USB storage usable as a
# public vold volume with world-readable mounts.
#
# Two edits, both discovered live in the ex2.img and codified here so a
# 14_gpt.sh rebuild reproduces them:
#
# 1. vendor fstab: the usbotg entry's sysfs path prefix points at the car's
#    MTK USB controller; QEMU's xHCI lives at PCI 0000:00:03.0 behind
#    4010000000.pcie. Redirect the prefix so vold claims the stick.
#
# 2. /system/bin/sdcard shim: this kernel has no sdcardfs/esdfs, so vold's
#    fuse step aborts ("failed to sdcardfs_setup") and the volume never
#    reaches "mounted". vold execs /system/bin/sdcard <flags> <src> <label>
#    WITHOUT dropping uid first, so a shell script runs as root: remount the
#    vfat world-readable (the kernel ignores uid/gid on remount of an
#    existing vfat mount, so umount + fresh mount), then bind-mount the
#    storage/runtime paths vold polls for. vold sees st_dev change and the
#    child exit, and reports the volume mounted. Without the fresh mount the
#    stick stays media_rw 0770 and uid-1000 scanners see nothing.
set -eu
cd /project
IMG=work/qemu/ex2.img

part() {
  sfdisk -d "$IMG" 2>/dev/null | grep -F "name=\"$1\"" | sed -n 's/.*'"$2"'=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1
}
SYS_S=$(part system start); SYS_N=$(part system size)
VEN_S=$(part vendor start); VEN_N=$(part vendor size)
SYS=work/qemu/system-mod.img
VEN=work/qemu/vendor-mod.img
dd if="$IMG" of="$SYS" bs=512 skip="$SYS_S" count="$SYS_N" conv=sparse status=none
dd if="$IMG" of="$VEN" bs=512 skip="$VEN_S" count="$VEN_N" conv=sparse status=none

QEMU_USB_PREFIX="/devices/platform/4010000000.pcie/pci0000:00/0000:00:03.0"

TMP=$(mktemp -d)
# ---- vendor: fstab.ecarxp usbotg path ----
debugfs -R "cat /etc/fstab.ecarxp" "$VEN" 2>/dev/null > "$TMP/fstab.orig"
cp "$TMP/fstab.orig" "$TMP/fstab.new"
sed -i -E "s|^/devices/[^ 	]*(.*voldmanaged=usbotg)|$QEMU_USB_PREFIX*\1|" "$TMP/fstab.new"
if ! cmp -s "$TMP/fstab.orig" "$TMP/fstab.new"; then
  CMDS=$(mktemp)
  {
    echo "cd /etc"
    if ! debugfs -R "stat /etc/fstab.ecarxp.bak" "$VEN" >/dev/null 2>&1; then
      echo "rm fstab.ecarxp.bak"
      echo "write /etc/fstab.ecarxp fstab.ecarxp.bak"
    fi
    echo "rm fstab.ecarxp"
    echo "write $TMP/fstab.new fstab.ecarxp"
  } > "$CMDS"
  debugfs -w -f "$CMDS" "$VEN" >/dev/null 2>&1
  rm -f "$CMDS"
  printf 'u:object_r:vendor_configs_file:s0\0' > "$TMP/lbl"
  for f in fstab.ecarxp fstab.ecarxp.bak; do
    debugfs -w -R "ea_set -f $TMP/lbl /etc/$f security.selinux" "$VEN" >/dev/null 2>&1
  done
fi

# ---- system: sdcard shim ----
cat > "$TMP/sdcard" <<'EOF'
#!/system/bin/sh
# Emulator-only shim: kernel lacks sdcardfs/esdfs, emulate vold's FUSE step
# with bind mounts, and re-mount the vfat world-readable so uid-1000 apps
# can walk it. vold execs this without setuid, so it runs as root.
{
  echo "=== $(date)"
  echo "args: $*"
  echo "ppid: $PPID"
} >> /data/local/tmp/sdcard-shim.log
while [ $# -gt 2 ]; do shift; done
SRC="$1"
LBL="$2"
# drop stale binds left by a previous attach of the same label
for p in /storage/$LBL /mnt/runtime/default/$LBL /mnt/runtime/read/$LBL /mnt/runtime/write/$LBL; do
  umount "$p" 2>/dev/null
done
DEV=$(awk -v s="$SRC" '$2==s {print $1; exit}' /proc/mounts)
if [ -n "$DEV" ] && umount "$SRC" 2>/dev/null; then
  mount -t vfat -o rw,uid=0,gid=1000,fmask=0000,dmask=0000 "$DEV" "$SRC" \
    >> /data/local/tmp/sdcard-shim.log 2>&1
fi
mkdir -p /storage/$LBL
mount -o bind "$SRC" /storage/$LBL
for v in default read write; do
  mkdir -p /mnt/runtime/$v/$LBL
  mount -o bind "$SRC" /mnt/runtime/$v/$LBL 2>/dev/null
done
exit 0
EOF
chmod 0755 "$TMP/sdcard"
CMDS=$(mktemp)
{
  echo "cd /bin"
  if ! debugfs -R "stat /bin/sdcard.real" "$SYS" >/dev/null 2>&1; then
    echo "rename sdcard sdcard.real"
  fi
  echo "rm sdcard"
  echo "write $TMP/sdcard sdcard"
  echo "sif sdcard mode 0100755"
  echo "sif sdcard uid 0"
  echo "sif sdcard gid 2000"
} > "$CMDS"
debugfs -w -f "$CMDS" "$SYS" >/dev/null 2>&1
rm -f "$CMDS"
printf 'u:object_r:sdcardd_exec:s0\0' > "$TMP/lbl-s"
printf 'u:object_r:system_file:s0\0' > "$TMP/lbl-r"
debugfs -w -R "ea_set -f $TMP/lbl-s /bin/sdcard security.selinux" "$SYS" >/dev/null 2>&1
debugfs -w -R "ea_set -f $TMP/lbl-r /bin/sdcard.real security.selinux" "$SYS" >/dev/null 2>&1

echo "=== verify ==="
debugfs -R "cat /etc/fstab.ecarxp" "$VEN" 2>/dev/null | grep usbotg
debugfs -R "stat /bin/sdcard" "$SYS" 2>/dev/null | grep -E "Size|Type"

off=$(( SYS_S * 512 ))
dd if="$SYS" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
off=$(( VEN_S * 512 ))
dd if="$VEN" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
rm -rf "$TMP"
