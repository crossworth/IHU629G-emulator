#!/usr/bin/env bash
# Shared QEMU machine definition. Sourced by 12_dtb.sh, 20_boot.sh, live.sh.
#
# These scripts MUST agree: QEMU generates the virt device tree from the
# machine configuration, so a DTB dumped under one CPU count or memory size
# does not describe the machine another invocation creates.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/work"
QDIR="$WORK/qemu"
OUT="$ROOT/out"
FW="$ROOT/firmware"

mkdir -p "$QDIR" "$OUT/boot"

# --- host tools -------------------------------------------------------------

QEMU="${EX2_QEMU:-qemu-system-aarch64}"

# --- machine ----------------------------------------------------------------

MACHINE="virt"
# -cpu host: on macOS, HVF virtualizes the actual Apple Silicon cores. The
# WSL project used cortex-a53 to match dalvik.vm.isa.arm64.variant, but HVF
# on aarch64 requires -cpu host; ART detects the real core at runtime anyway.
# Changing this invalidates virt-android.dtb: rerun 12_dtb.sh after touching.
CPU="${EX2_CPU:-host}"
SMP="${EX2_SMP:-8}"
MEM="${EX2_MEM:-6144}"

# HVF: native virtualization. This is the whole reason the project exists on
# this machine - the WSL/TCG project's Watchdog kills were CPU starvation.
ACCEL="${EX2_ACCEL:-hvf}"

# --- kernel ------------------------------------------------------------------

KERNEL_VERSION="${EX2_KERNEL_VERSION:-4.14.336}"
KIMAGE="$QDIR/Image"

# --- disk --------------------------------------------------------------------

GPT_IMG="$QDIR/ex2.img"

# --- kernel command line ------------------------------------------------------
#
# androidboot.hardware selects their init.ecarxp.rc (vendor) plus ours
# (ramdisk). enforcing=0 + selinux_pin_permissive=1 keep SELinux permissive:
# their user-build init calls setenforce(1) itself (see kernel patch).
#
# NO qemu=1 on the cmdline (removed 2026-08-14): SystemServer reads
# ro.kernel.qemu and skips BluetoothManagerService ("No Bluetooth Service
# (emulator)") - SystemUI's Flyme plugin then NPEs on a null BT binder and
# crash-loops. SwiftShader selection does NOT need it: Pie's Loader calls
# load_updated_driver FIRST, which opens lib<kind>_<ro.hardware.egl>.so from
# the driver namespace (verified in android-9.0.0_r46 Loader.cpp). The
# Mali blob must be removed from /vendor/lib64/egl though - otherwise the
# fallback scan (load_system_driver, pattern libGLES_*) grabs it. See
# tools/stages/19_display.sh.
CMDLINE="console=ttyAMA0,115200 earlycon=pl011,0x9000000 \
enforcing=0 selinux_pin_permissive=1 \
androidboot.hardware=ecarxp \
androidboot.redroid_width=1920 androidboot.redroid_height=1080 androidboot.redroid_fps=60 \
androidboot.bootdevice=a003e00.virtio_mmio \
androidboot.console=ttyAMA0 \
androidboot.selinux=permissive \
androidboot.verifiedbootstate=orange \
androidboot.veritymode=disabled \
androidboot.serialno=ex2emu0001 \
vt.global_cursor_default=0 \
loglevel=7 printk.devkmsg=on rootwait audit=0 video=1920x1080e"

qemu_machine_args() {
  local extra="${1:-}"
  local m="$MACHINE"
  [ -n "$extra" ] && m="$MACHINE,$extra"
  printf '%s' "-M $m -cpu $CPU -smp $SMP -m $MEM -accel $ACCEL"
}

# Everything the guest needs except the display and tracing options, which
# the caller picks (-nographic, -vnc, cocoa). Fills the GUEST_ARGS array;
# sockets and logs default to the usual /tmp paths, override via env.
#
# Single GPT disk on the MMIO bus: virtio-mmio devices appear under
# /sys/devices/platform, which ueventd needs for the by-name symlinks their
# fstab resolves through the bootdevice alias. PCI would not.
# Touch input is a usb-tablet (absolute pointer - what a car touchscreen is).
qemu_guest_args() {
  local ramdisk="${1:-$QDIR/ramdisk-mod.img}"
  MON_SOCK="${MON_SOCK:-/tmp/ex2-monitor.sock}"
  SHELL_SOCK="${SHELL_SOCK:-/tmp/ex2-shell.sock}"
  LIVE_LOG="${LIVE_LOG:-/tmp/ex2-logcat-live.log}"
  GUEST_ARGS=(
    -name IHU629G-emulator
    -monitor "unix:$MON_SOCK,server,nowait"
    -chardev "file,id=ex2log,path=$LIVE_LOG"
    -device virtio-serial-pci,id=ex2vser
    -device virtconsole,chardev=ex2log,name=ex2.logcat
    -chardev "socket,id=ex2sh,path=$SHELL_SOCK,server=on,wait=off"
    -device virtconsole,chardev=ex2sh,name=ex2.shell
    -kernel "$KIMAGE"
    -initrd "$ramdisk"
    -dtb "$QDIR/virt-android.dtb"
    -append "$CMDLINE"
    -drive "file=$GPT_IMG,format=raw,if=none,id=hd0"
    -device virtio-blk-device,drive=hd0
    -device "virtio-gpu-pci,xres=1920,yres=1080,edid=${EX2_EDID:-on}"
    -device qemu-xhci,id=ex2usb
    -device usb-tablet,bus=ex2usb.0
    -device usb-kbd,bus=ex2usb.0
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=tcp:127.0.0.1:33452-:33452
    -device virtio-net-device,netdev=net0
    -no-reboot
  )
}
