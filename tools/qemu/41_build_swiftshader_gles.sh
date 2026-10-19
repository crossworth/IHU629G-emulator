#!/usr/bin/env bash
# 41 - build the 2021 SwiftShader (last GLES-capable revision) for android-arm64.
#
# Host-side (macOS + NDK r27c universal). Produces drop-in replacements for
# /vendor/lib64/egl/lib{EGL,GLESv2}_swiftshader.so (keep the OLD
# libGLESv1_CM_swiftshader.so - the 2021 tree dropped ES1; the old v1 lib is
# self-contained and coexists).
#
# STATUS (2026-08-17): the built libs LOAD and run - SurfaceFlinger reports
# "SwiftShader 4.6.6.6", zero crashes, eglCreateImageKHR's Android path works
# (needed for SF's own composition). REMAINING BLOCKER: no app window ever
# posts a buffer (all 41 SF layers stay activeBuffer 0x0, screen black, no
# EGL errors logged). Next step: debug eglCreateWindowSurface/swap in
# src/OpenGL/libEGL/Surface.cpp + src/Main/FrameBufferAndroid.cpp (NDK
# branch) against the API-28 Surface. See BLOCKERS.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
WORK=$ROOT/work
SS=$WORK/swiftshader-gles            # patched tree (kept between runs)
NDK=$WORK/ndk/android-ndk-r27c
LINKLIBS=$WORK/linklibs              # guest LLNDK libs for linking
# Last commit whose CMake still builds libEGL/libGLESv2 (GLES frontend was
# removed from CMake 2021-12-09, source deleted 2022-04-19).
SS_COMMIT=606261c75c2a686ee5a9331e2141d3ed946986f4

command -v cmake >/dev/null || { echo "brew install cmake ninja"; exit 1; }
[ -d "$NDK" ] || {
  echo "fetching NDK r27c (darwin)"
  mkdir -p "$WORK/ndk"
  curl -sL -o "$WORK/ndk-r27c.zip" \
    https://dl.google.com/android/repository/android-ndk-r27c-darwin.zip
  unzip -q "$WORK/ndk-r27c.zip" -d "$WORK/ndk"
}
# Marker rename (ex2sim -> ex2emu): a tree patched by an older script carries
# legacy markers and would trip the patch asserts below - fetch a pristine
# tree instead of layering on it.
if [ -d "$SS/src" ] && grep -rq "ex2sim:" "$SS/src"; then
  echo "stale patch markers in $SS - re-fetching pristine tree"
  rm -rf "$SS"
fi
[ -f "$SS/src/OpenGL/libEGL/libEGL.cpp" ] || {
  echo "fetching swiftshader $SS_COMMIT"
  curl -sL -o "$WORK/swiftshader-gles.tar.gz" \
    "https://github.com/google/swiftshader/archive/$SS_COMMIT.tar.gz"
  tar xzf "$WORK/swiftshader-gles.tar.gz" -C "$WORK"
  mv "$WORK/swiftshader-$SS_COMMIT" "$SS"
}

# ---- platform headers the NDK sysroot lacks (installed into the sysroot) ----
SR=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include
[ -f "$SR/system/graphics.h" ] || {
  echo "installing platform headers into NDK sysroot (from AOSP android-9)"
  mkdir -p "$SR/cutils" "$SR/system" "$SR/vndk" "$SR/nativebase" "$SR/hardware" "$SR/system"
  G="https://android.googlesource.com/platform/system/core/+/refs/tags/android-9.0.0_r1"
  F="https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-9.0.0_r1"
  for h in graphics.h graphics-base.h graphics-base-v1.0.h graphics-base-v1.1.h graphics-sw.h; do
    curl -sL "$G/libsystem/include/system/$h?format=TEXT" | base64 -d > "$SR/system/$h"
  done
  curl -sL "$G/libcutils/include/cutils/native_handle.h?format=TEXT" | base64 -d > "$SR/cutils/native_handle.h"
  for h in gralloc.h gralloc1.h hardware.h fb.h; do
    curl -sL "$G/libhardware/include/hardware/$h?format=TEXT" | base64 -d > "$SR/hardware/$h"
  done
  curl -sL "$F/libs/nativewindow/include/vndk/window.h?format=TEXT" | base64 -d > "$SR/vndk/window.h"
  curl -sL "$F/libs/nativebase/include/nativebase/nativebase.h?format=TEXT" | base64 -d > "$SR/nativebase/nativebase.h"
}

