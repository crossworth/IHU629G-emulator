#!/usr/bin/env bash
# Stage 15 (in-container) - inject SwiftShader arm64 into the vendor
# partition of work/qemu/ex2.img.
#
# Source: work/swiftshader-redroid/ (staged by tools/02_blobs.sh from the
# redroid 9 image - Android 9 era, arm64, no MediaTek deps). The firmware's
# own Mali blob cannot render under virtio-gpu; ro.hardware.egl=swiftshader
# (set in the ramdisk) makes Pie's EGL loader pick these.
set -eu
cd /project
IMG=work/qemu/ex2.img
G=work/swiftshader-redroid

for f in libEGL_swiftshader.so libGLESv1_CM_swiftshader.so libGLESv2_swiftshader.so; do
  [ -s "$G/$f" ] || { echo "missing $G/$f - run tools/02_blobs.sh"; exit 1; }
done

sect=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="vendor"' | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
size=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="vendor"' | sed -n 's/.*size=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
[ -n "$sect" ] || { echo "no vendor partition"; exit 1; }

V=work/qemu/vendor-mod.img
dd if="$IMG" of="$V" bs=512 skip="$sect" count="$size" conv=sparse status=none

# debugfs `write` creates the target in its CWD and -R resets to the fs root
# on every invocation, so a path in the target silently fails. A command file
# via -f keeps state across lines: cd once, then write by bare name.
CMDS=$(mktemp)
{
  echo "cd /lib64/egl"
  for f in libEGL_swiftshader.so libGLESv1_CM_swiftshader.so libGLESv2_swiftshader.so; do
    echo "rm $f"
    echo "write /project/$G/$f $f"
    echo "sif $f mode 0100644"
  done
} > "$CMDS"
debugfs -w -f "$CMDS" "$V" 2>&1 | grep -E 'Allocated|Error' || true
rm -f "$CMDS"

printf 'u:object_r:same_process_hal_file:s0\0' > /tmp/lbl
for f in libEGL_swiftshader.so libGLESv1_CM_swiftshader.so libGLESv2_swiftshader.so; do
  debugfs -w -R "ea_set -f /tmp/lbl /lib64/egl/$f security.selinux" "$V" >/dev/null 2>&1
done

echo "=== verify ==="
debugfs -R "ls -l /lib64/egl" "$V" 2>/dev/null

off=$(( sect * 512 ))
dd if="$V" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
