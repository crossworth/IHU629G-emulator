#!/usr/bin/env bash
# timesyncd.sh - keep the guest clock in step with the host across Mac sleeps.
#
# QEMU's virtual clock pauses while the host sleeps and the guest kernel
# never re-reads the RTC after boot, so the Android clock falls behind by
# the sleep duration. This watcher detects the wall-clock jump on wake and
# pushes the host time over adb (same mechanism as `run.sh --sync-time`).
#
# Spawned by run.sh after boot; exits on its own once QEMU is gone.
#
#   timesyncd.sh          watch loop (INTERVAL/THRESHOLD envs, seconds)
#   timesyncd.sh --now    sync once immediately, then exit (manual use/tests)
set -uo pipefail
cd "$(dirname "$0")/../.."

ADB_SERIAL=127.0.0.1:5555
INTERVAL="${TIMESYNC_INTERVAL:-15}"
THRESHOLD="${TIMESYNC_THRESHOLD:-30}"

sync_now() {
  adb connect "$ADB_SERIAL" >/dev/null 2>&1
  adb -s "$ADB_SERIAL" shell date "$(date '+%m%d%H%M%Y.%S')" >/dev/null 2>&1
}

if [ "${1:-}" = "--now" ]; then
  sync_now && echo "guest clock synced" && exit 0
  echo "guest clock sync failed (adb unreachable?)" >&2
  exit 1
fi

last=$(date +%s)
while pgrep -x qemu-system-aarch64 >/dev/null 2>&1; do
  sleep "$INTERVAL"
  now=$(date +%s)
  if [ $((now - last - INTERVAL)) -gt "$THRESHOLD" ]; then
    echo "$(date '+%F %T') host sleep detected, syncing guest clock" \
      >> /tmp/ex2-logcat-live.log
    # adb may still be re-establishing right after wake - retry briefly
    for _ in 1 2 3; do
      sync_now && break
      sleep 5
    done
  fi
  last=$now
done
