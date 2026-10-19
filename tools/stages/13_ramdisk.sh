#!/usr/bin/env bash
# Stage 13 (in-container) - build the modified ramdisk.
#
# Their ramdisk is the base; the changes, each tied to a measured failure:
#
#  1. /sepolicy + monolithic contexts - their init's split-policy detection
#     fails, so it wants the monolithic policy at the ramdisk root.
#  2. drop zygote_secondary (32-bit) - app_process32 SIGABRTs under
#     qemu-user and takes the whole zygote group down every ~5 s.
#  3. mount points from their fstab - fs_mgr silently fails mounts whose
#     target directory does not exist.
#  4. qemu-arm-static + binfmt_misc registration - Apple Silicon has no
#     AArch32 EL0; the firmware's 32-bit services run under qemu-user.
#  5. /init.ecarxp.rc - the slot their init.rc imports; supplies the
#     bootdevice alias, network setup (ex2net), debug shell (ex2sh),
#     bounded logcat, log sizing, display/EGL property selection.
#  6. /adb_keys - pre-authorize this host (ro.adb.secure=1 would otherwise
#     demand a touch dialog before allowing adb).
#
# Everything else of theirs is untouched.
set -eu
cd /project
# Staged in the container's own filesystem, NOT under /project: the macOS
# mount may not preserve modes exactly, and their init refuses init.rc unless
# it is root-owned and not group/world-writable ("Skipping insecure file").
# Extracting from their cpio here preserves the real modes (init 0750).
DST=/root/ramdisk-mod
OUT_RD=work/qemu/ramdisk-mod.img
mkdir -p work/qemu

[ -s work/boot/ramdisk.img ] || { echo "run 05_boot.sh first"; exit 1; }

echo "extracting their ramdisk with modes intact"
rm -rf "$DST"; mkdir -p "$DST"
( cd "$DST" && gzip -dc /project/work/boot/ramdisk.img | cpio -idm --quiet )
echo "  init=$(stat -c %a "$DST/init")  init.rc=$(stat -c %a "$DST/init.rc")"

echo "change 1: monolithic sepolicy"
debugfs -R "dump /etc/selinux/precompiled_sepolicy $DST/sepolicy" firmware/vendor.img 2>/dev/null
[ -s "$DST/sepolicy" ] || { echo "  !! precompiled_sepolicy missing"; exit 1; }
chmod 0644 "$DST/sepolicy"

copy_ctx() {
  local img="$1" src="$2" dst="$3"
  debugfs -R "dump $src $DST/$dst" "$img" 2>/dev/null
  if [ -s "$DST/$dst" ]; then
    chmod 0644 "$DST/$dst"
    echo "  /$dst ok"
  else
    rm -f "$DST/$dst"
    echo "  /$dst absent in source"
  fi
}

echo "change 1b: monolithic contexts"
for n in file_contexts property_contexts seapp_contexts service_contexts \
         hwservice_contexts mac_permissions.xml; do
  copy_ctx firmware/system.img "/etc/selinux/plat_$n" "plat_$n"
done
for n in file_contexts property_contexts seapp_contexts hwservice_contexts; do
  copy_ctx firmware/vendor.img "/etc/selinux/vendor_$n" "vendor_$n"
  [ -s "$DST/vendor_$n" ] && cp "$DST/vendor_$n" "$DST/nonplat_$n"
done
copy_ctx firmware/vendor.img "/etc/selinux/vndservice_contexts" "vndservice_contexts"

echo "change 2: drop zygote_secondary (32-bit) from init.zygote64_32.rc"
# app_process32 under qemu-user-static SIGABRTs during ART startup, and its
# death takes the whole zygote process group down every ~5s - system_server
# never starts. The 64-bit zygote alone is enough for the framework; 32-bit
# standalone daemons still run via binfmt. Revisit: fix qemu-arm for ART if
# 32-bit apps become necessary.
python3 - <<'PY'
import re
p = "/root/ramdisk-mod/init.zygote64_32.rc"
s = open(p).read()
new = re.sub(r"\nservice zygote_secondary .*?(?=\nservice |\Z)", "\n", s, flags=re.S)
assert "zygote_secondary" not in new, "secondary still present"
open(p, "w").write(new)
print("  zygote_secondary service removed")
PY

