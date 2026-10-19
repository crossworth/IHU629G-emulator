#!/usr/bin/env bash
# Stage 23 (in-container) - disable the vendor OMX HAL service.
#
# android.hardware.media.omx@1.0-service (init name: "mediacodec", class
# main) is a 32-bit MTK binary. Since the 32-bit binder fix it starts for
# real - and SIGABRTs ~5 s later, forever: init restarts it, it aborts
# again, one tombstone per cycle (~1/min, all worthless: the backtrace
# under qemu-user unwinds nothing past abort+58). The codecs it would
# register need MTK ION anyway (BLOCKERS.md), so the service can never
# work in this emulator.
#
# Edit: append "disabled" to the service stanza in the vendor rc - init
# will not auto-start it ("class main" trigger skips disabled services).
# The original stanza is kept as .rc.orig inside the image; restore it
# (remove the stage from the rebuild, or put the file back) to re-enable,
# e.g. to debug the SIGABRT itself.
#
# What remains after this: framework clients (media.codec) keep logging
# "Waited one second for IOmx" - logcat-only, no process churn, no disk
# writes; playback was already broken either way.
set -eu
cd /project
IMG=work/qemu/ex2.img

part() {
  sfdisk -d "$IMG" 2>/dev/null | grep -F "name=\"$1\"" | sed -n 's/.*'"$2"'=[[:space:]]*\([0-9]\+\).*/\1/p' | head -1
}
VEN_S=$(part vendor start); VEN_N=$(part vendor size)
VEN=work/qemu/vendor-mod.img
dd if="$IMG" of="$VEN" bs=512 skip="$VEN_S" count="$VEN_N" conv=sparse status=none

RC=/etc/init/android.hardware.media.omx@1.0-service.rc
TMP=$(mktemp -d)
debugfs -R "cat $RC" "$VEN" 2>/dev/null > "$TMP/omx.rc"
grep -q '^service mediacodec ' "$TMP/omx.rc" || { echo "service stanza not found"; exit 1; }

if grep -q '^    disabled$' "$TMP/omx.rc"; then
  echo "already disabled - nothing to do"
else
  cp "$TMP/omx.rc" "$TMP/omx.rc.new"
  printf '    disabled\n' >> "$TMP/omx.rc.new"
  CMDS=$(mktemp)
  {
    echo "cd /etc/init"
    if ! debugfs -R "stat /etc/init/android.hardware.media.omx@1.0-service.rc.orig" "$VEN" >/dev/null 2>&1; then
      echo "rm android.hardware.media.omx@1.0-service.rc.orig"
      echo "write $TMP/omx.rc android.hardware.media.omx@1.0-service.rc.orig"
    fi
    echo "rm android.hardware.media.omx@1.0-service.rc"
    echo "write $TMP/omx.rc.new android.hardware.media.omx@1.0-service.rc"
  } > "$CMDS"
  debugfs -w -f "$CMDS" "$VEN" >/dev/null 2>&1
  rm -f "$CMDS"
  LBL=$(mktemp)
  printf 'u:object_r:vendor_configs_file:s0\0' > "$LBL"
  for f in android.hardware.media.omx@1.0-service.rc android.hardware.media.omx@1.0-service.rc.orig; do
    debugfs -w -R "ea_set -f $LBL /etc/init/$f security.selinux" "$VEN" >/dev/null 2>&1
  done
  rm -f "$LBL"
fi

echo "=== verify ==="
debugfs -R "cat $RC" "$VEN" 2>/dev/null

off=$(( VEN_S * 512 ))
dd if="$VEN" of="$IMG" bs=4M oflag=seek_bytes seek="$off" conv=notrunc,sparse status=none
echo "written back"
rm -rf "$TMP"
