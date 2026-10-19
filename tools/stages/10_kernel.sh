#!/usr/bin/env bash
# Stage 10 (in-container) - build the substitute kernel, Linux 4.14.336 arm64.
#
# Runs NATIVELY on the arm64 container (gcc-9 is Ubuntu 20.04's default);
# no cross prefix. Seven patches, all load-bearing:
#
#   1. virtio-gpu: transfer any 2D scanout buffer to the host, not only dumb
#      ones. Without it SET_SCANOUT/RESOURCE_FLUSH fire but the host never
#      re-reads the pixels - a perfectly healthy guest with a blank screen.
#
#   2. selinuxfs: selinux_pin_permissive=1 ignores userspace setenforce(1).
#      Their user build calls setenforce(1) itself; a cpio ramdisk carries no
#      SELinux labels, so enforcement would kill init immediately.
#
#   3. arm64_personality: strip PER_LINUX32 instead of EINVAL (bionic aborts
#      32-bit processes on failure; they run under qemu-user anyway).
#
#   4. virtio-gpu fbdev: ABGR8888 (RGBA byte order, what the gralloc/
#      composer actually writes) + fix.smem_len so the classic libhardware
#      gralloc can open /dev/graphics/fb0 (plus CONFIG_DRM_FBDEV_OVERALLOC=200
#      for front+back). ARGB8888 displayed a perfect R/B channel swap.
#
#   4b. virtio-gpu fbdev: wire fb_deferred_io (screen_base, dumb, fbdefio) -
#      event-driven dirty tracking of userspace fb writes; this is what
#      pushes presented frames to the host scanout, at up to ~60 Hz.
#
#   5. xt_qtaguid backport (tools/kernel-patches/): Pie's NPMS crash-loops
#      system_server without /proc/net/xt_qtaguid/ctrl.
#
#   6. ex2emu_ipo_pin44 (tools/kernel-patches/): fake
#      /proc/bicv_ipo_dir/pin44_value reading "1" (MCU-awake GPIO), the file
#      the MTK IPO driver creates on the car. The VHAL polls it every 100 ms;
#      without it the service logs an open error 10x/s and after ~20 min
#      (12000 failures) escalates to SOC_Wake_MCU ioctl spam on
#      /dev/ipo_manager.
#
#   7. ex2emu_mcu_spi (tools/kernel-patches/): fake /dev/spidev_mcu1.0 +
#      /proc/spi_ctrl - "device present, MCU silent" (opens and setup
#      ioctls succeed, no fasync SIGIO, so the VHAL's transfer engine never
#      clocks the bus). Kills the bring-up open-error spam while keeping
#      the VHAL in the car-proven "MCU unplugged" equilibrium. Answering
#      the handshake instead would arm dead paths (IPO reboot watchdog,
#      FOTA) - rejected after disassembling the VHAL.
set -eu
cd /project

KERNEL_VERSION="${EX2_KERNEL_VERSION:-4.14.336}"
# /root/kbuild is a docker volume (case-sensitive ext4). The kernel Makefile
# needs targets like xt_TCPMSS.o from xt_tcpmss.c - on a case-insensitive
# mount (the project dir is APFS) that build breaks. Only the tarball and
# the finished Image cross the mounts.
KBUILD=/root/kbuild
KSRC="$KBUILD/linux-$KERNEL_VERSION"
KIMAGE=work/qemu/Image
mkdir -p work/qemu

command -v gcc-9 >/dev/null || { echo "missing gcc-9 in container"; exit 1; }

TARBALL="$KBUILD/linux-$KERNEL_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "fetching $TARBALL"
  mkdir -p "$KBUILD"
  curl -fL -C - -o "$TARBALL.part" \
    "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$KERNEL_VERSION.tar.xz" \
    && mv "$TARBALL.part" "$TARBALL"
fi
xz -t "$TARBALL"

