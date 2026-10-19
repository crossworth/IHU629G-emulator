#!/usr/bin/env bash
# run.sh - start the IHU629G emulator with screen, touch and adb.
#
#   ./run.sh              daemon boot, VNC on 127.0.0.1:5901, waits for
#                         boot_completed, opens a VNC window, connects adb
#   ./run.sh --cocoa      native QEMU window instead of VNC
#   ./run.sh --no-open    do not open a VNC client window automatically
#   ./run.sh --stop       graceful stop (guest sync first)
#   ./run.sh --status     show guest state
#   ./run.sh --sync-time  set guest clock to host time (done automatically
#                         while the guest runs - tools/qemu/timesyncd.sh
#                         re-syncs after every host wake; this flag remains
#                         for manual use)
#
# Touch: the usb-tablet device is an absolute pointer - click/drag in the
# window works like the car's touchscreen. adb: 127.0.0.1:5555.
#
# The disk is raw (writes persist). Rebuild from scratch with:
#   tools/qemu/14_gpt.sh --force && tools/qemu/15_inject_swiftshader.sh &&
#   tools/qemu/16_audio.sh && tools/qemu/17_bluetooth.sh &&
#   tools/qemu/18_adbd.sh && tools/qemu/19_display.sh &&
#   tools/qemu/21_aee_stub.sh && tools/qemu/22_usb_public_volume.sh &&
#   tools/qemu/23_disable_omx.sh
set -uo pipefail
cd "$(dirname "$0")"
source tools/lib.sh
source tools/qemu/machine.sh

DISPLAY=vnc
OPEN=1
BOOT_TIMEOUT=300

while [ $# -gt 0 ]; do
  case "$1" in
    --cocoa)   DISPLAY=cocoa; shift ;;
    --no-open) OPEN=0; shift ;;
    --stop)
      if command -v adb >/dev/null 2>&1 && pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
        adb connect 127.0.0.1:5555 >/dev/null 2>&1
        timeout 20 adb -s 127.0.0.1:5555 shell sync >/dev/null 2>&1 \
          && echo "guest sync ok" \
          || echo "guest sync skipped (adb unreachable) - recent writes may be lost"
      fi
      pkill -TERM -x qemu-system-aarch64 2>/dev/null
      for _ in $(seq 10); do
        pgrep -x qemu-system-aarch64 >/dev/null 2>&1 || break
        sleep 1
      done
      pkill -KILL -x qemu-system-aarch64 2>/dev/null
      echo "stopped"
      exit 0 ;;
    --status)
      if pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
        echo "qemu: running (pid $(pgrep -x qemu-system-aarch64))"
        adb connect 127.0.0.1:5555 >/dev/null 2>&1
        bc=$(timeout 10 adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        echo "boot_completed: ${bc:-unknown}"
        echo "adb: $(adb devices | grep -c '127.0.0.1:5555.*device$') device(s) on 127.0.0.1:5555"
      else
        echo "qemu: not running"
      fi
      exit 0 ;;
    --sync-time)
      adb connect 127.0.0.1:5555 >/dev/null 2>&1
      if out=$(timeout 10 adb -s 127.0.0.1:5555 shell date "$(date '+%m%d%H%M%Y.%S')" 2>&1); then
        echo "guest clock synced: $(echo "$out" | tr -d '\r')"
      else
        echo "failed to set guest clock (adb unreachable or not rooted): $(echo "$out" | tr -d '\r')" >&2
        exit 1
      fi
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

require "$QEMU" timeout

if pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
  echo "a guest is already running - $0 --stop first, or --status" >&2
  exit 1
fi

RAMDISK="$QDIR/ramdisk-mod.img"
for f in "$KIMAGE" "$RAMDISK" "$QDIR/virt-android.dtb" "$GPT_IMG"; do
  [ -s "$f" ] || die "missing $f - run the pipeline first (see header)"
done

MON_SOCK=/tmp/ex2-monitor.sock
LIVE_LOG=/tmp/ex2-logcat-live.log
qemu_guest_args "$RAMDISK"

VNC_PASSWORD=ex2emu

