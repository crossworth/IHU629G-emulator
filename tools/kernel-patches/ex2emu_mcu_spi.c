// SPDX-License-Identifier: GPL-2.0
/*
 * ex2emu: fake MCU SPI slave + CS proc knob for the ECARX VHAL.
 *
 * On the car, /dev/spidev_mcu1.0 is the SOC<->MCU SPI link and
 * /proc/spi_ctrl a vendor-driver knob that bit-bangs the chip-select
 * line. The VHAL's McuController opens both at bring-up; without them
 * it logs open errors in a loop (~10x/min).
 *
 * Reverse-engineering the VHAL (BLOCKERS.md) showed the safe
 * emulation is "device present, MCU silent": accept open() and the
 * spidev setup ioctls, deliver NO fasync SIGIO. The VHAL's transfer
 * engine is gated on g_spi_rdy, which only its SIGIO handler sets, so
 * no SPI_IOC_MESSAGE is ever issued and the MCU state machine sits in
 * exactly the "MCU unplugged" equilibrium the real car exhibits
 * (1 s CS-ready timeout + 350 ms handshake-queue retry logs - benign).
 * Actually answering the handshake would arm otherwise-dead paths
 * (IPO reboot watchdog, FOTA) - worse than the spam it would silence.
 */
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/spi/spidev.h>
#include <linux/uaccess.h>

static long ex2emu_spidev_ioctl(struct file *f, unsigned int cmd,
				unsigned long arg)
{
	if (_IOC_TYPE(cmd) != SPI_IOC_MAGIC)
		return -ENOTTY;
	if (cmd == SPI_IOC_MESSAGE(1))
		return -EIO; /* unreachable: no SIGIO -> no transfers */
	return 0;        /* setup ioctls: per-transfer struct overrides them */
}

static const struct file_operations ex2emu_spidev_fops = {
	.owner		= THIS_MODULE,
	.open		= nonseekable_open,
	.unlocked_ioctl	= ex2emu_spidev_ioctl,
	.compat_ioctl	= ex2emu_spidev_ioctl,
	.llseek		= no_llseek,
};

static struct miscdevice ex2emu_spidev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "spidev_mcu1.0",
	.fops	= &ex2emu_spidev_fops,
	.mode	= 0666,
};

static ssize_t ex2emu_spi_ctrl_read(struct file *f, char __user *buf,
				    size_t len, loff_t *off)
{
	return simple_read_from_buffer(buf, len, off, "0\n", 2);
}

static ssize_t ex2emu_spi_ctrl_write(struct file *f, const char __user *buf,
				     size_t len, loff_t *off)
{
	return len;
}

static const struct file_operations ex2emu_spi_ctrl_fops = {
	.owner	= THIS_MODULE,
	.read	= ex2emu_spi_ctrl_read,
	.write	= ex2emu_spi_ctrl_write,
	.llseek	= noop_llseek,
};

static int __init ex2emu_mcu_spi_init(void)
{
	int ret = misc_register(&ex2emu_spidev);

	if (ret)
		return ret;
	if (!proc_create("spi_ctrl", 0666, NULL, &ex2emu_spi_ctrl_fops))
		return -ENOMEM;
	return 0;
}
late_initcall(ex2emu_mcu_spi_init);