# Patches are applied in-place with grep guards. If the tree carries markers
# from patch versions this script no longer applies (including the pre-rename
# ex2sim: markers), they would silently survive - re-extract from the tarball
# instead of layering on a dirty tree.
if [ -d "$KSRC" ] && grep -qE "ex2sim:|ex2defio:" \
    "$KSRC/drivers/gpu/drm/virtio/virtgpu_fb.c" \
    "$KSRC/drivers/gpu/drm/virtio/virtgpu_plane.c" \
    "$KSRC/arch/arm64/kernel/sys.c" \
    "$KSRC/drivers/video/fbdev/core/fb_defio.c" 2>/dev/null; then
  echo "stale patch markers in $KSRC - re-extracting pristine tree"
  rm -rf "$KSRC"
fi
[ -d "$KSRC" ] || { echo "unpacking"; tar -C "$KBUILD" -xf "$TARBALL"; }
cd "$KSRC"
export ARCH=arm64 CC=gcc-9

# --- patch 1: virtio-gpu scanout transfer ------------------------------------
VGP=drivers/gpu/drm/virtio/virtgpu_plane.c
if ! grep -q "ex2emu: transfer any 2D scanout" "$VGP"; then
python3 - "$VGP" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """		handle = bo->hw_res_handle;
		if (bo->dumb) {
			virtio_gpu_cmd_transfer_to_host_2d"""
new = """		handle = bo->hw_res_handle;
		/* ex2emu: transfer any 2D scanout buffer, not only dumb ones.
		 * A buffer allocated with RESOURCE_CREATE never had its contents
		 * pushed to the host; without virgl the host has no other copy
		 * of the pixels, so the transfer is required for every scanout
		 * buffer, including buffers created outside the dumb-buffer path. */
		if (bo->dumb || !vgdev->has_virgl_3d) {
			virtio_gpu_cmd_transfer_to_host_2d"""
if old not in s:
    print("PATTERN NOT FOUND in virtgpu_plane.c"); sys.exit(1)
s = s.replace(old, new, 1)
open(p,'w',encoding='utf-8').write(s)
print("patched virtgpu_plane.c")
PY
grep -q "ex2emu: transfer any 2D scanout" "$VGP"
fi

# --- patch 2: pin permissive -------------------------------------------------
SELFS=security/selinux/selinuxfs.c
if ! grep -q selinux_pin_permissive "$SELFS"; then
python3 - "$SELFS" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
decl = '''
/* selinux_pin_permissive: ignore userspace attempts to RAISE enforcement.
 * Android user builds call setenforce(1) unconditionally. For emulator
 * analysis of such an image, permissive must stick. Lowering enforcement is
 * still honoured. Deliberate weakening; never for production. */
static int selinux_pin_permissive __read_mostly;
static int __init selinux_pin_permissive_setup(char *str)
{
	unsigned long val;
	if (!kstrtoul(str, 0, &val))
		selinux_pin_permissive = val ? 1 : 0;
	return 1;
}
__setup("selinux_pin_permissive=", selinux_pin_permissive_setup);
'''
anchor = 'static ssize_t sel_write_enforce(struct file *file, const char __user *buf,'
assert anchor in s
s = s.replace(anchor, decl.lstrip('\n') + '\n' + anchor, 1)
m = re.search(r'(\tif \(sscanf\(page, "%d", &new_value\) != 1\)\n\t\tgoto out;\n)', s)
assert m
s = s.replace(m.group(1), m.group(1) +
              '\n\tif (selinux_pin_permissive && new_value)\n\t\tnew_value = 0;\n', 1)
open(p,'w',encoding='utf-8').write(s)
print("patched selinuxfs.c")
PY
grep -q selinux_pin_permissive "$SELFS"
fi

