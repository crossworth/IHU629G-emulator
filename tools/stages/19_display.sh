#!/usr/bin/env bash
# Stage 19 (in-container) - display stack for virtio-gpu.
#
#   vendor:/lib64/egl/libGLES_mali.so        <- REMOVED (archived to
#     work/mali/). With ro.hardware.egl=swiftshader, Pie's Loader tries the
#     updated driver first, but the combined load_driver("GLES") scan can
#     still match and load the Mali blob; removing it makes every scan miss.
#   vendor:/lib64/hw/hwcomposer.ecarxp.so    <- content replaced with the
#     android-28 GSI's hwcomposer.ranchu.so (classic emulator fbdev
#     composer). The OEM module is MediaTek-only; the redroid composer is
#     stream-only (serves frames over /ipc/hwcomposer.sock - nothing blits
#     without its client). ranchu actually drives /dev/graphics/fb0.
#   vendor:/lib64/hw/gralloc.ecarxp.so       <- content replaced with the
#     ashmem-only gralloc (work/fw-gfx/gralloc.ashmem.so - the firmware's
#     own gralloc with the GRALLOC_USAGE_HW_FB branch NOP'd). The HW_FB
#     path returns handles pointing into the ALLOCATOR service's fb mapping,
#     meaningless in SurfaceFlinger's address space; SwiftShader wrote there
#     and died. fb_post handles plain ashmem fine.
#
# The OEM composer@2.1 service+impl stay: they are 64-bit and their NEEDED
# libs (incl. libhwc2on1adapter/libhwc2onfbadapter, shipped by the firmware
# itself) all resolve. If IComposer ever fails to register in a future
# firmware, the redroid pair in work/redroid-composer/ is the known-good
# fallback (swap bin/hw/...composer@2.1-service and lib64/hw/...impl.so,
# label hal_graphics_composer_default_exec / same_process_hal_file).
set -eu
cd /project
IMG=work/qemu/ex2.img

for f in work/gsi28-gfx/hwcomposer.ranchu.so work/fw-gfx/gralloc.ashmem.so; do
  [ -s "$f" ] || { echo "missing $f - run tools/02_blobs.sh"; exit 1; }
done

python3 - <<'PY'
data = open("work/fw-gfx/gralloc.ashmem.so", "rb").read()
assert data[0x11d0:0x11d4] == bytes.fromhex("1f2003d5"), "gralloc.ashmem.so is not patched"
print("gralloc patch sanity OK")
PY

sect=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="vendor"' | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
size=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="vendor"' | sed -n 's/.*size=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
V=work/qemu/vendor-mod.img
dd if="$IMG" of="$V" bs=512 skip="$sect" count="$size" conv=sparse status=none

mkdir -p work/mali
if [ ! -s work/mali/libGLES_mali.so ]; then
  debugfs -R "dump /lib64/egl/libGLES_mali.so /project/work/mali/libGLES_mali.so" "$V" 2>/dev/null || true
fi

CMDS=$(mktemp)
{
  echo "cd /lib64/egl"
  echo "rm libGLES_mali.so"
  echo "cd /lib64/hw"
  echo "rm hwcomposer.ecarxp.so"
  echo "write /project/work/gsi28-gfx/hwcomposer.ranchu.so hwcomposer.ecarxp.so"
  echo "sif hwcomposer.ecarxp.so mode 0100644"
  echo "rm gralloc.ecarxp.so"
  echo "write /project/work/fw-gfx/gralloc.ashmem.so gralloc.ecarxp.so"
  echo "sif gralloc.ecarxp.so mode 0100644"
} > "$CMDS"
debugfs -w -f "$CMDS" "$V" 2>&1 | grep -E 'Allocated|Error|not found' || true
rm -f "$CMDS"

printf 'u:object_r:same_process_hal_file:s0\0' > /tmp/lbl
for p in /lib64/hw/hwcomposer.ecarxp.so /lib64/hw/gralloc.ecarxp.so; do
  debugfs -w -R "ea_set -f /tmp/lbl $p security.selinux" "$V" >/dev/null 2>&1
done

echo "=== verify ==="
debugfs -R "ls -l /lib64/egl" "$V" 2>/dev/null
debugfs -R "ls -l /lib64/hw" "$V" 2>/dev/null | grep -E "hwcomposer|gralloc|composer"

off=$(( sect * 512 ))
dd if="$V" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