# ---- link libs: the guest's real LLNDK libraries ----
# libcutils/libhardware are needed for GrallocModule; libnativewindow to pin
# the device's unversioned... (note: P's libnativewindow DOES export
# @@LIBNATIVEWINDOW versioned symbols - version tags are NOT an issue).
[ -f "$LINKLIBS/libnativewindow.so" ] || {
  mkdir -p "$LINKLIBS"
  adb -s 127.0.0.1:5555 pull /system/lib64/libcutils.so      "$LINKLIBS/" >/dev/null
  adb -s 127.0.0.1:5555 pull /system/lib64/libhardware.so    "$LINKLIBS/" >/dev/null
  adb -s 127.0.0.1:5555 pull /system/lib64/libnativewindow.so "$LINKLIBS/" >/dev/null
}

# ---- source patches (idempotent) ----
python3 - "$SS" <<'PY'
import sys, os
ss = sys.argv[1]
def patch(path, old, new, already=None):
    p = os.path.join(ss, path)
    s = open(p).read()
    if old not in s:
        ok = already if already is not None else new
        assert ok in s, f"pattern not found and not already patched: {path}"
        return
    open(p, "w").write(s.replace(old, new, 1))
    print("patched", path)

MARK = "// ex2emu: enabled for NDK builds too"
# 1. EGL_NATIVE_BUFFER_ANDROID branch in CreateImage - without it the buffer
#    pointer is treated as a GL texture name and the NULL context (valid for
#    native-buffer imports) is dereferenced -> SIGSEGV in every GL process.
patch("src/OpenGL/libEGL/libEGL.cpp",
      "\t#if defined(__ANDROID__) && !defined(ANDROID_NDK_BUILD)\n\t\tif(target == EGL_NATIVE_BUFFER_ANDROID)",
      "\t#if defined(__ANDROID__)  " + MARK + "\n\t\tif(target == EGL_NATIVE_BUFFER_ANDROID)",
      already=MARK)
# 2. AndroidNativeImage class + format conversion.
patch("src/OpenGL/common/Image.hpp",
      "#if defined(__ANDROID__) && !defined(ANDROID_NDK_BUILD)\n\ninline GLenum GLPixelFormatFromAndroid",
      "#if defined(__ANDROID__)  " + MARK + "\n\ninline GLenum GLPixelFormatFromAndroid")
# 3. vndk/window.h include in libEGL.cpp (first guard in that file).
patch("src/OpenGL/libEGL/libEGL.cpp",
      "#if defined(__ANDROID__) && !defined(ANDROID_NDK_BUILD)\n#include <vndk/window.h>",
      "#if defined(__ANDROID__)  " + MARK + "\n#include <vndk/window.h>",
      already=MARK)

# 4. GrallocAndroid.cpp must be linked (it is commented out upstream).
p = os.path.join(ss, "src/Common/CMakeLists.txt")
s = open(p).read()
if "GrallocAndroid.cpp  # ex2emu" not in s:
    assert "    # GrallocAndroid.cpp\n" in s
    s = s.replace("    # GrallocAndroid.cpp\n",
                  "    GrallocAndroid.cpp  # ex2emu: needed for EGL_NATIVE_BUFFER_ANDROID\n", 1)
    open(p, "w").write(s)
    print("patched src/Common/CMakeLists.txt")
PY

# ---- build ----
cmake -S "$SS" -B "$SS/build-android" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DSWIFTSHADER_BUILD_EGL=ON -DSWIFTSHADER_BUILD_GLESv2=ON \
  -DSWIFTSHADER_BUILD_VULKAN=OFF -DSWIFTSHADER_BUILD_TESTS=OFF \
  -DSWIFTSHADER_BUILD_PVR=OFF -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SHARED_LINKER_FLAGS="-llog -lsync $LINKLIBS/libcutils.so $LINKLIBS/libhardware.so $LINKLIBS/libnativewindow.so"
ninja -C "$SS/build-android"

echo
echo "built:"
ls -la "$SS/build-android/bin/"libEGL_deprecated_swiftshader.so \
       "$SS/build-android/bin/"libGLESv2_deprecated_swiftshader.so
echo
echo "live test (NOT for daily use - renderer currently renders black):"
echo "  adb shell 'mount -o remount,rw /vendor'"
echo "  adb push $SS/build-android/bin/libEGL_deprecated_swiftshader.so /vendor/lib64/egl/libEGL_swiftshader.so"
echo "  adb push $SS/build-android/bin/libGLESv2_deprecated_swiftshader.so /vendor/lib64/egl/libGLESv2_swiftshader.so"
echo "  adb shell 'chmod 644 /vendor/lib64/egl/*.so; restorecon -R /vendor/lib64/egl; stop; sleep 2; start'"