# --- patch 3: accept personality(PER_LINUX32) as no-op ------------------------
#
# Their 32-bit binaries (adbd! audio HAL MTK, thermal daemons) call
# personality(PER_LINUX32) during init; bionic ABORTS the process when the
# call fails ("error setting PER_LINUX32 personality: Invalid argument").
# Apple Silicon has no 32-bit EL0 so arm64_personality returns EINVAL - but
# these processes run under qemu-user, where the personality bit is
# irrelevant. Strip the bit and succeed instead of killing the caller.
ASYS=arch/arm64/kernel/sys.c
if ! grep -q "ex2emu: PER_LINUX32" "$ASYS"; then
python3 - "$ASYS" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """SYSCALL_DEFINE1(arm64_personality, unsigned int, personality)
{
	if (personality(personality) == PER_LINUX32 &&
		!system_supports_32bit_el0())
		return -EINVAL;
	return sys_personality(personality);
}"""
new = """SYSCALL_DEFINE1(arm64_personality, unsigned int, personality)
{
	/* ex2emu: PER_LINUX32 under qemu-user is meaningless; bionic aborts
	 * the calling 32-bit process on failure (adbd, MTK audio HAL...).
	 * Strip the bit and succeed rather than return -EINVAL. */
	if (personality(personality) == PER_LINUX32 &&
		!system_supports_32bit_el0())
		personality &= ~PER_LINUX32;
	return sys_personality(personality);
}"""
if old not in s:
    print("PATTERN NOT FOUND in arch/arm64/kernel/sys.c"); sys.exit(1)
s = s.replace(old, new, 1)
open(p,'w',encoding='utf-8').write(s)
print("patched arm64_personality")
PY
grep -q "ex2emu: PER_LINUX32" "$ASYS"
fi

# --- patch 4: virtio-gpu fbdev usable by classic fbdev gralloc ----------------
#
# The ranchu/goldfish composer presents through the classic libhardware
# gralloc's fb device, which drives /dev/graphics/fb0 with fbdev ioctls.
# virtio-gpu's fbdev breaks it three ways:
#   a) fix.smem_len is never set (stays 0) and gralloc's mapFrameBuffer
#      bails out silently on smem_len <= 0 → "could not open framebuffer".
#   b) the fb is created XRGB8888 (depth 24 → transp 0:0); gralloc's
#      FBIOPUT_VSCREENINFO requests transp 24:8 and drm_fb_helper_check_var
#      rejects the pixel-format change → no double buffer, no page flip.
#      drm_fb_helper_fill_pixel_fmt keys the var offsets off DEPTH ONLY, so
#      any depth-32 fourcc satisfies it identically.
#   c) CONFIG_DRM_FBDEV_OVERALLOC=100 is *not* double buffering (it is
#      surface_height * 100 / 100); 200 is.
# The depth-32 fourcc must be ABGR8888, not ARGB8888: the gralloc/composer
# pair writes RGBA_8888 byte order (R,G,B,A in memory, goldfish-fb
# convention) regardless of the fbdev var. ARGB8888 (memory B,G,R,A) made
# the host scanout a perfect R/B swap of the composed frame - measured by
# comparing a QEMU monitor screendump against the guest screencap (diff 0.0
# after swapping R/B, 2026-08-17). ABGR8888 → VIRTIO_GPU_FORMAT_R8G8B8A8 →
# the host reads the same byte order the guest writes (direct diff 0.0).
VGF=drivers/gpu/drm/virtio/virtgpu_fb.c
if ! grep -q "ex2emu: fbdev smem_len" "$VGF"; then
python3 - "$VGF" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """	mode_cmd.pixel_format = drm_mode_legacy_fb_format(32, 24);"""
new = """	/* ex2emu: fbdev smem_len + ABGR for classic gralloc. depth 32 keeps the
	 * fbdev var transp at 24:8 so the gralloc FBIOPUT_VSCREENINFO passes
	 * drm_fb_pixel_format_equal (XRGB's 0:0 always rejects it); ABGR8888
	 * (memory R,G,B,A) matches the RGBA_8888 bytes the ranchu composer +
	 * gralloc pair actually writes - ARGB8888 (B,G,R,A) made the host
	 * scanout a perfect R/B swap of the composed frame. */
	mode_cmd.pixel_format = DRM_FORMAT_ABGR8888;"""
if old not in s:
    print("PATTERN 1 NOT FOUND in virtgpu_fb.c"); sys.exit(1)
