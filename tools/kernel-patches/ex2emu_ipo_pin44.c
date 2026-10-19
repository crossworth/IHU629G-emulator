// SPDX-License-Identifier: GPL-2.0
/*
 * ex2emu: fake MediaTek IPO pin44 state for the ECARX VHAL.
 *
 * On the car, /proc/bicv_ipo_dir/pin44_value is created by the MTK
 * instant-power-on (IPO) driver and mirrors the MCU-awake GPIO. The VHAL
 * polls it every 100 ms (readPin44Value, ASCII digit minus '0'). Without
 * the file the service logs an open error 10x/s, and after 12000
 * consecutive failures (~20 min of uptime) it escalates through
 * SOC_Wake_MCU() - an ioctl on /dev/ipo_manager - every 100 ms.
 * Emulate the awake state: read returns "1\n"; writes accepted, ignored
 * (the VHAL opens the file O_RDWR).
 */
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>

static struct proc_dir_entry *ex2emu_ipo_dir;

static ssize_t ex2emu_pin44_read(struct file *f, char __user *buf,
				 size_t len, loff_t *off)
{
	return simple_read_from_buffer(buf, len, off, "1\n", 2);
}

static ssize_t ex2emu_pin44_write(struct file *f, const char __user *buf,
				  size_t len, loff_t *off)
{
	return len;
}

static const struct file_operations ex2emu_pin44_fops = {
	.owner	= THIS_MODULE,
	.read	= ex2emu_pin44_read,
	.write	= ex2emu_pin44_write,
	.llseek	= noop_llseek,
};

static int __init ex2emu_ipo_init(void)
{
	ex2emu_ipo_dir = proc_mkdir("bicv_ipo_dir", NULL);
	if (!ex2emu_ipo_dir)
		return -ENOMEM;
	if (!proc_create("pin44_value", 0666, ex2emu_ipo_dir,
			 &ex2emu_pin44_fops))
		return -ENOMEM;
	return 0;
}
late_initcall(ex2emu_ipo_init);
