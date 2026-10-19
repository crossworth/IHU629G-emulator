#!/usr/bin/env bash
# Run a command in the guest root shell (dedicated virtio-console port
# "ex2.shell", /dev/hvc1 in guest, unix socket on host) and print its output.
#
#   tools/qemu/shell.sh "dumpsys SurfaceFlinger | head -30" [wait_secs]
#
# The guest shell service (ex2sh) auto-starts at late_start; if the socket
# refuses connections, the guest is not up yet (or booted an old ramdisk).
set -u
SOCK=/tmp/ex2-shell.sock
CMD="${1:?usage: shell.sh \"command\" [wait_secs]}"
WAIT="${2:-5}"

[ -S "$SOCK" ] || { echo "no $SOCK - is the guest running?" >&2; exit 1; }
# Keep stdin open for WAIT seconds so nc keeps reading the reply; the guest
# shell echoes the command back, so filter the echo and our marker out.
{ printf '%s\n' "$CMD"; sleep "$WAIT"; } | nc -U "$SOCK"
echo