s = s.replace(old, new, 1)
old2 = """	drm_fb_helper_fill_fix(info, fb->pitches[0], fb->format->depth);"""
new2 = """	drm_fb_helper_fill_fix(info, fb->pitches[0], fb->format->depth);
	/* fill_fix leaves smem_len at 0; the classic gralloc fb device treats
	 * smem_len <= 0 as a fatal (and silent) open failure. */
	info->fix.smem_len = size;"""
if old2 not in s:
    print("PATTERN 2 NOT FOUND in virtgpu_fb.c"); sys.exit(1)
s = s.replace(old2, new2, 1)
open(p,'w',encoding='utf-8').write(s)
print("patched virtgpu_fb.c")
PY
grep -q "ex2emu: fbdev smem_len" "$VGF"
fi

# --- patch 4b: fbdev deferred-IO mmap (event-driven host refresh) -------------
#
# virtio_gpufb_ops has no .fb_mmap and no fbdefio: fbmem's default fb_mmap
# ioremaps fix.smem_start (=0 for virtio - the fb is a vmap'd TTM shadow, not
# a physical BAR) with pgprot_writecombine, and userspace memset/memcpy use
# DC ZVA, which faults on non-cacheable memory WITHOUT an instruction
# syndrome - HVF cannot emulate it and QEMU aborts (exit 134).
# ttm_fbdev_mmap does not help either: ttm_bo_vm_fault refuses SG-backed
# objects ("Refuse to fault imported pages") with VM_FAULT_SIGBUS.
#
# The kernel's own deferred-IO machinery solves both at once:
# fb_deferred_io_mmap faults vmap-backed CACHED pages on demand (DC ZVA-safe)
# and tracks written pages via page_mkwrite; the deferred work then calls
# drm_fb_helper_deferred_io → fb->funcs->dirty = virtio_gpu_surface_dirty,
# which transfers just the dirty y-band to the host and flushes. Event-driven
# refresh, ~60 Hz cap (16 ms at HZ=250), zero traffic when the screen is
# idle. Three glue details make it work on this driver:
#   - screen_base must point at the vmap: fb_deferred_io_page() resolves
#     struct pages through it, upstream sets only screen_buffer.
#   - obj->dumb = true: surface_dirty transfers pixels only for dumb
#     objects; otherwise it flushes WITHOUT a transfer and the host never
#     re-reads the resource.
#   - fbmem's fb_open wires fb_deferred_io_open automatically once
#     info->fbdefio is set; fb_deferred_io_init installs
#     fb_mmap = fb_deferred_io_mmap.
if ! grep -q "ex2emu: fbdev defio" "$VGF"; then
python3 - "$VGF" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old = """	struct drm_mode_fb_cmd2 mode_cmd = {};
	struct virtio_gpu_object *obj;
	uint32_t resid, format, size;
	int ret;"""
new = """	struct drm_mode_fb_cmd2 mode_cmd = {};
	struct virtio_gpu_object *obj;
	struct fb_deferred_io *fbdefio;
	uint32_t resid, format, size;
	int ret;"""
if old not in s:
    print("PATTERN NOT FOUND (decls) in virtgpu_fb.c"); sys.exit(1)
s = s.replace(old, new, 1)

old = """	info->screen_buffer = obj->vmap;
	info->screen_size = obj->gem_base.size;"""
new = """	info->screen_buffer = obj->vmap;
	/* ex2emu: fbdev defio - fb_deferred_io_page() resolves struct pages
	 * through screen_base; upstream sets only screen_buffer. */
	info->screen_base = (char __iomem *)obj->vmap;
	info->screen_size = obj->gem_base.size;"""
if old not in s:
    print("PATTERN NOT FOUND (screen_buffer) in virtgpu_fb.c"); sys.exit(1)
s = s.replace(old, new, 1)

old = """	info->fix.mmio_start = 0;
	info->fix.mmio_len = 0;
	return 0;"""
