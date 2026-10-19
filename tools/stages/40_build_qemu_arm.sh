#!/usr/bin/env bash
# Stage 40 (in-container) - build qemu-arm-static with the binder ioctl
# passthrough patch (applied textually - the patch file carries context
# lines that drift between versions).
set -eu
cd /project
# Persist on the ex2-kbuild docker volume (survives container recycling);
# /root is ephemeral here.
QROOT=/root/kbuild/qemu
QSRC=$QROOT/qemu-8.2.0
QOUT=work/qemu-arm-binder

mkdir -p "$QROOT"
if [ ! -d "$QSRC" ]; then
  if [ ! -f "$QROOT/qemu-8.2.0.tar.xz" ]; then
    curl -fL -o "$QROOT/qemu-8.2.0.tar.xz" https://download.qemu.org/qemu-8.2.0.tar.xz
  fi
  tar -C "$QROOT" -xf "$QROOT/qemu-8.2.0.tar.xz"
fi

cd "$QSRC"
if ! grep -q "g2h((abi_ulong)arg)" linux-user/syscall.c; then
python3 - <<'PY'
p = "linux-user/syscall.c"
s = open(p, encoding='utf-8').read()
anchor = """    int target_size;
    void *argptr;

    ie = ioctl_entries;"""
repl = """    int target_size;
    void *argptr;

    if (_IOC_TYPE(cmd) == 'b') {
        /* Android binder ioctls: layouts are 32/64-identical and the
         * kernel handles 32-bit callers via compat_ptr_ioctl. Translate
         * the guest address through guest_base (g2h) - qemu-user maps the
         * guest at an offset; a raw guest pointer is NOT a host pointer
         * unless guest_base==0. Unsigned cast: bit-31 cmds sign-extend. */
        return get_errno(safe_ioctl(fd, (unsigned int)cmd,
                                    g2h((abi_ulong)arg)));
    }

    ie = ioctl_entries;"""
assert anchor in s, "anchor not found in do_ioctl"
s = s.replace(anchor, repl, 1)
open(p, 'w', encoding='utf-8').write(s)
print("binder passthrough patched into do_ioctl")
PY
fi

# ex2 patch 3: pretend seccomp prctl success. Upstream returns EINVAL for
# PR_SET_SECCOMP ("prevent the target disabling stuff we need"), but
# Android's libminijail treats that as fatal - the 32-bit mediacodec
# service aborts at startup (prctl(seccomp_filter) failed → SIGABRT).
# A guest filter would constrain qemu-user's own host syscalls with the
# wrong ABI anyway, so claiming success is the only sane emulation.
if ! grep -q "ex2: pretend seccomp success" linux-user/syscall.c; then
python3 - <<'PY'
p = "linux-user/syscall.c"
s = open(p, encoding='utf-8').read()
old = """    case PR_GET_SECCOMP:
    case PR_SET_SECCOMP:
    case PR_SET_SYSCALL_USER_DISPATCH:"""
new = """    case PR_GET_SECCOMP:
    case PR_SET_SECCOMP:
        /* ex2: pretend seccomp success - see stage 40 header. */
        return 0;

    case PR_SET_SYSCALL_USER_DISPATCH:"""
assert old in s, "seccomp case not found in do_prctl"
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print("seccomp fake-success patched into do_prctl")
PY
fi

# Identity guest_base (guest ptr == host ptr) is required by the type-'b'
# binder passthrough: binder_write_read carries NESTED guest pointers
# (write_buffer/read_buffer → command stream → binder_transaction_data →
# parcel data) that qemu cannot translate - they only reach the kernel as
# valid host addresses when guest_base == 0. pgb_dynamic() tries identity
# first but its probe (MAP_FIXED_NOREPLACE over [mmap_min_addr, 4 GiB))
# returns EEXIST while qemu's own non-PIE static image sits at 0x400000:
# identity never wins and every binder_write_read from a 32-bit process
# EFAULTs in the kernel - mediaserver/cameraserver/drm abort 3 ms after
# start, before publishing media.player (b0.S then blocks forever in
# getService("media.player") and the FFmpeg fallback never runs).
# gcc-9 has no rcrt1.o (no -static-pie), so relocate the text segment to
# 8 GiB instead - same effect, stock toolchain.
QBUILD="$QSRC/build"   # meson build dir (qemu's configure wrapper delegates here)
is_high_linked() {
  [ -x "$QBUILD/qemu-arm" ] || return 1
  first_load=$(readelf -lW "$QBUILD/qemu-arm" | awk '/^  LOAD/{print $3; exit}')
  [ "$((first_load))" -ge 4294967296 ] 2>/dev/null
}
if ! is_high_linked; then
  mkdir -p "$QBUILD"
  cd "$QBUILD"
  "$QSRC/configure" \
    --static --target-list=arm-linux-user \
    --extra-ldflags="-Wl,-Ttext-segment=0x200000000" \
    --disable-system --disable-tools --disable-docs \
    --disable-gio --disable-glusterfs --disable-libusb \
    --disable-capstone --disable-slirp --disable-fdt
fi
# Always ninja: source patches applied above must reach an existing build.
ninja -C "$QBUILD" qemu-arm
if ! is_high_linked; then
  echo "qemu-arm linked inside the low 4 GiB - identity guest_base impossible" >&2
  exit 1
fi
mkdir -p /project/work
cp "$QBUILD/qemu-arm" /project/work/qemu-arm-binder-bin
file /project/work/qemu-arm-binder-bin