echo "change 3: mount points from their fstab"
FSTAB_TMP=$(mktemp)
debugfs -R "cat /etc/fstab.ecarxp" firmware/vendor.img >"$FSTAB_TMP" 2>/dev/null
created=0
while read -r _dev mnt _rest; do
  case "$mnt" in /*) ;; *) continue ;; esac
  case "$mnt" in /system|/vendor|/data|/) continue ;; esac
  if [ ! -d "$DST$mnt" ] && [ ! -e "$DST$mnt" ]; then
    mkdir -p "$DST$mnt"; chmod 0771 "$DST$mnt"
    created=$((created+1))
  fi
done < <(grep -vE '^\s*#|^\s*$' "$FSTAB_TMP")
rm -f "$FSTAB_TMP"
echo "  $created mount points created"

echo "change 4: 32-bit ARM support (qemu-arm + binfmt_misc)"
# Apple Silicon has no AArch32 at EL0, and this firmware runs real 32-bit
# services - mediaserver, cameraserver, the MTK media/thermal daemons.
# binfmt_misc routes every 32-bit ARM ELF through qemu-arm.
#
# The binary is OUR build (tools/qemu/40_build_qemu_arm.sh): qemu 8.2 with a
# binder-ioctl passthrough patch - upstream qemu-user rejects binder ioctls
# (type 'b') with ENOTTY because its whitelist doesn't know them, killing
# every 32-bit binder client. The kernel's binder driver accepts 32-bit
# callers natively (compat_ptr_ioctl; layouts are 32/64-identical), so the
# patch forwards the pointer with identity guest_base (stage 40's high link
# address). This revives the needed 32-bit binder services; OMX/hwbinder
# still has a marshalling failure (see BLOCKERS.md).
# The F flag pins the interpreter fd at registration, so it survives the
# later mount over the ramdisk's /system.
if [ -s /project/work/qemu-arm-binder-bin ]; then
  cp /project/work/qemu-arm-binder-bin "$DST/qemu-arm-static"
  chmod 0755 "$DST/qemu-arm-static"
else
  cp /usr/bin/qemu-arm-static "$DST/qemu-arm-static"
  chmod 0755 "$DST/qemu-arm-static"
  echo "  !! using distro qemu-arm (no binder passthrough)"
fi

# magic: ELF32 LSB, machine EM_ARM (0x28); mask matches class/data/version/
# osabi/type-machine fields per qemu-binfmt-conf. The registration LINE is
# generated here in Python - the guest just cats the file into register.
# printf-escape bugs (octal digit counts) cost two boots; bytes are not
# shell's job.
python3 - <<'PY'
magic = bytes([0x7f,0x45,0x4c,0x46,0x01,0x01,0x01,0x00] + [0x00]*8 + [0x02,0x00,0x28,0x00])
mask  = bytes([0xff]*7 + [0x00] + [0xff]*8 + [0xfe,0xff,0xff,0xff])
assert len(magic) == len(mask) == 20
line = f":qemu-arm:M::{magic.hex()}:{mask.hex()}:/qemu-arm-static:F"
# .hex() gives no separators; binfmt_misc wants raw bytes - use escaped form
open("/root/binfmt_line", "wb").write(
    b":qemu-arm:M::" + magic + b":" + mask + b":/qemu-arm-static:F\n")
print("binfmt line:", len(magic), "+", len(mask), "bytes")
PY
cp /root/binfmt_line "$DST/ex2_binfmt_line"
chmod 0644 "$DST/ex2_binfmt_line"

cat > "$DST/ex2_binfmt.sh" <<'SH'
#!/system/bin/sh
# Register the 32-bit ARM ELF binfmt_misc handler. Runs as early as init
# allows; before it is armed, execve of 32-bit binaries fails and init
# retries them on its restart cycle, so a small race is self-healing.
B=/proc/sys/fs/binfmt_misc
# The bare directory exists as soon as the built-in initializes, but it stays
# EMPTY until binfmt_misc is mounted over it. Test for 'register', not for
# the directory - testing -d skipped the mount and cost three boots of
# printf-bug hunting against a target that did not exist.
i=0
while [ ! -e "$B/register" ] && [ $i -lt 30 ]; do
    mount -t binfmt_misc binfmt_misc "$B" 2>/dev/null
    sleep 1
    i=$((i + 1))
done
if [ ! -e "$B/register" ]; then
    echo "EX2BINFMT: register node missing after mount attempts" > /dev/kmsg
    exit 1
fi
if [ -e "$B/qemu-arm" ]; then
    echo "EX2BINFMT: already registered" > /dev/kmsg
    exit 0
fi
if cat /ex2_binfmt_line > "$B/register" 2>/dev/null; then
    echo "EX2BINFMT: armed" > /dev/kmsg
else
    echo "EX2BINFMT: register write failed" > /dev/kmsg
    { echo EX2BINFMT-STATUS; cat "$B/status" 2>&1; ls -l "$B" 2>&1; } > /dev/kmsg
fi
SH
chmod 0750 "$DST/ex2_binfmt.sh"

echo "change 5: /init.ecarxp.rc"
BOOTDEV="${BOOTDEV:-a003e00.virtio_mmio}"
cat > "$DST/init.ecarxp.rc" <<RC
# Supplied by IHU629G-emulator. Their init.rc imports this path and
# their boot image does not provide it. Their vendor
# /etc/init/hw/init.ecarxp.rc is imported separately and stays as-is.

on early-fs
    # Their fstab addresses storage as /dev/block/platform/bootdevice/by-name/*.
    # Under QEMU the controller is $BOOTDEV, so alias it - one symlink makes
    # every fstab entry resolve.
    symlink /dev/block/platform/$BOOTDEV /dev/block/platform/bootdevice

on early-init
    # 64-bit-only zygote: ZygoteInit.hasSecondZygote() == abilist contains a
    # comma. With secondary zygote removed the system_server child would
    # block in waitForSecondaryZygote and wtf-crash. ro.* props are
    # first-write-wins and this runs before build.prop loads.
    setprop ro.product.cpu.abilist arm64-v8a
    setprop ro.product.cpu.abilist64 arm64-v8a
    setprop ro.product.cpu.abilist32 ""
    # Arm 32-bit ARM execution BEFORE any class starts. Apple Silicon has no
    # AArch32; qemu-arm-static + binfmt_misc covers the firmware's 32-bit
    # services (mediaserver, MTK daemons).
    start ex2binfmt
    # EGL: the Mali blob needs its kernel module (absent) and its
    # eglInitialize failure cascades into strlen(NULL) in RenderEngine
    # (documented 81-crash loop). libGLES_android (libagl) is GLES1-only.
    # SwiftShader arm64 (redroid 9) is injected into vendor:/lib64/egl by
    # tools/qemu/15_inject_swiftshader.sh; this selects it.
    setprop ro.hardware.egl swiftshader
    # Display geometry: without these props the framework lays out for the
    # 720x1280 portrait default while fb0 is 1920x1080. Match the car's
    # panel (density 160 already comes from their build.prop).
    setprop ro.boot.redroid_width 1920
    setprop ro.boot.redroid_height 1080
    setprop ro.boot.redroid_fps 60
    # adbd (64-bit, listens on 0.0.0.0) reads this at start; set it before
    # any service comes up so adb over QEMU hostfwd works from boot.
    setprop service.adb.tcp.port 5555
    # logd defaults to 256K/buffer; this guest logs faster than that and the
    # drops hid evidence in the WSL project. Read once when logd starts.
    setprop ro.logd.size 8M
    # Silence vendor spam tags (measured on real E02 hardware by the ECARX
    # community: AudioFlinger "reverse duck" is ~73% of log volume).
    setprop log.tag.AudioFlinger S
    setprop log.tag.APM_AudioPolicyManager S
    setprop log.tag.McuLog S
    # Boot animation blocks in binder if its peer dies; its failure mode is
    # indistinguishable from a hung guest. Not worth a fullscreen surface.
    setprop debug.sf.nobootanimation 1
    # Release ECARX's EVS touch shield; the release path never runs with the
    # camera HALs disabled and the shield eats every touch.
    setprop evsapp.shield_touch 0
    # No sdcardfs module in this kernel; FUSE fallback.
    setprop ro.sys.sdcardfs 0

service ex2binfmt /system/bin/sh /ex2_binfmt.sh
    class core
    user root
    group root
    seclabel u:r:shell:s0
    oneshot

# Bounded logcat to /log (a real partition), readable offline via
# tools/qemu/getlogs.sh.
service ex2logdump /system/bin/logcat -b all -v threadtime -r 8192 -n 2 -f /log/ex2-logcat.txt
    class core
    user logd
    group log root system
    seclabel u:r:logpersist:s0

# Raw-disk safety net: flush the page cache periodically so a hard stop
# loses at most a few seconds of writes.
service ex2sync /system/bin/sh -c "while true; do sync; sleep 3; done"
    class core
    user root
    group root
    seclabel u:r:logpersist:s0

# Live logcat to /dev/hvc0 (virtio-console -> host file /tmp/ex2-logcat-live.log).
service ex2loglive /system/bin/sh -c "exec /system/bin/logcat -b all -v threadtime | grep -vE 'ion_custom_ioctl|ion_set_client|ion_dbg|IOmx/default' > /dev/hvc0"
    class core
    user root
    group root root log
    seclabel u:r:logpersist:s0
    disabled

# Network setup with reconnect loop: their EthernetService never configures
# eth0, and never fills the policy-routing tables unmarked traffic uses.
service ex2net /system/bin/sh /ex2_net.sh
    class core
    user root
    group root
    seclabel u:r:logpersist:s0

# Interactive root shell on a DEDICATED virtio-console port (ex2.shell,
# host side: /tmp/ex2-shell.sock, drive it with tools/qemu/shell.sh).
# The serial console (ttyAMA0) is shared with kmsg and QEMU's stdio/monitor
# mux and drops input bytes; hvcN has no printk traffic and no mux.
service ex2sh /system/bin/sh /ex2_sh.sh
    class late_start
    user root
    group root
    seclabel u:r:shell:s0

# Touchscreen bridge: without it the QEMU usb-tablet's events reach the
# kernel but are invisible to Android (EventHub classes==0 drop).
service ex2touchd /ex2touchd
    class core
    user root
    group root input
    seclabel u:r:shell:s0

on post-fs-data
    # Never suspend: no wake source exists here, sleep looks like a hang.
    write /sys/power/wake_lock ex2emu
    # Legacy sw_sync path used by the hwc2on1 adapter for retire fences.
    symlink /sys/kernel/debug/sync/sw_sync /dev/sw_sync
    chmod 0666 /sys/kernel/debug/sync/sw_sync
    start ex2logdump
    start ex2sync
    start ex2net
    start ex2loglive

# EVS/AVM stack: crashes in GraphicBuffer::lock (no camera hw), restarts
# forever, and its updateLoop competes for the display. Their rc files are
# in system (read-only for us); init override syntax (Pie) lets us add
# \`disabled\` to existing services from OUR rc file.
override
service evsapp /system/bin/evsapp
    disabled

override
service evsengine /system/bin/evsengine
    disabled

override
service evs_manager /system/bin/evs_manager
    disabled

on property:sys.boot_completed=1
    # radio_spi_service is dead even on real hardware (measured by the ECARX
    # community: ~10% of a core + 275 log lines/s). Stop it.
    stop radio_spi_service

RC
chmod 0750 "$DST/init.ecarxp.rc"

cat > "$DST/ex2_sh.sh" <<'SH'
#!/system/bin/sh
# Shell on the dedicated virtio-console port (host: /tmp/ex2-shell.sock).
# Kernel console is ttyAMA0 and hvc0 is the logcat stream; our shell port is
# the next hvc. Probe every hvcN except hvc0 - the exact index depends on
# probe order, not on QEMU's port nr.
echo 0 > /proc/sys/kernel/printk 2>/dev/null
dmesg -n 1 2>/dev/null
TTY=""
i=0
while [ -z "$TTY" ] && [ $i -lt 60 ]; do
  for t in /dev/hvc1 /dev/hvc2 /dev/hvc3; do
    if [ -c "$t" ]; then TTY=$t; break; fi
  done
  [ -z "$TTY" ] && { sleep 1; i=$((i+1)); }
done
if [ -z "$TTY" ]; then
  echo "ex2-sim shell: NO HVC PORT FOUND" > /dev/hvc0
  dmesg | grep -iE "hvc|virtio_console|virtio-ports" > /dev/hvc0 2>&1
  exit 1
fi
echo "ex2-sim shell on $TTY" > /dev/hvc0
exec /system/bin/sh < $TTY > $TTY 2>&1
SH
chmod 0750 "$DST/ex2_sh.sh"

# Separate file, QUOTED heredoc: an unquoted heredoc once expanded \$(...)
# at build time and silently emptied init.ecarxp.rc - costing the bootdevice
# symlink and /data.
cat > "$DST/ex2_net.sh" <<'SH'
#!/system/bin/sh
# Bring up QEMU's user-mode network (slirp) and keep adbd reachable.
#
# Android policy routing: unmarked traffic NEVER consults the main table -
# ip rules 15000-17000 send fwmark-0 sockets to the legacy_system,
# legacy_network and local_network tables, which their EthernetService
# leaves empty because it never configures eth0. Without routes there,
# every connection from an unmarked process (adbd included) dies with
# ENETUNREACH - the adbd TCP listener accepted nothing even though slirp
# completed the host-side handshake. Install the subnet + default route
# into all four tables.
ADDR="10.0.2.15/24"
GW="10.0.2.2"
DEV="eth0"
setup_net() {
    ip link set lo up 2>/dev/null
    ip addr add 127.0.0.1/8 dev lo 2>/dev/null
    ip link set $DEV up 2>/dev/null
    if ! ip addr show $DEV 2>/dev/null | grep -q "$ADDR"; then
        ip addr add $ADDR dev $DEV 2>/dev/null
        echo "EX2NET: configured $DEV $ADDR gw $GW" > /dev/kmsg
    fi
    for t in main legacy_system legacy_network local_network; do
        ip route replace 10.0.2.0/24 dev $DEV scope link table $t 2>/dev/null
        ip route replace default via $GW dev $DEV table $t 2>/dev/null
    done
}
setup_net
while true; do
    sleep 10
    if ! ip route get $GW >/dev/null 2>&1; then
        echo "EX2NET: lost route to $GW, reconfiguring" > /dev/kmsg
        setup_net
    fi
    if ! netstat -tln 2>/dev/null | grep -q ":5555 "; then
        echo "EX2NET: adbd not listening, restarting" > /dev/kmsg
        stop adbd
        start adbd
    fi
done
SH
chmod 0750 "$DST/ex2_net.sh"

echo "change 6: /adb_keys"
ADB_KEY="${ADB_KEY:-/project/work/adbkey.pub}"
if [ -s "$ADB_KEY" ]; then
  cp "$ADB_KEY" "$DST/adb_keys"
  chmod 0640 "$DST/adb_keys"
  echo "  pre-authorised $(basename "$ADB_KEY")"
else
  echo "  no key at $ADB_KEY - adb will require manual authorisation"
fi

echo "change 7: ex2touchd - touchscreen bridge over the usb-tablet"
# Pie's EventHub drops the QEMU usb-tablet: classes==0 because it is neither
# a REL mouse (BTN_MOUSE+REL_X/Y) nor a touchscreen (BTN_TOUCH+ABS_X/Y), so
# host pointer input never reached any Android app. ex2touchd republishes
# the tablet through uinput with BTN_TOUCH (tools/guest/ex2touchd.c).
gcc-9 -O2 -static -Wall -Wextra -o "$DST/ex2touchd" /project/tools/guest/ex2touchd.c
chmod 0755 "$DST/ex2touchd"

echo "repacking"
( cd "$DST" && find . -mindepth 1 -printf '%P\n' \
    | cpio -o -H newc --owner=root:root --quiet ) | gzip -9 > "$OUT_RD"
echo "  $OUT_RD ($(stat -c %s "$OUT_RD") bytes; original $(stat -c %s work/boot/ramdisk.img))"

echo "verifying from the artifact"
gzip -dc "$OUT_RD" | cpio -t --quiet 2>/dev/null | grep -E '^(init|sepolicy|init\.ecarxp\.rc|ex2_net\.sh|ex2_sh\.sh)' | sed 's/^/  /'