new = """	info->fix.mmio_start = 0;
	info->fix.mmio_len = 0;

	/* ex2emu: fbdev defio - dumb so surface_dirty transfers pixels
	 * instead of flushing without a transfer. */
	obj->dumb = true;
	fbdefio = kzalloc(sizeof(*fbdefio), GFP_KERNEL);
	if (!fbdefio)
		return -ENOMEM;
	fbdefio->delay = msecs_to_jiffies(16);
	fbdefio->deferred_io = drm_fb_helper_deferred_io;
	info->fbdefio = fbdefio;
	fb_deferred_io_init(info);
	return 0;"""
if old not in s:
    print("PATTERN NOT FOUND (mmio) in virtgpu_fb.c"); sys.exit(1)
s = s.replace(old, new, 1)

old = """	drm_fb_helper_unregister_fbi(&vgfbdev->helper);"""
new = """	/* ex2emu: fbdev defio */
	if (vgfbdev->helper.fbdev && vgfbdev->helper.fbdev->fbdefio)
		fb_deferred_io_cleanup(vgfbdev->helper.fbdev);
	drm_fb_helper_unregister_fbi(&vgfbdev->helper);"""
if old not in s:
    print("PATTERN NOT FOUND (destroy) in virtgpu_fb.c"); sys.exit(1)
s = s.replace(old, new, 1)

open(p,'w',encoding='utf-8').write(s)
print("patched virtgpu_fb.c (fbdev defio)")
PY
fi
grep -q "ex2emu: fbdev defio" "$VGF"

# --- patch 5: xt_qtaguid backport (per-uid traffic accounting) ------------------
# Pie's NetworkManagementService only enables bandwidth control when
# /proc/net/xt_qtaguid/ctrl exists. Without it NPMS.initService() returns
# early ("bandwidth controls disabled, unable to enforce policy"), leaving
# mUsageStats null - ~60 s after boot the first temp-whitelist push calls
# isUidIdle() and system_server dies on an NPE, in a loop. Mainline 4.14
# never carried xt_qtaguid and android-common dropped it after 4.9, so
# backport the msm-4.9 Pie-era sources (LineageOS/android_kernel_google_msm
# @ lineage-16.0), kept verbatim in tools/kernel-patches/. qtaguid replaces
# the owner match (Kconfig: depends on NETFILTER_XT_MATCH_OWNER=n), same as
# on the real QCom device kernel.
QTSRC=/project/tools/kernel-patches
install -m644 "$QTSRC/xt_qtaguid.c" "$QTSRC/xt_qtaguid_print.c" \
  "$QTSRC/xt_qtaguid_internal.h" "$QTSRC/xt_qtaguid_print.h" net/netfilter/
install -m644 "$QTSRC/xt_qtaguid.h" include/linux/netfilter/
if ! grep -q NETFILTER_XT_MATCH_QTAGUID net/netfilter/Kconfig; then
python3 - <<'PY'
p = "net/netfilter/Kconfig"
s = open(p, encoding='utf-8').read()
block = '''config NETFILTER_XT_MATCH_QTAGUID
	bool '"quota, tag, owner" match and stats support'
	depends on NETFILTER_XT_MATCH_SOCKET
	depends on NETFILTER_XT_MATCH_OWNER=n
	help
	  This option replaces the `owner' match. In addition to matching
	  on uid, it keeps stats based on a tag assigned to a socket.
	  The full tag is comprised of a UID and an accounting tag.
	  The tags are assignable to sockets from user space (e.g. a download
	  manager can assign the socket to another UID for accounting).
	  Stats and control are done via /proc/net/xt_qtaguid/.
	  It replaces owner as it takes the same arguments, but should
	  really be recognized by the iptables tool.

'''
anchor = "config NETFILTER_XT_MATCH_SOCKET"
assert anchor in s
s = s.replace(anchor, block + anchor, 1)
open(p, 'w', encoding='utf-8').write(s)
print("patched net/netfilter/Kconfig")
PY
fi
grep -q "NETFILTER_XT_MATCH_QTAGUID" net/netfilter/Makefile || \
  echo 'obj-$(CONFIG_NETFILTER_XT_MATCH_QTAGUID) += xt_qtaguid_print.o xt_qtaguid.o' \
  >> net/netfilter/Makefile
