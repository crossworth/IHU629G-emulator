#!/usr/bin/env bash
# Stage 0 (in-container) - fingerprint the firmware.
set -u
cd /project

echo "=== image types ==="
for f in firmware/system.img firmware/vendor.img firmware/boot.img; do
  echo "  $f: $(file -b "$f" | cut -c1-90)"
done

echo "=== filesystem sanity ==="
for p in firmware/system.img firmware/vendor.img; do
  dumpe2fs -h "$p" 2>/dev/null | awk -v p="$p" '
    /^Filesystem volume name/ { v=$4 }
    /^Block count/            { bc=$3 }
    /^Block size/             { bs=$3 }
    END { if (bc) printf "  %-22s label=%-10s %.2f GiB\n", p, v, bc*bs/1073741824 }
  '
done

echo "=== build properties ==="
for f in /system/build.prop /system/etc/prop.default /build.prop /etc/prop.default; do
  out=$(debugfs -R "cat $f" firmware/system.img 2>/dev/null)
  if [ -n "$out" ]; then
    echo "  --- system.img:$f"
    echo "$out" | grep -E "^ro\.(product|build|hardware|ecarx|caf\.variant)" | sed 's/^/  /'
    break
  fi
done
for f in /build.prop /etc/build.prop /default.prop /etc/fstab.*; do
  out=$(debugfs -R "cat $f" firmware/vendor.img 2>/dev/null)
  if [ -n "$out" ] && ! echo "$f" | grep -q fstab; then
    echo "  --- vendor.img:$f"
    echo "$out" | grep -E "^ro\.(product|build|hardware|ecarx)" | sed 's/^/  /'
    break
  fi
done

echo "=== boot image ==="
file firmware/boot.img | sed 's/^/  /'
python3 - <<'PY'
import struct, gzip
d = open("firmware/boot.img","rb").read()
ks, rs, ts, dts = struct.unpack_from("<4I", d, 8)
page = struct.unpack_from("<I", d, 36)[0]
extra = struct.unpack_from("<4I", d, 40)
print(f"  kernel={ks}B ramdisk={rs}B second={ts}B dt={dts}B page={page} extra={extra[0]}B")
k = d[page:page+ks]
print(f"  kernel starts with {k[:4].hex()} (1f8b.. = gzip)")
if k[:2] == b"\x1f\x8b":
    ik = gzip.decompress(k)
    for l in ik.split(b"\n"):
        if b"Linux version" in l:
            print("  " + l.decode(errors="replace")[:150]); break
PY

echo "=== fstab ==="
for f in /etc/fstab.ecarxp /etc/fstab.$(true) ; do :; done
fst=$(debugfs -R "cat /etc/fstab.ecarxp" firmware/vendor.img 2>/dev/null)
if [ -n "$fst" ]; then
  echo "  --- vendor.img:/etc/fstab.ecarxp"
  echo "$fst" | grep -vE '^\s*#|^\s*$' | sed 's/^/  /'
else
  echo "  fstab.ecarxp NOT FOUND in vendor - listing /etc:"
  debugfs -R "ls -l /etc" firmware/vendor.img 2>/dev/null | grep -i fstab | sed 's/^/  /'
fi
