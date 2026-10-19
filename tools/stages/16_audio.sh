#!/usr/bin/env bash
# Stage 16 (in-container) - make audio work under the emulator.
#
# Three changes, all forced by the same root cause: the firmware's audio
# binaries are 32-bit MediaTek builds, and 32-bit processes die under
# qemu-user-static (no binder ioctl support). SystemServer blocks in
# StartAudioService until media.audio_flinger publishes, so this is boot
# critical.
#
#   system:/bin/audioserver          <- android-28 GSI 64-bit (arm64 native)
#   system:/lib64/libaudioflinger.so <- GSI copy; the firmware's 64-bit one
#     carries ELF TLS DT entries that Pie's linker rejects ("unsupported ELF
#     TLS DT entry"). GSI copy is TLS-free, identical NEEDED list.
#   system:/lib64/libaaudioservice.so <- GSI (only missing audioserver dep)
#   vendor:/bin/hw/android.hardware.audio@4.0-service-mediatek <- GSI 64-bit
#     service (name stays theirs - init rc resolves by name; registers both
#     @2.0 and @4.0 IDevicesFactory)
#   vendor:/lib64/hw/android.hardware.audio{,.effect}@4.0-impl.so <- GSI pair
#   vendor:/lib64/hw/audio.primary.ecarxp.so <- content replaced with the
#     firmware's own audio.primary.default.so (tinyalsa stub, fails
#     gracefully without hw:0,0). The MTK blob blocks forever in a futex
#     waiting for audio hardware that does not exist here.
#
# SELinux labels are preserved from the files being replaced where possible
# (debugfs writes drop security.selinux xattrs).
set -eu
cd /project
IMG=work/qemu/ex2.img
G=work/gsi28-audio

for f in work/audioserver-aosp9 work/libaaudioservice.so work/libaudioflinger-gsi.so \
         "$G/service" "$G/audio4-impl.so" "$G/audiofx4-impl.so"; do
  [ -s "$f" ] || { echo "missing $f - run tools/02_blobs.sh"; exit 1; }
done

part() { # part <name> -> "start size"
  sfdisk -d "$IMG" 2>/dev/null | grep -F "name=\"$1\"" \
    | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*size=[[:space:]]*\([0-9]\+\).*/\1 \2/p' | head -1
}

writeback() { # writeback <partition-img> <start-sector>
  dd if="$1" of="$IMG" bs=4M oflag=seek_bytes seek="$(( $2 * 512 ))" conv=notrunc,sparse status=none
}

# --- system partition: audioserver + libs -----------------------------------
read -r ssect ssize <<< "$(part system)"
S=work/qemu/system-mod.img
dd if="$IMG" of="$S" bs=512 skip="$ssect" count="$ssize" conv=sparse status=none

AUD_LABEL=$(debugfs -R "ea_list /bin/audioserver" "$S" 2>/dev/null | grep -o 'u:object_r:[a-z_]*:s0' | head -1)
echo "  original audioserver label: ${AUD_LABEL:-none}"
[ -n "$AUD_LABEL" ] || { echo "refusing to write without a label to copy"; exit 1; }

CMDS=$(mktemp)
{
  echo "cd /bin"
  echo "rm audioserver"
  echo "write /project/work/audioserver-aosp9 audioserver"
  echo "sif audioserver mode 0100755"
  echo "cd /lib64"
  echo "rm libaaudioservice.so"
  echo "write /project/work/libaaudioservice.so libaaudioservice.so"
  echo "sif libaaudioservice.so mode 0100644"
  echo "rm libaudioflinger.so"
  echo "write /project/work/libaudioflinger-gsi.so libaudioflinger.so"
  echo "sif libaudioflinger.so mode 0100644"
} > "$CMDS"
debugfs -w -f "$CMDS" "$S" 2>&1 | grep -E 'Allocated|Error' || true
rm -f "$CMDS"