grep -q NETFILTER_XT_MATCH_QTAGUID net/netfilter/Kconfig
grep -q NETFILTER_XT_MATCH_QTAGUID net/netfilter/Makefile

# --- patch 6: fake IPO pin44 proc entry (MCU-awake GPIO for the VHAL) ---------
install -m644 "$QTSRC/ex2emu_ipo_pin44.c" drivers/misc/
grep -q ex2emu_ipo_pin44 drivers/misc/Makefile || \
  echo 'obj-y += ex2emu_ipo_pin44.o' >> drivers/misc/Makefile
grep -q ex2emu_ipo_pin44 drivers/misc/Makefile

# --- patch 7: fake MCU SPI slave + /proc/spi_ctrl (VHAL bring-up) -------------
install -m644 "$QTSRC/ex2emu_mcu_spi.c" drivers/misc/
grep -q ex2emu_mcu_spi drivers/misc/Makefile || \
  echo 'obj-y += ex2emu_mcu_spi.o' >> drivers/misc/Makefile
grep -q ex2emu_mcu_spi drivers/misc/Makefile

# --- config -------------------------------------------------------------------
make defconfig
enable() { ./scripts/config --file .config --enable "$1"; }
set_str() { ./scripts/config --file .config --set-str "$1" "$2"; }

for opt in \
  ANDROID ANDROID_BINDER_IPC ASHMEM \
  STAGING \
  VIRTIO VIRTIO_PCI VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE \
  VIRTIO_MMIO_CMDLINE_DEVICES \
  SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE \
  EXT4_FS EXT4_USE_FOR_EXT2 \
  BLK_DEV_INITRD RD_GZIP RD_LZ4 \
  DEVTMPFS DEVTMPFS_MOUNT \
  AUDIT AUDITSYSCALL \
  PM_WAKELOCKS PM_WAKELOCKS_GC \
  HID_MULTITOUCH INPUT_TOUCHSCREEN INPUT_UINPUT \
  NET NETWORK_SECMARK \
  NETFILTER_NETLINK NETFILTER_NETLINK_LOG NETFILTER_NETLINK_QUEUE \
  NETFILTER_XT_TARGET_NFLOG NETFILTER_XT_TARGET_NFQUEUE \
  NETFILTER_ADVANCED NETFILTER_XTABLES \
  NF_SOCKET_IPV4 NF_SOCKET_IPV6 \
  NF_CONNTRACK NF_CONNTRACK_IPV4 NF_CONNTRACK_IPV6 NF_CONNTRACK_EVENTS \
  NF_NAT NF_NAT_IPV4 NF_NAT_IPV6 NF_NAT_MASQUERADE_IPV4 \
  IP_NF_IPTABLES IP_NF_FILTER IP_NF_MANGLE IP_NF_RAW IP_NF_NAT \
  IP_NF_TARGET_MASQUERADE IP_NF_TARGET_REJECT \
  IP6_NF_IPTABLES IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_RAW \
  NETFILTER_XT_MATCH_QUOTA NETFILTER_XT_MATCH_QUOTA2 \
  NETFILTER_XT_MATCH_QTAGUID \
  NETFILTER_XT_MATCH_STATE \
  NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MATCH_MULTIPORT \
  NETFILTER_XT_MATCH_POLICY NETFILTER_XT_MATCH_U32 \
  NETFILTER_XT_TARGET_CONNMARK NETFILTER_XT_TARGET_MARK \
  NETFILTER_XT_TARGET_IDLETIMER NETFILTER_XT_TARGET_TCPMSS \
  NETFILTER_XT_MATCH_SOCKET NETFILTER_XT_MATCH_COMMENT \
  IPV6 IPV6_MULTIPLE_TABLES IPV6_ROUTER_PREF IPV6_OPTIMISTIC_DAD \
  INET6_ESP INET6_AH IPV6_SIT \
  NF_LOG_COMMON NF_LOG_IPV4 NF_DEFRAG_IPV6 \
  NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_TARGET_LOG \
  NETFILTER_XT_TARGET_CHECKSUM BRIDGE_NETFILTER \
  INET_DIAG INET_UDP_DIAG NETLINK_DIAG PACKET_DIAG UNIX_DIAG \
  IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES XFRM_USER \
  SECURITY SECURITY_NETWORK SECURITY_SELINUX SECURITY_SELINUX_BOOTPARAM \
  SECURITY_SELINUX_DEVELOP \
  XATTR EXT4_FS_SECURITY EXT4_FS_POSIX_ACL \
  QUOTA QUOTACTL QFMT_V2 QUOTA_TREE \
  ION ION_SYSTEM_HEAP SYNC_FILE SW_SYNC \
  DMA_SHARED_BUFFER STAGING_ANDROID \
  DRM DRM_VIRTIO_GPU DRM_FBDEV_EMULATION DRM_KMS_FB_HELPER \
  FB FB_DEFERRED_IO FB_CFB_FILLRECT FB_CFB_COPYAREA FB_CFB_IMAGEBLIT \
  FRAMEBUFFER_CONSOLE VT VT_CONSOLE \
  TMPFS TMPFS_POSIX_ACL TMPFS_XATTR \
  FUSE_FS \
  SYSVIPC \
  CGROUPS CGROUP_SCHED CGROUP_FREEZER CGROUP_CPUACCT \
  NAMESPACES \
  PSTORE PSTORE_CONSOLE PSTORE_RAM \
  UID_SYS_STATS \
  BINFMT_MISC \
  FTRACE ENABLE_DEFAULT_TRACERS EVENT_TRACING TRACEPOINTS \
  ; do enable "CONFIG_$opt"; done

