#!/usr/bin/env bash
# Stage 12 (in-container) - decompile raw DTB, inject fstab node, recompile.
# Usage: 12_dtb_inject.sh <raw.dtb> <out.dtb> <by-name-dir>
set -eu
cd /project
RAW="$1"; OUT="$2"; BYNAME="$3"

dtc -I dtb -O dts -o work/qemu/virt-raw.dts "$RAW" 2>/dev/null

BYNAME="$BYNAME" python3 - <<'PY'
import os, re
src, dst = 'work/qemu/virt-raw.dts', 'work/qemu/virt-android.dts'
dts = open(src, encoding='utf-8', errors='replace').read()
BYNAME = os.environ['BYNAME']
NODE = '''
\tfirmware {
\t\tandroid {
\t\t\tcompatible = "android,firmware";
\t\t\tfstab {
\t\t\t\tcompatible = "android,fstab";
\t\t\t\tsystem {
\t\t\t\t\tcompatible = "android,system";
\t\t\t\t\tdev = "@BYNAME@/system";
\t\t\t\t\ttype = "ext4";
\t\t\t\t\tmnt_flags = "ro";
\t\t\t\t\tfsmgr_flags = "wait";
\t\t\t\t};
\t\t\t\tvendor {
\t\t\t\t\tcompatible = "android,vendor";
\t\t\t\t\tdev = "@BYNAME@/vendor";
\t\t\t\t\ttype = "ext4";
\t\t\t\t\tmnt_flags = "ro";
\t\t\t\t\tfsmgr_flags = "wait";
\t\t\t\t};
\t\t\t};
\t\t};
\t};
'''.replace('@BYNAME@', BYNAME)
if 'android,firmware' in dts:
    dts = re.sub(r'\n\tfirmware \{.*?\n\t\};\n', '\n', dts, flags=re.S)
i = dts.rstrip().rfind('};')
assert i > 0, 'no root close brace'
open(dst, 'w', encoding='utf-8').write(dts[:i] + NODE + dts[i:])
print('wrote ' + dst)
PY

dtc -I dts -O dtb -o "$OUT" work/qemu/virt-android.dts 2>/dev/null
echo "compiled $(stat -c %s "$OUT") bytes"

# Verify from the blob, not the source: what the guest sees is the blob.
dtc -I dtb -O dts "$OUT" 2>/dev/null | python3 -c '
import re, sys
t = sys.stdin.read()
m = re.search(r"fstab \{(.*?)\n\t\t\t\};", t, re.S)
assert m, "no fstab node in compiled DTB"
found = re.findall(r"(\w+) \{\s*compatible = \"android,(\w+)\";\s*dev = \"([^\"]+)\"", m.group(1))
for name, compat, dev in found:
    print(f"  {name:<10} dev={dev}")
assert len(found) == 2
print("OK: 2 early mounts in the blob")
'