printf '%s\0' "$AUD_LABEL" > /tmp/lbl_a
printf 'u:object_r:system_file:s0\0' > /tmp/lbl_l
debugfs -w -R "ea_set -f /tmp/lbl_a /bin/audioserver security.selinux" "$S" >/dev/null 2>&1
debugfs -w -R "ea_set -f /tmp/lbl_l /lib64/libaaudioservice.so security.selinux" "$S" >/dev/null 2>&1
debugfs -w -R "ea_set -f /tmp/lbl_l /lib64/libaudioflinger.so security.selinux" "$S" >/dev/null 2>&1

echo "=== system verify ==="
debugfs -R "ea_list /bin/audioserver" "$S" 2>/dev/null | grep -o 'u:object_r:[a-z_]*' | head -1
debugfs -R "stat /bin/audioserver" "$S" 2>/dev/null | grep Size
writeback "$S" "$ssect"

# --- vendor partition: HAL service + impls + stub primary -------------------
read -r vsect vsize <<< "$(part vendor)"
V=work/qemu/vendor-mod.img
dd if="$IMG" of="$V" bs=512 skip="$vsect" count="$vsize" conv=sparse status=none

SVC_LABEL=$(debugfs -R "ea_list /bin/hw/android.hardware.audio@4.0-service-mediatek" "$V" 2>/dev/null | grep -o 'u:object_r:[a-z_]*:s0' | head -1)
echo "  service label: ${SVC_LABEL:-none}"
[ -n "$SVC_LABEL" ] || exit 1

debugfs -R "dump /lib64/hw/audio.primary.default.so /tmp/apd.so" "$V" 2>/dev/null
[ -s /tmp/apd.so ] || { echo "audio.primary.default.so missing in vendor"; exit 1; }

CMDS=$(mktemp)
{
  echo "cd /bin/hw"
  echo "rm android.hardware.audio@4.0-service-mediatek"
  echo "write /project/$G/service android.hardware.audio@4.0-service-mediatek"
  echo "sif android.hardware.audio@4.0-service-mediatek mode 0100755"
  echo "cd /lib64/hw"
  echo "rm android.hardware.audio@4.0-impl.so"
  echo "write /project/$G/audio4-impl.so android.hardware.audio@4.0-impl.so"
  echo "sif android.hardware.audio@4.0-impl.so mode 0100644"
  echo "rm android.hardware.audio.effect@4.0-impl.so"
  echo "write /project/$G/audiofx4-impl.so android.hardware.audio.effect@4.0-impl.so"
  echo "sif android.hardware.audio.effect@4.0-impl.so mode 0100644"
  echo "rm audio.primary.ecarxp.so"
  echo "write /tmp/apd.so audio.primary.ecarxp.so"
  echo "sif audio.primary.ecarxp.so mode 0100644"
} > "$CMDS"
debugfs -w -f "$CMDS" "$V" 2>&1 | grep -E 'Allocated|Error' || true
rm -f "$CMDS"

printf '%s\0' "$SVC_LABEL" > /tmp/lbl_s
printf 'u:object_r:same_process_hal_file:s0\0' > /tmp/lbl_h
debugfs -w -R "ea_set -f /tmp/lbl_s /bin/hw/android.hardware.audio@4.0-service-mediatek security.selinux" "$V" >/dev/null 2>&1
for p in /lib64/hw/android.hardware.audio@4.0-impl.so \
         /lib64/hw/android.hardware.audio.effect@4.0-impl.so \
         /lib64/hw/audio.primary.ecarxp.so; do
  debugfs -w -R "ea_set -f /tmp/lbl_h $p security.selinux" "$V" >/dev/null 2>&1
done

echo "=== vendor verify ==="
debugfs -R "ls -l /bin/hw" "$V" 2>/dev/null | grep "audio@4.0-service"
debugfs -R "ls -l /lib64/hw" "$V" 2>/dev/null | grep -E "audio.primary|audio@4.0-impl|audio.effect@4.0-impl"
writeback "$V" "$vsect"
echo "written back"