set_str CONFIG_ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
./scripts/config --file .config --disable CONFIG_CMDLINE_FORCE
# qtaguid replaces the owner match (Kconfig depends on OWNER=n)
./scripts/config --file .config --disable CONFIG_NETFILTER_XT_MATCH_OWNER
# 100 means "no overallocation" (surface_height * 100 / 100); 200 doubles it
# so the fbdev fb can hold front+back buffers and FBIOPAN_DISPLAY page-flips.
./scripts/config --file .config --set-val CONFIG_DRM_FBDEV_OVERALLOC 200
set_str CONFIG_DEFAULT_SECURITY "selinux"
./scripts/config --file .config --enable CONFIG_DEFAULT_SECURITY_SELINUX
set_str CONFIG_LSM "yama,loadpin,safesetid,integrity,selinux"

make olddefconfig
MISSING=0
for o in CONFIG_ANDROID_BINDER_IPC CONFIG_ASHMEM CONFIG_VIRTIO_BLK \
         CONFIG_VIRTIO_MMIO CONFIG_SERIAL_AMBA_PL011_CONSOLE \
         CONFIG_EXT4_FS CONFIG_BLK_DEV_INITRD CONFIG_SECURITY_SELINUX \
         CONFIG_DEVTMPFS_MOUNT CONFIG_QUOTA CONFIG_QFMT_V2 \
         CONFIG_ION CONFIG_SYNC_FILE CONFIG_SW_SYNC \
         CONFIG_FB_DEFERRED_IO \
         CONFIG_NETFILTER_XT_MATCH_QTAGUID; do
  grep -q "^$o=y" .config || { echo "MISSING: $o"; MISSING=1; }
done
[ "$MISSING" -eq 0 ] || exit 1

JOBS=$(nproc)
echo "make -j$JOBS Image"
make -j"$JOBS" Image

cp arch/arm64/boot/Image "/project/$KIMAGE"
mkdir -p /project/out/boot
cp .config "/project/out/boot/kernel_config_$KERNEL_VERSION.txt"
echo "kernel: /project/$KIMAGE ($(stat -c %s "/project/$KIMAGE") bytes)"
