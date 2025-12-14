#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>
#include <linux/i2c.h>
#include <linux/delay.h>
#include <linux/sysfs.h>
#include <linux/version.h>
#include "ap3216c.h"

#define DEVICE_CNT      1
#define DEVICE_NAME     "ap3216c"

#if LINUX_VERSION_CODE <= KERNEL_VERSION(5, 6, 0)
#define sysfs_emit(buf, fmt, ...) \
    scnprintf(buf, PAGE_SIZE, fmt, ##__VA_ARGS__)
#endif

#define AP3216C_ATTR_RO(_name, _type)           \
static struct ap3216c_attr ap3216c_attr_##_name = { \
    .dev_attr = __ATTR(_name, 0444, ap3216c_show, NULL), \
    .type = _type,                              \
}

struct ap3216c_device {
	int devid;
	struct cdev cdev;
	struct class *class;
	struct device *device;
	struct i2c_client *client;
	u16  ir, als, ps;
};

enum ap3216c_attr_type {
    AP3216C_ATTR_IR,
    AP3216C_ATTR_ALS,
    AP3216C_ATTR_PS,
};

struct ap3216c_attr {
    struct device_attribute dev_attr;
    enum ap3216c_attr_type type;
};

static struct ap3216c_device ap3216c_dev;
static int ap3216c_open(struct inode *inode, struct file *filp);
static ssize_t ap3216c_read(struct file *filp, char __user *user, size_t count, loff_t *loffp);
static int ap3216c_release(struct inode *inode, struct file *filp);
static ssize_t ap3216c_show(struct device *dev, struct device_attribute *attr, char *buf);

static struct file_operations ap3216c_fops = {
	.owner = THIS_MODULE,
	.open = ap3216c_open,
	.read = ap3216c_read,
	.release = ap3216c_release,
};

AP3216C_ATTR_RO(ir,  AP3216C_ATTR_IR);
AP3216C_ATTR_RO(als, AP3216C_ATTR_ALS);
AP3216C_ATTR_RO(ps,  AP3216C_ATTR_PS);
static struct attribute *ap3216c_attrs[] = {
    &ap3216c_attr_ir.dev_attr.attr,
    &ap3216c_attr_als.dev_attr.attr,
    &ap3216c_attr_ps.dev_attr.attr,
    NULL,
};

static const struct attribute_group ap3216c_attrs_group = {
	.attrs = ap3216c_attrs,
};

static int ap3216c_read_regs(struct i2c_client *client, u8 reg, void *buf, u16 len)
{
	struct i2c_msg msgs[2];

	msgs[0].addr = client->addr;    
	msgs[0].flags = 0;              
	msgs[0].len = 1;                
	msgs[0].buf = &reg;             

	msgs[1].addr = client->addr;    
	msgs[1].flags = I2C_M_RD;       
	msgs[1].len = len;              
	msgs[1].buf = buf;              

	if(i2c_transfer(client->adapter, msgs, 2) < 0){
		pr_err("i2c_transfer failed!\n");
		return -1;
	}

	return len;
}

static int ap3216c_write_regs(struct i2c_client *client, u8 reg, u8 *buf, u16 len)
{
	struct i2c_msg msg;
	u8 temp_buf[64] = {0};

	if (len >= 64)
		len = 63;

	temp_buf[0] = reg;
	memcpy(&temp_buf[1], buf, len);

	msg.addr = client->addr;        
	msg.flags = 0;                  
	msg.len = len + 1;              
	msg.buf = temp_buf;             

	if(i2c_transfer(client->adapter, &msg, 1) < 0){
		pr_err("i2c_transfer failed!\n");
		return -1;
	}

	return len;
}

static int ap3216c_read_single_reg(struct ap3216c_device *dev, u8 reg, u8 *data)
{
	return  ap3216c_read_regs(dev->client, reg, data, 1);
}

static int ap3216c_write_single_reg(struct ap3216c_device *dev, u8 reg,u8 data)
{
	return ap3216c_write_regs(dev->client, reg, &data, 1);
}

void ap3216c_readdata(struct ap3216c_device *dev)
{
	int i = 0;
	u8 buf[6] = {0};

	for (i = 0; i < 6; i++) {
		ap3216c_read_single_reg(dev,  AP3216C_IRDATALOW + i, &buf[i]);
	}

	if (buf[0] & 0x80)
		dev->ir = 0;
	else
		dev->ir = (buf[1] << 2) | (buf[0] & 0x03);

	dev->als = (buf[3] << 8) | buf[2];

	if (buf[4] & 0x40)
		dev->ps = 0;
	else
		dev->ps = ((buf[5] & 0x3f) << 4) | (buf[4] & 0x0f);
}

static ssize_t ap3216c_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret = 0;
    struct i2c_client *client = to_i2c_client(dev);
    struct ap3216c_device *ap = i2c_get_clientdata(client);
    struct ap3216c_attr *a = container_of(attr, struct ap3216c_attr, dev_attr);

    ap3216c_readdata(ap);

    switch (a->type) {
    case AP3216C_ATTR_IR:
        ret = sysfs_emit(buf, "%u\n", ap->ir);
		break;
    case AP3216C_ATTR_ALS:
        ret = sysfs_emit(buf, "%u\n", ap->als);
		break;
    case AP3216C_ATTR_PS:
        ret = sysfs_emit(buf, "%u\n", ap->ps);
		break;
    default:
        ret = -EINVAL;
		break;
    }

	return ret;
}

