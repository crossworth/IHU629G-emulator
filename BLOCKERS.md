# BLOCKERS - open items

The emulator boots to a working, interactive Flyme Auto HMI. Nothing below
blocks daily use (`./run.sh`); they are the remaining fidelity gaps.

## VHAL spins on absent hardware (minor - properties now injectable)

The service is ECARX's fork of AOSP EmulatedVehicleHal, identified by
firmware analysis. Car state sits on compiled-in defaults (NIGHT_MODE
boots as night) unless injected.

**Working injection path (2026-08-17):** the fork kept AOSP's SocketComm -
a listener on guest TCP 33452 (hostfwd'd) speaking the Android 9
`emulator.EmulatorMessage` protobuf. `tools/qemu/vhalctl.py` sets/gets any
property: values land in the store and fan out as onChangeEvent exactly
like MCU RX telemetry. Use it for day/night, gear, speed, HVAC state.

**pin44 fixed (2026-08-18):** kernel patch 6 (stage 10,
`tools/kernel-patches/ex2emu_ipo_pin44.c`) creates
`/proc/bicv_ipo_dir/pin44_value` reading `1` (MCU-awake GPIO), what the
MTK IPO driver exposes on the car. Semantics from disassembly of
`readPin44Value` (10×/s poll, ASCII digit minus '0'): 1 = awake, safe -
handshake only fires on a low→high transition, and the failure counter
that escalates to `SOC_Wake_MCU()` ioctl spam after ~20 min only
increments while the read fails. Verified: zero open errors, debug line
every 10 s (`don't repeat handshake`, checkNum=0) exactly like the car.

**MCU SPI faked "present but silent" (2026-08-18):** kernel patch 7
(stage 10, `tools/kernel-patches/ex2emu_mcu_spi.c`) creates
`/dev/spidev_mcu1.0` (misc char dev: opens + setup ioctls succeed, no
fasync SIGIO) and `/proc/spi_ctrl` (writable, discards). Full protocol
map from disassembling the VHAL: raw frame = 5C C5 + len + 00 00 +
CRC16-Modbus + COBS DataFrame (cmd/smd/sn/ct + payload + CRC); init =
SOC handshake cmdsmd 0x0000 → MCU ACK (ct=1, sn match) → MCU notify
0x0001 → 0x0200 heartbeats. The decisive finding: `g_spi_rdy` is set
ONLY by the SIGIO handler, so without fasync the transfer engine never
issues SPI_IOC_MESSAGE and the MCU state machine idles in exactly the
car-proven "MCU unplugged" equilibrium (1 s CS-ready timeout + 350 ms
handshake-queue logs - benign). Emulating the handshake was REJECTED:
it would arm dead paths (the IPO watchdog enqueues a reboot-SoC request
if heartbeats stutter; the FOTA thread wakes). Verified post-reboot:
`SPI_GPIO_DEV_PATH failed` and spidev open errors zero, queue/timeout
logs continue at car cadence, HMI/adb/touch intact.

Boot defaults (2026-08-18): with no MCU the store booted on compiled-in
nonsense (GEAR_SELECTION=2 = REVERSE in the ECARX enum, NIGHT_MODE=2,
e-brake off, SoC 0%) and apps reacted - FlymeAutoRestrictionService
locked the UI "in R gear" right after boot. run.sh now injects the
parked-car baseline (`vhalctl.py park`) after boot_completed.

## OMX HAL service crash-looped → disabled by stage 23 (2026-08-17, root-caused 2026-08-18)

`android.hardware.media.omx@1.0-service` (init name `mediacodec`, 32-bit
MTK binary under qemu-arm) started for real once 32-bit binder worked -
then SIGABRTed ~5 s later, forever: init restarted it, one tombstone per
cycle. Stage 23 appends `disabled` to the vendor rc stanza (pristine kept
as `.rc.orig` in the vendor image).

Root-cause chain (2026-08-18, now that tombstones work):

1. **Startup abort = libminijail + qemu-user.** The service jails itself;
   qemu-user deliberately answers `prctl(PR_SET_SECCOMP)` with EINVAL
   ("prevent the target disabling stuff we need"), minijail treats that
   as fatal → SIGABRT. Fixed in our qemu-arm (stage 40 patch 3): pretend
   seccomp success - a guest filter would constrain qemu's own host
   syscalls with the wrong ABI anyway. With it, the service starts,
   registers `IOmx/default`, and instantiates the OMX.google.* software
   codecs for clients.
2. **Next blocker = 32-bit hwbinder.** Seconds later a worker thread dies
   in `hardware::Parcel::writeInt32` on a null `mData` - the known
   qemu-user nested-binder-marshalling gap. The service
   stays disabled at boot until that is fixed.

Framework clients (media.codec) still log "Waited one second for IOmx"
every second - logcat-only, stable process, no churn. Playback needs IOmx
and would ALSO need MTK ION even if the service ran.

To re-test the service by hand (it must NOT be left enabled at boot):
`nohup /vendor/bin/hw/android.hardware.media.omx@1.0-service &` - or
restore `/vendor/etc/init/android.hardware.media.omx@1.0-service.rc.orig`.

## drm / mediadrm abort-loop - no longer observed (2026-08-17)

The old entry (vendor.drm-hal-1-0 + mediadrm dying every ~5 s with "Could
not get passthrough implementation for IDrmFactory") is stale: after the
2026-08-17 32-bit binder fix both sit stable since early boot
(`init.svc.vendor.drm-hal-1-0=running`, low pid, binder_thread_read).
Widevine/media DRM is not working in this setup, but there is no loop.
Re-check before acting on the old diagnosis.

## Instrument cluster display

The car has a second display (cluster) driven by hardware we do not emulate.
Nothing here attempts it.

## MTK ION ABI (inherited, out of scope)

libion_mtk uses ION_IOC_CUSTOM; mainline 4.14 ION doesn't implement it, so
MediaTek mediacodec/omx cannot work. A full ION shim is out of scope unless
something user-visible turns out to need it.

## com.geely.dab dies once at boot (benign)

DAB radio app: "Invalid audio buffer size" against the stub audio HAL (no
real tuner exists in an emulator). Single death, no loop. Expected.

## Status-bar clock: torn digit + stuck white highlight (firmware app bug)

Both artifacts live in the Flyme SystemUI plugin's view state, not in the
display path and not in the GLES renderer. Root-caused 2026-08-18 against
the decompiled GeelyAutoSystemUIPlugin (jadx) with live instrumentation:

1. **Stuck white pill behind the clock** = the *selected-state background*
   of `StatusTimeIconLayout` (`StatusIconBackgroundDrawable`, a translucent
   white rounded rect drawn when the view is selected). Tapping the clock
   opens a date popup and selects the icon; dismissing the popup provably
   runs (`StatusIconPopupWindow: Dismiss` → `onPanelDismiss()` →
   `setSelected(false)`), frames provably render (gfxinfo frame counter
   advances +27/+47 across an open/close cycle), yet the pill stays -
   even with `debug.hwui.use_buffer_age=false` +
   `debug.hwui.use_partial_updates=false` (every frame a full repaint).
   Pill opacity varies with the drawable's frozen fade ValueAnimator
   (faint vs bright). Conclusion: the plugin's popup/icon selection state
   desyncs from the visible view instance; the emulator renders exactly
   what the app draws. Almost certainly reproducible on the real car with
   the same tap flow - worth verifying there. Only
   `adb shell pkill -f com.android.systemui` clears it.
2. **Torn minute digit** (old+new glyph overlapped until the next tick) =
   the clock's digit-change transition frozen mid-frame: the last rendered
   frame is a mid-transition draw. Same family: app-side animation state,
   faithfully displayed. Present even without any clicks.

The earlier theory (SwiftShader gamma blending / ripple stuck for lack of
invalidation) was WRONG for these two: blending explains only the AA
fringe below, and invalidations demonstrably flow. The
`debug.hwui.renderer=skia` knob does NOT exist on Pie either ("skia"
falls into the legacy OpenGL pipeline branch - only skiagl/skiavk are
recognized; see Properties.cpp getRenderPipelineType).

## SwiftShader AA fringe: icons/text look semi-bold (cosmetic, renderer)

Status-bar icons and the clock render with a 1-px dark fringe (edge
profile 147→52→0 instead of a smooth AA ramp), so everything drawn via
GLES looks heavier than on the real unit's Mali. Measured INSIDE the
status bar's own RGBA buffer (screendump == screencap diff 0.0). Cause:
gamma-incorrect alpha blending in the redroid SwiftShader build. A real
fix means replacing the GLES renderer (see below) - not scheduled.

## Renderer replacement: 2021 SwiftShader builds+loads, renders black (open)

`tools/qemu/41_build_swiftshader_gles.sh` produces android-arm64 drop-ins
from the last GLES-capable upstream revision (606261c, 2021-12 - master
deleted the GLES frontend; redroid's Mesa has no software rasterizer; no
virgl in brew QEMU). The result initializes cleanly ("SwiftShader
4.6.6.6", zero crashes, eglCreateImageKHR Android path ported) but NO app
window ever posts - all SurfaceFlinger layers stay activeBuffer 0x0,
screen black, no EGL errors. Silent break in the window path
(eglCreateWindowSurface/swap, Surface.cpp + FrameBufferAndroid.cpp NDK
branch) vs the API-28 Surface. Further diagnosis would require a
TRACE/debug build and gdbserver on SurfaceFlinger.

Value update (2026-08-18): the status-bar pill/tear artifacts turned out
to be app-level (see above), NOT renderer bugs - a renderer swap would
fix only the AA fringe. Deprioritized accordingly.

## Guest clock falls behind after the Mac sleeps (auto-healed)

QEMU's virtual clock pauses while the host sleeps and the guest kernel
never re-reads the RTC after boot, so the Android clock stays behind by
the sleep duration (observed: 33 min host sleep → 31 min guest lag).
NTP does not self-heal in this firmware. The clock itself keeps ticking
normally - it is not frozen. run.sh spawns `tools/qemu/timesyncd.sh`
(2026-08-18), which watches for the host wake and re-syncs the guest
clock over adb automatically. Manual escape hatch:

    ./run.sh --sync-time

## EVS camera stack spam (benign)

EvsApp logs `EGLImageTargetRenderbufferStorageOES unimplemented` (redroid
SwiftShader) and camera search errors; no cameras exist here.

## 32-bit ECARX services

The 32-bit binder users needed by the UI run via binfmt and the
binder-patched qemu-arm (`tools/qemu/40_build_qemu_arm.sh`). This is not
complete 32-bit compatibility: the OMX/hwbinder failure above remains open.

## Real audio behavior

Audio is the GSI 64-bit stack + the firmware's stub primary HAL: framework
works, `media.audio_flinger` publishes, no actual sound output. Recreating
the car-relevant audio behavior (chimes, focus, setParameters) means
reverse-engineering the ECARX audio stack - a project in itself, not
scheduled.
