#!/usr/bin/env bash
# Boot the guest live: serial console + guest logcat side by side in tmux.
#
#   pane 0   kernel/init serial console
#   pane 1   guest logcat, streamed over virtio-console (/dev/hvc0)
#   screen   VNC on 127.0.0.1:5900
#
# Usage:  live.sh [--timeout N]
#         tmux attach -t ex2live      to watch (Ctrl-b d detaches)
#         live.sh --stop              to stop the guest
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT" || exit 1

SESSION=ex2live
LIVE_LOG=/tmp/ex2-logcat-live.log
SERIAL_LOG=/tmp/ex2-serial-live.log
TIMEOUT=7200

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --stop)
      # Flush the guest's page cache before killing: raw-mode writes go
      # straight to ex2.img and a hard kill replays the ext4 journal to an
      # older but consistent state - silently losing work.
      if command -v adb >/dev/null 2>&1 && pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
        adb connect 127.0.0.1:5555 >/dev/null 2>&1
        if timeout 20 adb -s 127.0.0.1:5555 shell sync >/dev/null 2>&1; then
          echo "  guest sync ok"
        else
          echo "  guest sync skipped (adb unreachable) - recent writes may be lost"
        fi
      fi
      tmux kill-session -t "$SESSION" 2>/dev/null
      pkill -TERM -x qemu-system-aarch64 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x qemu-system-aarch64 >/dev/null 2>&1 || break
        sleep 1
      done
      pkill -KILL -x qemu-system-aarch64 2>/dev/null
      sleep 1
      echo "stopped ($(pgrep -x qemu-system-aarch64 | wc -l | tr -d ' ') guests left)"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
  echo "a guest is already running - stop it first:  $0 --stop" >&2
  exit 1
fi

: > "$LIVE_LOG"
: > "$SERIAL_LOG"

tmux kill-session -t "$SESSION" 2>/dev/null
tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  "cd '$ROOT' && bash tools/qemu/20_boot.sh --vnc --timeout $TIMEOUT 2>&1 | tee '$SERIAL_LOG'"
tmux split-window -t "$SESSION" -h \
  "echo '--- guest logcat (live, via /dev/hvc0) ---'; tail -F '$LIVE_LOG'"
tmux select-pane -t "$SESSION":0.0

cat <<EOF
=== live guest started ===

  watch      tmux attach -t $SESSION      (Ctrl-b d to detach, guest keeps running)
  screen     VNC client -> localhost:5901 (127.0.0.1 only, no auth; :1 because
             macOS Screen Sharing owns 5900)
  stop       $0 --stop
  logs       tail -f $SERIAL_LOG   (kernel + init)
             tail -f $LIVE_LOG     (guest logcat, starts at post-fs-data)
EOF
