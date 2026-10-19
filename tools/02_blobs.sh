#!/usr/bin/env bash
# tools/02_blobs.sh - extract or derive every modified binary used by the
# emulator, with provenance recorded in each step.
#
# Sources:
#   - redroid/redroid:9.0.0-latest container image (SwiftShader EGL, BT stub,
#     composer service+impl, libc++_shared)
#   - AOSP SDK system/vendor images for android-28 (adbd, audioserver,
#     audioflinger, audio HAL service+impls, ranchu hwcomposer)
#   - binary patches applied to pristine copies (byte-level, asserted)
#
# Every output lands in the work/ staging layout consumed by the disk
# modification stages (15+). Idempotent: skips artifacts already present.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "ERROR: $*" >&2; exit 1; }
need() { [ -e "$1" ] || die "missing input: $1"; }

GSI_SYS="work/android-sdk/system-28-raw.img"
GSI_VEN="work/android-sdk/vendor-28-raw.img"
REDROID_IMG="redroid/redroid:9.0.0-latest"

need "$GSI_SYS"; need "$GSI_VEN"

have() { [ -e "$1" ] && { echo "  already present: $1"; return 0; }; return 1; }

echo "==> 1/7 redroid: SwiftShader EGL + libchrome + libc++_shared"
if have work/swiftshader-redroid/libEGL_swiftshader.so && have work/redroid-bt/libchrome.so && have work/redroid-bt/libc++_shared.so; then :; else
  cid=$(docker create "$REDROID_IMG")
  mkdir -p work/swiftshader-redroid work/redroid-bt
  for f in libEGL_swiftshader.so libGLESv1_CM_swiftshader.so libGLESv2_swiftshader.so; do
    docker cp "$cid:/vendor/lib64/egl/$f" "work/swiftshader-redroid/$f"
  done
  docker cp "$cid:/vendor/lib64/libchrome.so" "work/redroid-bt/libchrome.so"
  docker cp "$cid:/vendor/lib64/libc++_shared.so" "work/redroid-bt/libc++_shared.so"
  docker rm "$cid" >/dev/null
fi

echo "==> 2/7 redroid: BT stub service + HIDL lib"
if have work/redroid-bt/service.sim && have work/redroid-bt/android.hardware.bluetooth@1.0.so; then :; else
  cid=$(docker create "$REDROID_IMG")
  docker cp "$cid:/vendor/bin/hw/android.hardware.bluetooth@1.0-service.sim" "work/redroid-bt/service.sim"
  docker cp "$cid:/system/lib64/android.hardware.bluetooth@1.0.so" "work/redroid-bt/android.hardware.bluetooth@1.0.so"
  docker rm "$cid" >/dev/null
fi

echo "==> 3/7 redroid: composer service + impl (fallback if OEM composer fails)"
if have work/redroid-composer/composer-service && have work/redroid-composer/composer-impl.so; then :; else
  cid=$(docker create "$REDROID_IMG")
  mkdir -p work/redroid-composer
  docker cp "$cid:/vendor/bin/hw/android.hardware.graphics.composer@2.1-service" "work/redroid-composer/composer-service"
  docker cp "$cid:/vendor/lib64/hw/android.hardware.graphics.composer@2.1-impl.so" "work/redroid-composer/composer-impl.so"
  docker rm "$cid" >/dev/null
fi

echo "==> 4/7 GSI android-28: adbd, audioserver, audioflinger, libaaudioservice"
if have work/adbd-gsi-pristine && have work/audioserver-aosp9 && have work/libaudioflinger-gsi.so && have work/libaaudioservice.so; then :; else
  tools/drun.sh -- /bin/bash -c '
    set -e
    mkdir -p /tmp/extsys
    debugfs -R "dump /system/bin/adbd /tmp/extsys/adbd" /project/work/android-sdk/system-28-raw.img 2>/dev/null
    debugfs -R "dump /system/bin/audioserver /tmp/extsys/audioserver" /project/work/android-sdk/system-28-raw.img 2>/dev/null
    debugfs -R "dump /system/lib64/libaudioflinger.so /tmp/extsys/libaudioflinger.so" /project/work/android-sdk/system-28-raw.img 2>/dev/null
    debugfs -R "dump /system/lib64/libaaudioservice.so /tmp/extsys/libaaudioservice.so" /project/work/android-sdk/system-28-raw.img 2>/dev/null
    for f in adbd audioserver libaudioflinger.so libaaudioservice.so; do
      [ -s "/tmp/extsys/$f" ] || { echo "FAIL: $f not extracted"; exit 1; }
    done
    cp /tmp/extsys/adbd /project/work/adbd-gsi-pristine
    cp /tmp/extsys/audioserver /project/work/audioserver-aosp9
    cp /tmp/extsys/libaudioflinger.so /project/work/libaudioflinger-gsi.so
    cp /tmp/extsys/libaaudioservice.so /project/work/libaaudioservice.so
  '
fi

