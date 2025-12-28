#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/cdev.h>
#include <linux/spi/spi.h>
#include <linux/uaccess.h>
#include <linux/version.h>
#include "icm20608.h"
#include <linux/sysfs.h>
#include <linux/regmap.h>

#define DEVICE_CNT	1
#define DEVICE_NAME	"icm20608"

#if LINUX_VERSION_CODE <= KERNEL_VERSION(5, 6, 0)
#define sysfs_emit(buf, fmt, ...) \
    scnprintf(buf, PAGE_SIZE, fmt, ##__VA_ARGS__)
#endif

#define ICM20608_ATTR_RO(_name, _type)           \
static struct icm20608_attr icm20608_attr_##_name = { \
    .dev_attr = __ATTR(_name, 0444, icm20608_show, NULL), \
    .type = _type,                              \
}

enum icm20608_attr_type {
    ICM20608_ATTR_GX,
    ICM20608_ATTR_GY,
    ICM20608_ATTR_GZ,
    ICM20608_ATTR_AX,
    ICM20608_ATTR_AY,
    ICM20608_ATTR_AZ,
    ICM20608_ATTR_TEMP,
};

struct icm20608_attr {
	struct device_attribute dev_attr;
	enum icm20608_attr_type type;
};

struct icm20608_dev {
	dev_t devid;				
	struct cdev cdev;			
	struct class *class;		
	struct device *device;		
	struct spi_device *spi;
	int gx, gy, gz;		
	int ax, ay, az;		
	int temp;		
	struct regmap *regmap;
};
static struct icm20608_dev icm20608dev;

static ssize_t icm20608_show(struct device *dev, struct device_attribute *attr, char *buf);

ICM20608_ATTR_RO(gx, ICM20608_ATTR_GX);
ICM20608_ATTR_RO(gy, ICM20608_ATTR_GY);
ICM20608_ATTR_RO(gz, ICM20608_ATTR_GZ);
ICM20608_ATTR_RO(ax, ICM20608_ATTR_AX);
ICM20608_ATTR_RO(ay, ICM20608_ATTR_AY);
ICM20608_ATTR_RO(az, ICM20608_ATTR_AZ);
ICM20608_ATTR_RO(temp, ICM20608_ATTR_TEMP);

static struct attribute *icm20608_attrs[] = {
	&icm20608_attr_gx.dev_attr.attr,
	&icm20608_attr_gy.dev_attr.attr,
	&icm20608_attr_gz.dev_attr.attr,
	&icm20608_attr_ax.dev_attr.attr,
	&icm20608_attr_ay.dev_attr.attr,
	&icm20608_attr_az.dev_attr.attr,
	&icm20608_attr_temp.dev_attr.attr,
	NULL,
};

static const struct attribute_group icm20608_attrs_group = {
	.attrs = icm20608_attrs,
};

static int icm20608_read_reg(struct icm20608_dev *dev, unsigned char reg, void *buf)
{
	return regmap_read(dev->regmap, reg, buf);
}

static int icm20608_write_reg(struct icm20608_dev *dev, unsigned char reg,  unsigned int data)
{
	return regmap_write(dev->regmap,  reg, data);
}

static int icm20608_readdata(struct icm20608_dev *dev)
{
	int ret = 0;
	unsigned char data[14] = { 0 };

	ret = regmap_bulk_read(dev->regmap, ICM20_ACCEL_XOUT_H, data, 14);
	if(ret == 0){
		dev->ax = (data[0] << 8) | data[1]; 
		dev->ay = (data[2] << 8) | data[3]; 
		dev->az = (data[4] << 8) | data[5]; 
		dev->temp = (data[6] << 8) | data[7]; 
		dev->gx = (data[8] << 8) | data[9]; 
		dev->gy = (data[10] << 8) | data[11];
		dev->gz = (data[12] << 8) | data[13];
	}

	return ret;
}

static ssize_t icm20608_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret = 0;
	struct spi_device *spi = to_spi_device(dev);
	struct icm20608_dev *icm20608 = spi_get_drvdata(spi);
	struct icm20608_attr *a = container_of(attr, struct icm20608_attr, dev_attr);

	icm20608_readdata(icm20608);
	switch(a->type){
		case ICM20608_ATTR_GX:
			ret = sysfs_emit(buf, "%d\n", icm20608->gx);
			break;
		case ICM20608_ATTR_GY:
			ret = sysfs_emit(buf, "%d\n", icm20608->gy);
			break;
		case ICM20608_ATTR_GZ:
			ret = sysfs_emit(buf, "%d\n", icm20608->gz);
			break;
		case ICM20608_ATTR_AX:
			ret = sysfs_emit(buf, "%d\n", icm20608->ax);
			break;
		case ICM20608_ATTR_AY:
			ret = sysfs_emit(buf, "%d\n", icm20608->ay);
			break;
		case ICM20608_ATTR_AZ:
			ret = sysfs_emit(buf, "%d\n", icm20608->az);
			break;
		case ICM20608_ATTR_TEMP:
			ret = sysfs_emit(buf, "%d\n", icm20608->temp);
			break;
		default:
			ret = -EINVAL;
			break;
	}

	return ret;
}

static int icm20608_open(struct inode *inode, struct file *filp)
{
	pr_debug("open\n");
	filp->private_data = &icm20608dev;

	return 0;
}

static ssize_t icm20608_read(struct file *filp, char __user *buf, size_t cnt, loff_t *off)
{
	signed int data[7];
	struct icm20608_dev *dev = filp->private_data;
	int ret = 0, len = 0;;

	if(cnt > sizeof(data))
		cnt = sizeof(data);

	ret = icm20608_readdata(dev);
	if(ret == 0){
		data[0] = dev->gx;
		data[1] = dev->gy;
		data[2] = dev->gz;
		data[3] = dev->ax;
		data[4] = dev->ay;
		data[5] = dev->az;
		data[6] = dev->temp;
		len = copy_to_user(buf, data, cnt);
		ret = cnt - len;
	}

	return ret;
}