case "$DISPLAY" in
  # password=on: macOS Screen Sharing refuses QEMU's auth-type "None"
  vnc)   DISP_ARGS=(-vnc "127.0.0.1:1,password=on" -daemonize) ;;
  cocoa) DISP_ARGS=(-display cocoa) ;;
esac

SERIAL_LOG=/tmp/ex2-run-serial.log
rm -f "$MON_SOCK"
: > "$LIVE_LOG"
: > "$SERIAL_LOG"

log "starting guest - serial: $SERIAL_LOG"
if [ "$DISPLAY" = cocoa ]; then
  # cocoa needs the main run loop: no -daemonize, detach with nohup instead
  # shellcheck disable=SC2046
  nohup "$QEMU" $(qemu_machine_args) "${DISP_ARGS[@]}" -serial "file:$SERIAL_LOG" \
    "${GUEST_ARGS[@]}" >>"$SERIAL_LOG" 2>&1 &
  disown
else
  # shellcheck disable=SC2046
  "$QEMU" $(qemu_machine_args) "${DISP_ARGS[@]}" -serial "file:$SERIAL_LOG" \
    "${GUEST_ARGS[@]}" >>"$SERIAL_LOG" 2>&1 || die "qemu failed to start"
fi

if [ "$DISPLAY" = vnc ]; then
  # QEMU starts rejecting VNC logins until a password is set - set it
  # immediately via the monitor socket, before the boot wait.
  (printf 'change vnc password "%s"\n' "$VNC_PASSWORD"; sleep 1) | nc -U "$MON_SOCK" >/dev/null 2>&1
fi

log "waiting for sys.boot_completed (up to ${BOOT_TIMEOUT}s)..."
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
ok=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  pgrep -x qemu-system-aarch64 >/dev/null 2>&1 || { tail -20 "$SERIAL_LOG"; die "qemu died during boot"; }
  adb connect 127.0.0.1:5555 >/dev/null 2>&1
  bc=$(timeout 8 adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  if [ "$bc" = 1 ]; then ok=1; break; fi
  sleep 5
done
[ -n "$ok" ] || die "boot did not complete in ${BOOT_TIMEOUT}s - check $SERIAL_LOG and $LIVE_LOG"

# Without an MCU the VHAL store boots on nonsense defaults (reverse gear,
# night, 0% battery) and apps react to them (drive restrictions, energy
# widget). Inject the parked-car baseline - what the MCU would report.
if command -v python3 >/dev/null 2>&1; then
  python3 tools/qemu/vhalctl.py park >/dev/null 2>&1 \
    && log "vhal: parked-car baseline applied (gear=PARK, day, SoC 80%)" \
    || log "vhal: baseline injection failed (non-fatal) - vhalctl.py park to retry"
fi

# Guest clock falls behind while the Mac sleeps (QEMU clock pauses, the
# kernel never re-reads the RTC). Watch for host wakes and re-sync over adb.
nohup tools/qemu/timesyncd.sh >/dev/null 2>&1 &
disown
log "timesyncd: guest clock will re-sync automatically after host sleeps"

if [ "$DISPLAY" = vnc ] && [ "$OPEN" = 1 ]; then
  open vnc://127.0.0.1:5901 >/dev/null 2>&1 || true
fi

cat <<EOF

=== IHU629G head unit is up ===

  screen   $([ "$DISPLAY" = vnc ] && echo "VNC 127.0.0.1:5901, password: $VNC_PASSWORD" || echo "QEMU cocoa window")
  touch    click/drag in the window (absolute pointer)
  adb      adb connect 127.0.0.1:5555  ($([ -n "$(adb devices 2>/dev/null | grep '127.0.0.1:5555.*device$')" ] && echo connected || echo connect manually))
  shell    adb -s 127.0.0.1:5555 shell
  stop     $0 --stop
  status   $0 --status
  clock    synced automatically after host sleeps (timesyncd.sh)
  vhal     python3 tools/qemu/vhalctl.py park|night|set|setf|get|all
  logs     tail -f $LIVE_LOG   (logcat)
           tail -f $SERIAL_LOG (kernel/init)
EOF
