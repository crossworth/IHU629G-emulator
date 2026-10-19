#!/usr/bin/env bash
# 20 - boot the firmware's userspace on the substitute kernel, under HVF.
#
# Usage: 20_boot.sh [--timeout N] [--until REGEX] [--grace N] [--vnc]
#                   [--graphic] [--trace]
#
# Everything the guest runs comes from the car dump via work/qemu/ex2.img
# (raw - writes persist). The kernel, DTB and GPT are ours; init, ramdisk
# mods aside, system, vendor and the car's userdata are theirs.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
source tools/qemu/machine.sh

TIMEOUT=180
UNTIL=""
TRACE_GPU=0
GRACE=20
DISPLAY_ARGS="-nographic"
VNC_NOTE=""
MON_SOCK="${MON_SOCK:-/tmp/ex2-monitor.sock}"
LIVE_LOG="${LIVE_LOG:-/tmp/ex2-logcat-live.log}"

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --grace)   GRACE="$2"; shift 2 ;;
    --until)   UNTIL="$2"; shift 2 ;;
    --trace)   TRACE_GPU=1; shift ;;
    # Headless with a monitor socket; screendump via the monitor gives the
    # framebuffer without any display server.
    --graphic) DISPLAY_ARGS="-serial mon:stdio"; shift ;;
    --vnc)     DISPLAY_ARGS="-vnc 127.0.0.1:1 -serial mon:stdio"
               VNC_NOTE="VNC on 127.0.0.1:5901 (display :1 - macOS Screen Sharing occupies 5900)"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require "$QEMU" timeout

# One guest at a time: two QEMUs sharing ex2.img (raw, no CoW) corrupt it
# and produce logs from the wrong VM. macOS comm is NOT truncated like
# Linux - pgrep -x matches the full name here.
if pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
  echo "!! qemu-system-aarch64 already running - stop it first" >&2
  exit 1
fi

RAMDISK="$QDIR/ramdisk-mod.img"
RAMDISK_KIND="modified"
[ -s "$RAMDISK" ] || { RAMDISK="$WORK/boot/ramdisk.img"; RAMDISK_KIND="theirs, unmodified"; }

for f in "$KIMAGE" "$RAMDISK" "$QDIR/virt-android.dtb" "$GPT_IMG"; do
  [ -s "$f" ] || die "missing $f - run 10_kernel/12_dtb/13_ramdisk/14_gpt first"
done

STAMP="$(date +%Y%m%d-%H%M%S)"
BOOTLOG="$OUT/boot/boot-$STAMP.log"

log "booting - log: ${BOOTLOG#$ROOT/}"
log "  kernel   $(basename "$KIMAGE") ($(stat -f %z "$KIMAGE") bytes)"
log "  ramdisk  $RAMDISK_KIND"
log "  disk     $GPT_IMG (raw - writes persist)"
log "  accel    $ACCEL  cpu $CPU  smp $SMP  mem ${MEM}M"
log "  timeout  ${TIMEOUT}s"
[ -n "$VNC_NOTE" ] && log "  display  $VNC_NOTE"

TRACE_ARGS=""
if [ "$TRACE_GPU" = 1 ]; then
  for ev in virtio_gpu_cmd_res_create_2d virtio_gpu_cmd_res_back_attach \
            virtio_gpu_cmd_set_scanout virtio_gpu_cmd_res_xfer_toh_2d \
            virtio_gpu_cmd_res_flush virtio_gpu_cmd_get_display_info; do
    TRACE_ARGS="$TRACE_ARGS -trace enable=$ev"
  done
fi

qemu_guest_args "$RAMDISK"
set -- \
  $(qemu_machine_args) \
  $TRACE_ARGS \
  $DISPLAY_ARGS \
  "${GUEST_ARGS[@]}"

rm -f "$MON_SOCK"
: > "$LIVE_LOG"

printf '# IHU629G-emulator boot log %s\n# cmdline: %s\n\n' "$STAMP" "$CMDLINE" > "$BOOTLOG"

if [ -n "$UNTIL" ]; then
  log "  until    /$UNTIL/ - guest is killed on first match"
  timeout --foreground "$TIMEOUT" "$QEMU" "$@" >> "$BOOTLOG" 2>&1 &
  QPID=$!
  tail -n +1 -f "$BOOTLOG" &
  TAILPID=$!
  MATCHED=no
  while kill -0 "$QPID" 2>/dev/null; do
    if grep -qE "$UNTIL" "$BOOTLOG" 2>/dev/null; then
      MATCHED=yes
      log "  matched - waiting ${GRACE}s for flush, then stopping"
      sleep "$GRACE"
      kill -TERM "$QPID" 2>/dev/null
      sleep 3
      break
    fi
    sleep 2
  done
  wait "$QPID" 2>/dev/null
  kill "$TAILPID" 2>/dev/null
  [ "$MATCHED" = yes ] || log "  pattern never matched"
  RC=0
else
  timeout --foreground "$TIMEOUT" "$QEMU" "$@" 2>&1 | tee -a "$BOOTLOG"
  RC=${PIPESTATUS[0]}
fi

# --- milestone assessment, read from the log --------------------------------
head1 "milestones"
m() { if grep -qE "$2" "$BOOTLOG"; then log "  PASS  $1"; else log "  ----  $1"; fi; }
m "M0 kernel handoff to userspace"  'Freeing unused kernel memory|Run /init as init process'
m "M0 console alive"               'Booting Linux on physical CPU|Linux version'
m "M1 their init started"          'init: init (first|second) stage started|init: init first stage'
m "M1 system mounted"              '__mount\(source=[^)]*,target=/system[^)]*\)=0: Success'
m "M1 vendor mounted"              '__mount\(source=[^)]*,target=/vendor[^)]*\)=0: Success'
m "M2 property service"            'init: starting property service|property_service'
m "M2 servicemanager"              'servicemanager|hwservicemanager'
m "M3 zygote"                      'zygote|Zygote'
m "M3 system_server"               'system_server|SystemServer'
m "M4 surfaceflinger"              'SurfaceFlinger|surfaceflinger'
m "M5 boot completed"              'sys.boot_completed=1'

head1 "failure signals"
grep -oiE 'kernel panic[^\n]{0,80}|Unable to mount[^\n]{0,60}|init: (cannot|failed)[^\n]{0,80}' \
  "$BOOTLOG" | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /' \
  || log "  none matched"

log ""
log "qemu exit $RC"
log "full log: ${BOOTLOG#$ROOT/}"
