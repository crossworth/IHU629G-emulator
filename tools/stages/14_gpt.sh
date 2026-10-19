#!/usr/bin/env bash
# Stage 14 (in-container) - build the one GPT disk the guest boots from.
#
# Every partition their fstab references gets a real GPT entry named exactly
# as expected, so their by-name paths resolve. Partitions that exist in the
# car dump are dd'd in from /dump (read-only mount); the rest are left zeroed
# (fs_mgr formats formattable ones on first boot, as on a factory unit).
#
# The dump's own images are never written. Output: work/qemu/ex2.img.
set -eu
cd /project
DUMP="${EX2_DUMP:-/dump}"
OUT=work/qemu/ex2.img

if [ -f "$OUT" ] && [ "${1:-}" != "--force" ]; then
  echo "exists: $OUT (pass --force to rebuild)"
  exit 0
fi

# name:size-or-'dump'  - 'dump' = take the image from /dump/<name>.img
declare -a PARTS=(
  "proinfo:dump" "nvram:dump" "protect1:dump" "protect2:dump"
  "lk:dump" "lk2:dump" "boot:dump" "boot_para:dump" "para:dump"
  "recovery:dump" "logo:dump" "expdb:dump" "seccfg:dump"
  "otp:dump" "tee1:dump" "tee2:dump" "scp1:dump" "scp2:dump"
  "sspm_1:dump" "sspm_2:dump" "spmfw:dump" "gz1:dump" "gz2:dump"
  "dtbo:dump" "frp:dump" "nvcfg:dump" "nvdata:dump" "metadata:dump"
  "persist:dump" "pki:dump" "private_ui:dump" "vechilecfg:dump"
  "system:dump" "vendor:dump" "cache:dump" "userdata:dump"
  "mtkdata:dump" "log:dump"
  "update:536870912"
  "md1img:dump" "md1dsp:dump" "md1arm7:dump" "md3img:dump"
  "cam_vpu1:dump" "cam_vpu2:dump" "cam_vpu3:dump" "odmdtbo:dump"
)

# resolve sizes
declare -a LAYOUT=()   # "name:bytes:src(or empty)"
for p in "${PARTS[@]}"; do
  name="${p%%:*}"; spec="${p#*:}"
  if [ "$spec" = dump ]; then
    img="$DUMP/$name.img"
    [ -r "$img" ] || { echo "  !! $img missing in dump - skipping $name"; continue; }
    sz=$(stat -c %s "$img")
    LAYOUT+=("$name:$sz:$img")
  else
    LAYOUT+=("$name:$spec:")
  fi
done

# recompute TOTAL properly from LAYOUT
TOTAL=$((34*1024*1024))
for e in "${LAYOUT[@]}"; do TOTAL=$((TOTAL + $(echo "$e" | cut -d: -f2))); done
echo "total virtual size: $(numfmt --to=iec $TOTAL)"

truncate -s 0 "$OUT"
truncate -s "$TOTAL" "$OUT"

{
  echo 'label: gpt'
  echo 'unit: sectors'
  START=2048
  for e in "${LAYOUT[@]}"; do
    IFS=: read -r name sz src <<<"$e"
    n=$(( (sz + 511) / 512 ))
    START=$(( (START + 2047) / 2048 * 2048 ))
    echo "start=$START, size=$n, type=8DA63339-0007-60C0-C436-083AC8230908, name=\"$name\""
    START=$(( START + n ))
  done
} | sfdisk --quiet "$OUT"

offset_of() {
  sfdisk -d "$OUT" 2>/dev/null | grep -F "name=\"$1\"" \
    | sed -n 's/.*start=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1
}

copied=0
for e in "${LAYOUT[@]}"; do
  IFS=: read -r name sz src <<<"$e"
  sect=$(offset_of "$name") || { echo "  !! no partition $name"; continue; }
  off=$(( sect * 512 ))
  [ "$off" -gt 0 ] || { echo "  !! $name at offset 0"; continue; }
  if [ -n "$src" ]; then
    # conv=sparse: zero runs in the source become holes in ex2.img
    dd if="$src" of="$OUT" bs=4M oflag=seek_bytes seek="$off" \
      conv=notrunc,sparse status=none
    copied=$((copied+1))
    echo "  $name <- $(basename "$src") ($(numfmt --to=iec $sz))"
  fi
done

echo "copied $copied partitions from the dump"

# verify ext4 magic for the two early mounts
for name in system vendor; do
  off=$(( $(offset_of "$name") * 512 ))
  magic=$(dd if="$OUT" bs=1 skip=$((off + 1080)) count=2 status=none | xxd -p)
  [ "$magic" = "53ef" ] && echo "  $name: ext4 superblock OK" \
                       || echo "  !! $name: expected 53ef, got $magic"
done

echo "done: $OUT"