echo "==> 5/7 GSI android-28 vendor: audio HAL service + impls (64-bit)"
if have work/gsi28-audio/service && have work/gsi28-audio/audio4-impl.so && have work/gsi28-audio/audiofx4-impl.so; then :; else
  tools/drun.sh -- /bin/bash -c '
    set -e
    mkdir -p /tmp/extven
    debugfs -R "dump /bin/hw/android.hardware.audio@2.0-service /tmp/extven/service" /project/work/android-sdk/vendor-28-raw.img 2>/dev/null
    debugfs -R "dump /lib64/hw/android.hardware.audio@4.0-impl.so /tmp/extven/audio4-impl.so" /project/work/android-sdk/vendor-28-raw.img 2>/dev/null
    debugfs -R "dump /lib64/hw/android.hardware.audio.effect@4.0-impl.so /tmp/extven/audiofx4-impl.so" /project/work/android-sdk/vendor-28-raw.img 2>/dev/null
    for f in service audio4-impl.so audiofx4-impl.so; do
      [ -s "/tmp/extven/$f" ] || { echo "FAIL: $f not extracted"; exit 1; }
    done
    mkdir -p /project/work/gsi28-audio
    cp /tmp/extven/* /project/work/gsi28-audio/
  '
fi

echo "==> 6/7 GSI android-28 vendor: ranchu hwcomposer + composer impl (display)"
if have work/gsi28-gfx/hwcomposer.ranchu.so && have work/gsi28-gfx/composer21-impl.so; then :; else
  tools/drun.sh -- /bin/bash -c '
    set -e
    mkdir -p /tmp/extgfx
    debugfs -R "dump /lib64/hw/hwcomposer.ranchu.so /tmp/extgfx/hwcomposer.ranchu.so" /project/work/android-sdk/vendor-28-raw.img 2>/dev/null
    debugfs -R "dump /lib64/hw/android.hardware.graphics.composer@2.1-impl.so /tmp/extgfx/composer21-impl.so" /project/work/android-sdk/vendor-28-raw.img 2>/dev/null
    for f in hwcomposer.ranchu.so composer21-impl.so; do
      [ -s "/tmp/extgfx/$f" ] || { echo "FAIL: $f not extracted"; exit 1; }
    done
    mkdir -p /project/work/gsi28-gfx
    cp /tmp/extgfx/* /project/work/gsi28-gfx/
  '
fi

echo "==> 7/7 binary patches (adbd auth, gralloc ashmem)"
if have work/adbd-gsi; then :; else
  need work/adbd-gsi-pristine
  python3 - <<'PYEOF'
import shutil, sys
src, dst = "work/adbd-gsi-pristine", "work/adbd-gsi"
shutil.copyfile(src, dst)
data = bytearray(open(dst, "rb").read())

def patch(off, expect, new, what):
    cur = bytes(data[off:off+len(expect)])
    if cur == new:
        print(f"  already patched: {what}")
        return
    assert cur == expect, f"{what}: expected {expect.hex()} at {off:#x}, found {cur.hex()}"
    data[off:off+len(expect)] = new
    print(f"  patched: {what}")

# cbz w10 -> NOP: allow ADB_AUTH even when ro.adb.secure=1
patch(0x1d6d0, bytes.fromhex("aa0e0034"), bytes.fromhex("1f2003d5"), "adbd auth cbz->nop")
# feature/flag bytes that gate auth on GSI adbd
patch(0x59569, bytes([0x01]), bytes([0x00]), "adbd flag @0x59569")
patch(0x59591, bytes([0x01]), bytes([0x00]), "adbd flag @0x59591")
patch(0x595cc, bytes.fromhex("e20b1e32"), bytes.fromhex("02028052"), "adbd flag @0x595cc")
open(dst, "wb").write(bytes(data))
PYEOF
fi
if have work/fw-gfx/gralloc.ashmem.so; then :; else
  need work/fw-gfx/gralloc.default.so
  python3 - <<'PYEOF'
import shutil
src, dst = "work/fw-gfx/gralloc.default.so", "work/fw-gfx/gralloc.ashmem.so"
shutil.copyfile(src, dst)
data = bytearray(open(dst, "rb").read())
off = 0x11d0
expect = bytes.fromhex("04016037")   # tbnz w4, #12 -> ION path
new    = bytes.fromhex("1f2003d5")   # NOP -> ashmem path
cur = bytes(data[off:off+4])
if cur == new:
    print("  already patched: gralloc tbnz->nop")
else:
    assert cur == expect, f"gralloc: expected {expect.hex()} at {off:#x}, found {cur.hex()}"
    data[off:off+4] = new
    open(dst, "wb").write(bytes(data))
    print("  patched: gralloc tbnz->nop")
PYEOF
fi

echo ""
echo "==> blob staging complete"
ls -la work/adbd-gsi work/audioserver-aosp9 work/gsi28-audio work/gsi28-gfx work/redroid-bt work/redroid-composer work/swiftshader-redroid work/fw-gfx