static int icm20608_release(struct inode *inode, struct file *filp)
{
	pr_debug("closed\n");
	filp->private_data = NULL;

	return 0;
}

static const struct file_operations icm20608_fops = {
	.owner = THIS_MODULE,
	.open = icm20608_open,
	.read = icm20608_read,
	.release = icm20608_release,
};

void icm20608_init(void)
{
	u32 value = 0;
	
	icm20608_write_reg(&icm20608dev, ICM20_PWR_MGMT_1, 0x80);
	mdelay(5);
	icm20608_write_reg(&icm20608dev, ICM20_PWR_MGMT_1, 0x01);
	mdelay(5);

	icm20608_read_reg(&icm20608dev, ICM20_WHO_AM_I, &value);
	pr_info("ICM20608 ID = %#X\n", value);	

	icm20608_write_reg(&icm20608dev, ICM20_SMPLRT_DIV, 0x00); 	
	icm20608_write_reg(&icm20608dev, ICM20_GYRO_CONFIG, 0x18); 	
	icm20608_write_reg(&icm20608dev, ICM20_ACCEL_CONFIG, 0x18); 	
	icm20608_write_reg(&icm20608dev, ICM20_CONFIG, 0x04); 		
	icm20608_write_reg(&icm20608dev, ICM20_ACCEL_CONFIG2, 0x04); 
	icm20608_write_reg(&icm20608dev, ICM20_PWR_MGMT_2, 0x00); 	
	icm20608_write_reg(&icm20608dev, ICM20_LP_MODE_CFG, 0x00); 	
	icm20608_write_reg(&icm20608dev, ICM20_FIFO_EN, 0x00);		
}

static int icm20608_probe(struct spi_device *spi)
{
	int ret = 0;
	 struct regmap_config config = {0};

	pr_info("probe!\n");
	config.reg_bits = 8;
	config.val_bits = 8;
	config.read_flag_mask = 0x80;
	icm20608dev.regmap = regmap_init_spi(spi, &config);
	if(IS_ERR(icm20608dev.regmap)){
		pr_err("failed regmap_init_spi\n");
		return PTR_ERR(icm20608dev.regmap);
	}

	ret = alloc_chrdev_region(&icm20608dev.devid, 0, DEVICE_CNT, DEVICE_NAME);
	if(ret < 0){
		pr_err("chrdev region error\n");
		return ret;
	}

	cdev_init(&icm20608dev.cdev, &icm20608_fops);
	icm20608dev.cdev.owner = THIS_MODULE;
	ret = cdev_add(&icm20608dev.cdev, icm20608dev.devid, DEVICE_CNT);
	if(ret < 0){
		pr_err("cdev_add error\n");
		goto fail_cdev_add;
	}

	icm20608dev.class = class_create(THIS_MODULE, DEVICE_NAME);
	if (IS_ERR(icm20608dev.class)) {
		pr_err("class_create error!\n");
		ret = PTR_ERR(icm20608dev.class);
		goto fail_class_create;
	}

	icm20608dev.device = device_create(icm20608dev.class, NULL, icm20608dev.devid, NULL, DEVICE_NAME);
	if (IS_ERR(icm20608dev.device)) {
		pr_err("device_create error\n");
		ret = PTR_ERR(icm20608dev.device);
		goto fail_device_create;
	}

	spi->mode = SPI_MODE_0;	
	ret = spi_setup(spi);
	if(ret < 0){
		pr_err("spi_setup error\n");
		goto fail_device;
	}

	icm20608dev.spi = spi; 
	spi_set_drvdata(spi, &icm20608dev);
	icm20608_init();		

	ret = sysfs_create_group(&spi->dev.kobj, &icm20608_attrs_group);
	if(ret){
		pr_err("failed to sysfs_create_group\n");
		goto fail_device;
	}

	return ret;
fail_device:
	device_destroy(icm20608dev.class, icm20608dev.devid);
fail_device_create:
	class_destroy(icm20608dev.class);
fail_class_create:
	cdev_del(&icm20608dev.cdev);
fail_cdev_add:
	unregister_chrdev_region(icm20608dev.devid, DEVICE_CNT);
	regmap_exit(icm20608dev.regmap);

	return ret;
}

static int icm20608_remove(struct spi_device *spi)
{
	struct icm20608_dev *icm = spi_get_drvdata(spi);
	pr_info("remove\n");
	sysfs_remove_group(&spi->dev.kobj, &icm20608_attrs_group);
	device_destroy(icm->class, icm->devid);
	class_destroy(icm->class);
	cdev_del(&icm->cdev);
	unregister_chrdev_region(icm->devid, DEVICE_CNT);
	regmap_exit(icm->regmap);

	return 0;
}

static const struct spi_device_id icm20608_id[] = {
	{"alientek,icm20608", 0},  
	{}
};

static const struct of_device_id icm20608_of_match[] = {
	{ .compatible = "alientek,icm20608" },
	{}
};

static struct spi_driver icm20608_driver = {
	.driver = {
			.owner = THIS_MODULE,
		   	.name = "icm20608",
		   	.of_match_table = icm20608_of_match, 
		   },
	.id_table = icm20608_id,
	.probe = icm20608_probe,
	.remove = icm20608_remove,
};
		   
module_spi_driver(icm20608_driver);
MODULE_AUTHOR("ym");
MODULE_LICENSE("GPL");
