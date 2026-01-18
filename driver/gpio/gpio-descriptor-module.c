#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>      /* For platform devices */
#include <linux/gpio/consumer.h>        /* For GPIO Descriptor interface */
#include <linux/interrupt.h>            /* For IRQ */
#include <linux/of.h>                   /* For DT*/

/*
 * Let us consider the bellow mapping
 *
 *    foo_device {
 *       compatible = "packt,gpio-descriptor-sample";
 *       led-gpios = <&gpio2 15 GPIO_ACTIVE_HIGH>, // red 
 *                   <&gpio2 16 GPIO_ACTIVE_HIGH>, // green 
 *
 *       btn1-gpios = <&gpio2 1 GPIO_ACTIVE_LOW>;
 *       btn2-gpios = <&gpio2 1 GPIO_ACTIVE_LOW>;
 *   };
 */

static struct gpio_desc *led, *key0, *key1, *wkup;
static int irq;

static irqreturn_t key_pushed_irq_handler(int irq, void *dev_id)
{
    static int state;

	state = !state;
    gpiod_set_value(led, state);
    pr_info("led -> %d\n", state);

    return IRQ_HANDLED;
}

static const struct of_device_id gpiod_dt_ids[] = {
    { .compatible = "alientek,gpio-descriptor-sample", },
    { /* sentinel */ }
};


static int my_pdrv_probe (struct platform_device *pdev)
{
    struct device *dev = &pdev->dev;

    /*
     * We use gpiod_get/gpiod_get_index() along with the flags
     * in order to configure the GPIO direction and an initial
     * value in a single function call.
     *
     * One could have used:
     *  red = gpiod_get_index(dev, "led", 0);
     *  gpiod_direction_output(red, 0);
     */
    led = gpiod_get(dev, "led", GPIOD_OUT_HIGH);
    gpiod_export(led, 0);

    /*
     * Configure Button GPIOs as input
     *
     * After this, one can call gpiod_set_debounce()
     * only if the controller has the feature
     * For example, to debounce  a button with a delay of 200ms
     *  gpiod_set_debounce(btn1, 200);
     */
    key0 = gpiod_get(dev, "key0", GPIOD_IN);
    key1= gpiod_get(dev, "key1", GPIOD_IN);
    wkup = gpiod_get(dev, "wkup", GPIOD_IN);
    gpiod_export(key0, "key0");
    gpiod_export(key1, "key1");

    irq = gpiod_to_irq(wkup);
    request_threaded_irq(irq, NULL,
                            key_pushed_irq_handler,
                            IRQF_TRIGGER_FALLING | IRQF_ONESHOT,
                            "gpio-descriptor-sample", NULL);
    pr_info("Hello! device probed!\n");
    return 0;
}

static int my_pdrv_remove(struct platform_device *pdev)
{
    free_irq(irq, NULL);
    gpiod_put(led);
    gpiod_put(key0);
    gpiod_put(key1);
    gpiod_put(wkup);
    pr_info("good bye reader!\n");
    return 0;
}

static struct platform_driver mypdrv = {
    .probe      = my_pdrv_probe,
    .remove     = my_pdrv_remove,
    .driver     = {
        .name     = "gpio_descriptor_sample",
        .of_match_table = of_match_ptr(gpiod_dt_ids),  
        .owner    = THIS_MODULE,
    },
};
module_platform_driver(mypdrv);

MODULE_AUTHOR("YM");
MODULE_LICENSE("GPL");
