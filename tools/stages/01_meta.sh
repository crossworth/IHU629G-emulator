#!/usr/bin/env bash
# Stage 1 (in-container) - metadata that decides how the emulator is wired:
# init imports (which init.<hw>.rc their init.rc expects), sepolicy shape,
# userdata encryption state, and which vendor HALs exist.
set -u
cd /project

echo "=== init.rc imports ==="
debugfs -R "cat /init.rc" firmware/system.img 2>/dev/null | grep -E "^import|^on early-init" | head -20 | sed 's/^/  /'

echo "=== ramdisk init.rc (from stage 5) ==="
if [ -s work/boot/ramdisk.cpio ]; then
  rm -rf work/boot/ramdisk-x && mkdir work/boot/ramdisk-x
  (cd work/boot/ramdisk-x && cpio -idm --quiet < ../ramdisk.cpio)
  grep -hE "^import" work/boot/ramdisk-x/init.rc 2>/dev/null | sed 's/^/  ramdisk:/'
  ls work/boot/ramdisk-x | head -30 | sed 's/^/  entry: /'
fi

echo "=== vendor init scripts ==="
debugfs -R "ls /etc/init/hw" firmware/vendor.img 2>/dev/null | head -20 | sed 's/^/  /'

echo "=== sepolicy ==="
for f in /etc/selinux/precompiled_sepolicy /sepolicy; do
  sz=$(debugfs -R "stat $f" firmware/vendor.img 2>/dev/null | grep -o "Size: [0-9]*" | head -1)
  [ -n "$sz" ] && echo "  vendor:$f $sz"
done

echo "=== graphics/audio HAL modules in vendor ==="
debugfs -R "ls -l /lib64/hw" firmware/vendor.img 2>/dev/null | awk '{print $NF}' | grep -E 'gralloc|hwcomposer|audio|power|memtrack|camera|sensors|gps' | sed 's/^/  /'

echo "=== userdata encryption check ==="
# FDE crypto footer lives in the last 16 KiB of the userdata partition.
python3 - <<'PY'
import os, struct
p = "/dump/userdata.img"
if not os.path.exists(p):
    print("  userdata.img not found at /dump - skipping"); raise SystemExit
sz = os.path.getsize(p)
with open(p, "rb") as f:
    f.seek(sz - 16384)
    tail = f.read()
    f.seek(1024)
    sup = f.read(58)
magic = struct.unpack_from("<I", tail, 0)[0]
print(f"  userdata size {sz/2**30:.1f} GiB, last-16K first u32 = 0x{magic:08x}")
print("  FDE footer magic PRESENT" if magic == 0xF60 else "  no FDE footer at end-16K")
print(f"  ext magic at 1080: {sup[56:58].hex()} (53ef = ext2/3/4 superblock)")

p = "/dump/metadata.img"
if os.path.exists(p):
    d = open(p,"rb").read(512)
    print(f"  metadata.img first 16 bytes: {d[:16].hex()}")
    print("  nonzero -> FDE crypto metadata exists" if any(d) else "  metadata all zero -> no FDE key material")
else:
    print("  metadata.img not found")
PY