static int ap3216c_open(struct inode *inode, struct file *filp)
{
	u8 data = 0;
	filp->private_data = &ap3216c_dev;

	/* Verify that the Settings are successful */
	ap3216c_read_single_reg(&ap3216c_dev, AP3216C_SYSTEMCONG, &data);
	pr_debug("ap3216c open(reg%d:0x%02x)!\n", AP3216C_SYSTEMCONG, data);

	return 0;
}

static ssize_t ap3216c_read(struct file *filp, char __user *user, size_t count, loff_t *loffp)
{
	int ret = 0;
	u16 buf[3] = {0};
	struct ap3216c_device *dev = filp->private_data;

	if(count > sizeof(buf)){
		count = sizeof(buf);
	}

	ap3216c_readdata(dev);
	buf[0] = dev->ir;
	buf[1] = dev->ps;
	buf[2] = dev->als;
	//Returns number of bytes that could not be copied. On success, this will be zero.
	ret = copy_to_user(user, buf, count);

	return count - ret;
}

static int ap3216c_release(struct inode *inode, struct file *filp)
{
	filp->private_data = NULL;
	pr_debug("ap3216c close!\n");

	return 0;
}

static int ap3216c_probe(struct i2c_client *client, const struct i2c_device_id *id)
{
	int ret = 0;

	pr_info("probe!\n");
	//check basic function support
	if (!i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_BYTE_DATA)){
		pr_err("check i2c function failed!\n");
		return -EIO;
	}

	ret = alloc_chrdev_region(&ap3216c_dev.devid, 0, DEVICE_CNT, DEVICE_NAME);
	if (ret < 0) {
		pr_err("chrdev region error!\n");
		return ret;
	}

	cdev_init(&ap3216c_dev.cdev, &ap3216c_fops);
	ap3216c_dev.cdev.owner = THIS_MODULE;
	ret = cdev_add(&ap3216c_dev.cdev, ap3216c_dev.devid, DEVICE_CNT);
	if (ret < 0) {
		pr_err("cdev add error!\n");
		goto fail_cdev_add;
	}

	ap3216c_dev.class = class_create(THIS_MODULE, DEVICE_NAME);
	if (IS_ERR(ap3216c_dev.class)) {
		pr_err("class create error!\n");
		ret = PTR_ERR(ap3216c_dev.class);
		goto fail_class_create;
	}

	ap3216c_dev.device = device_create(ap3216c_dev.class, NULL, ap3216c_dev.devid, NULL, DEVICE_NAME);
	if (IS_ERR(ap3216c_dev.device)) {
		pr_err("device create error!\n");
		ret = PTR_ERR(ap3216c_dev.device);
		goto fail_device_create;
	}

	ap3216c_dev.client = client;
	i2c_set_clientdata(client, &ap3216c_dev);

	/* Reset AP3216C, When the host writes this setting, the all registers of device will become the default value after 10ms.*/
	ret = ap3216c_write_single_reg(&ap3216c_dev, AP3216C_SYSTEMCONG, 0x04);
	if(ret < 0){
		pr_err("ap3216c reset failed!\n");
		goto fail_device;
	}

	mdelay(10);
	/* AP3216C ALS and PS+IR functions actions */
	ret = ap3216c_write_single_reg(&ap3216c_dev, AP3216C_SYSTEMCONG, 0x03);
	if(ret < 0){
		pr_err("ap3216c init failed!\n");
		goto fail_device;
	}

	ret = sysfs_create_group(&client->dev.kobj, &ap3216c_attrs_group);
	if (ret) {
		pr_err("failed to create sysfs group\n");
		goto fail_device;
	}

	return ret;

fail_device:
    device_destroy(ap3216c_dev.class, ap3216c_dev.devid);
fail_device_create:
	class_destroy(ap3216c_dev.class);
fail_class_create:
	cdev_del(&ap3216c_dev.cdev);
fail_cdev_add:
	unregister_chrdev_region(ap3216c_dev.devid, DEVICE_CNT);

	return ret;
}

static int ap3216c_remove(struct i2c_client *client)
{
	struct ap3216c_device *ap = i2c_get_clientdata(client);

	pr_info("ap3216c_remove!\n");
    sysfs_remove_group(&client->dev.kobj, &ap3216c_attrs_group);
	device_destroy(ap->class, ap->devid);
    class_destroy(ap->class);
    cdev_del(&ap->cdev);
    unregister_chrdev_region(ap->devid, DEVICE_CNT);

	return 0;
}

static const struct i2c_device_id ap3216c_id_table[] = {
	{"ap3216c", 0},
	{}
};

static const struct of_device_id ap3216c_match_table[] = {
	{ .compatible = "alientek,ap3216c"},
	{}
};

static struct i2c_driver ap3216c_driver = {
	.driver = {
		.name = "ap3216c",
		.owner = THIS_MODULE,
		.of_match_table = ap3216c_match_table,  
	},
	.probe = ap3216c_probe,
	.remove = ap3216c_remove,
	.id_table = ap3216c_id_table, 
};

module_i2c_driver(ap3216c_driver);
MODULE_AUTHOR("ym");
MODULE_LICENSE("GPL");
