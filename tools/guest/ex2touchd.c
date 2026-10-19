/* ex2touchd - touchscreen bridge over the QEMU usb-tablet.
 *
 * The usb-tablet reports ABS_X/ABS_Y + BTN_LEFT. Stock Pie EventHub accepts
 * a pointer device only as a mouse (BTN_MOUSE + REL_X/REL_Y) or as a
 * touchscreen (BTN_TOUCH + ABS_X/ABS_Y); the tablet is neither, so EventHub
 * drops it with classes==0 ("Dropping device", ALOGV) and no Android app
 * ever sees a touch. This daemon republishes the tablet's events through a
 * uinput device that advertises BTN_TOUCH - a real single-touch screen as
 * far as the framework is concerned.
 *
 * Coordinates pass through unchanged: the tablet's 0..32767 range is what
 * QEMU scales VNC framebuffer pixels into, and TouchInputMapper scales that
 * same range onto the 1920x1080 display, so the mapping is exact.
 *
 * The source node is intentionally NOT grabbed (EVIOCGRAB): nothing else
 * consumes it, and leaving it readable keeps getevent usable for debugging.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define TABLET_NAME "QEMU QEMU USB Tablet"
#define ABS_RANGE_MAX 32767

static int open_tablet(void)
{
    char path[64], name[256];
    for (int tries = 0; tries < 60; tries++) {
        for (int i = 0; i < 16; i++) {
            snprintf(path, sizeof(path), "/dev/input/event%d", i);
            int fd = open(path, O_RDONLY);
            if (fd < 0)
                continue;
            if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) > 0 &&
                strcmp(name, TABLET_NAME) == 0)
                return fd;
            close(fd);
        }
        sleep(1);
    }
    fprintf(stderr, "ex2touchd: '%s' not found under /dev/input\n", TABLET_NAME);
    exit(1);
}

static int create_touchscreen(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0 && errno == ENOENT) {
        mknod("/dev/uinput", S_IFCHR | 0600, makedev(10, 223));
        fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    }
    if (fd < 0) {
        perror("ex2touchd: open /dev/uinput");
        exit(1);
    }

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(fd, UI_SET_ABSBIT, ABS_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    /* INPUT_PROP_DIRECT: pointer acts directly on the display (a screen,
     * not a touchpad) - this is what makes TouchInputMapper treat it as
     * deviceType touchScreen without an IDC file. */
    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    struct uinput_user_dev dev;
    memset(&dev, 0, sizeof(dev));
    snprintf(dev.name, sizeof(dev.name), "ex2-touchscreen");
    dev.id.bustype = BUS_VIRTUAL;
    dev.id.vendor  = 0x6578;
    dev.id.product = 0x0001;
    dev.id.version = 1;
    dev.absmin[ABS_X] = 0;
    dev.absmax[ABS_X] = ABS_RANGE_MAX;
    dev.absmin[ABS_Y] = 0;
    dev.absmax[ABS_Y] = ABS_RANGE_MAX;

    if (write(fd, &dev, sizeof(dev)) != sizeof(dev) ||
        ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("ex2touchd: create uinput device");
        exit(1);
    }
    return fd;
}

int main(void)
{
    int in = open_tablet();
    int out = create_touchscreen();
    fprintf(stderr, "ex2touchd: bridging %s -> uinput touchscreen\n", TABLET_NAME);

    for (;;) {
        struct input_event ev;
        ssize_t n = read(in, &ev, sizeof(ev));
        if (n != sizeof(ev)) {
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == ENODEV)
                exit(1); /* tablet gone - let init restart us */
            continue;
        }
        if (ev.type == EV_KEY && ev.code == BTN_LEFT) {
            ev.code = BTN_TOUCH;
        } else if (ev.type == EV_ABS && (ev.code == ABS_X || ev.code == ABS_Y)) {
            /* pass through */
        } else if (ev.type == EV_SYN) {
            /* pass through */
        } else {
            continue; /* MSC_SCAN, wheel, extra buttons: nothing maps them */
        }
        if (write(out, &ev, sizeof(ev)) != sizeof(ev)) {
            perror("ex2touchd: uinput write");
            sleep(2);
        }
    }
}
