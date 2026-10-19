#!/usr/bin/env bash
# Stage 21 (in-container) - read the guest's /log partition out of ex2.img.
set -eu
cd /project
IMG=work/qemu/ex2.img

sect=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="log"' \
  | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
size=$(sfdisk -d "$IMG" 2>/dev/null | grep -F 'name="log"' \
  | sed -n 's/.*size=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
[ -n "$sect" ] || { echo "no log partition"; exit 1; }

mkdir -p out/guestlogs
# copy only what's populated; the partition is 3 GiB but the copy is sparse
dd if="$IMG" of=out/guestlogs/log.part bs=512 skip="$sect" count="$size" \
  conv=sparse status=none

echo "=== files in /log ==="
debugfs -R "ls -l /" out/guestlogs/log.part 2>/dev/null | head -20

for f in ex2-logcat.txt ex2-logcat.txt.1 ex2-logcat.txt.2; do
  if debugfs -R "stat /$f" out/guestlogs/log.part 2>/dev/null | grep -q Inode:; then
    debugfs -R "dump /$f out/guestlogs/$f" out/guestlogs/log.part 2>/dev/null
    echo "extracted $f ($(stat -c %s out/guestlogs/$f) bytes)"
  fi
done
