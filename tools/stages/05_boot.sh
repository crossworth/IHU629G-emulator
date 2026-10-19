#!/usr/bin/env bash
# Stage 5 (in-container) - unpack boot.img: kernel, ramdisk, second, dtb.
# The kernel gets replaced by ours, but the RAMDISK is theirs and is the
# starting point for tools/qemu/13_ramdisk.sh.
set -u
cd /project
mkdir -p work/boot

python3 - <<'PY'
import struct, os
d = open("firmware/boot.img","rb").read()
def u32(o): return struct.unpack_from("<I", d, o)[0]
ks, rs, ss, ds = u32(8), u32(16), u32(24), u32(40)
page = u32(36)
name = d[48:64].rstrip(b"\0").decode(errors="replace")
cmdline = d[64:576].rstrip(b"\0").decode(errors="replace")
print(f"kernel={ks} ramdisk={rs} second={ss} dt={ds} page={page}")
print(f"name='{name}'")
print(f"cmdline='{cmdline[:120]}'")

def blob(off, size, out):
    open(out,"wb").write(d[off:off+size])

kpages = (ks + page - 1)//page
rpages = (rs + page - 1)//page
spages = (ss + page - 1)//page
blob(page, ks, "work/boot/kernel.bin")
blob(page*(1+kpages), rs, "work/boot/ramdisk.img")
blob(page*(1+kpages+rpages), ss, "work/boot/second.bin")
blob(page*(1+kpages+rpages+spages), ds, "work/boot/dt.bin")
print("extracted kernel.bin ramdisk.img second.bin dt.bin")

k = open("work/boot/kernel.bin","rb").read()
print(f"kernel[0:8]={k[:8].hex()}")
# MTK kernels may carry a 512-byte signature header before the gzip stream
for probe, desc in [(0,"head"),(512,"mtk+512"),(1024,"mtk+1024")]:
    if k[probe:probe+2] == b"\x1f\x8b":
        print(f"  gzip stream found at {desc}")
        import gzip
        ik = gzip.decompress(k[probe:])
        open("work/boot/kernel.gzip.out","wb").write(ik)
        for l in ik.split(b"\n")[:5] + [x for x in ik.split(b"\n") if b"Linux version" in x][:1]:
            print("  " + l.decode(errors="replace")[:150])
        break
else:
    # arm64 raw Image has magic ARM\x64 at 0x38
    print(f"  Image magic at 0x38: {k[0x38:0x3c]!r}")
    strings_out = os.popen("strings -n 12 work/boot/kernel.bin | grep -m2 'Linux version'").read()
    print("  " + strings_out.strip()[:200])
PY

echo "=== ramdisk ==="
file work/boot/ramdisk.img
gzip -dc work/boot/ramdisk.img > work/boot/ramdisk.cpio 2>/dev/null || true
if [ -s work/boot/ramdisk.cpio ]; then
  echo "  entries: $(cpio -t --quiet < work/boot/ramdisk.cpio | wc -l)"
  cpio -t --quiet < work/boot/ramdisk.cpio | grep -E '^(init|init\.rc|init\..*\.rc|sepolicy|default\.prop|file_contexts)' | sed 's/^/  /'
fi

echo "=== second/dt ==="
file work/boot/second.bin work/boot/dt.bin 2>/dev/null | sed 's/^/  /'
