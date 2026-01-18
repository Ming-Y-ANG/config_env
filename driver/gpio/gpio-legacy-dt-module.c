#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>      /* For platform devices */
#include <linux/interrupt.h>            /* For IRQ */
#include <linux/gpio.h>                 /* For Legacy integer based GPIO */
#include <linux/of_gpio.h>              /* For of_gpio* functions */
#include <linux/of.h>                   /* For DT*/


/*
 * Let us consider the node bellow
 *
 *    foo_device {
 *       compatible = "packt,gpio-legacy-sample";
 *       led-gpios = <&gpio2 15 GPIO_ACTIVE_HIGH>, // red 
 *                   <&gpio2 16 GPIO_ACTIVE_HIGH>, // green 
 *
 *       btn1-gpios = <&gpio2 1 GPIO_ACTIVE_LOW>;
 *       btn2-gpios = <&gpio2 1 GPIO_ACTIVE_LOW>;
 *   };
 */

static unsigned int gpio_led, gpio_key0, gpio_key1, gpio_wkup;
static int irq;

static irqreturn_t key_pushed_irq_handler(int irq, void *dev_id)
{
    static int state = 0;

	state = !state;
    /* read the button value and change the led state */
    gpio_set_value(gpio_led, state);

    pr_info("led 0 -> %d\n", state);

    return IRQ_HANDLED;
}

static const struct of_device_id gpio_dt_ids[] = {
    { .compatible = "alientek,gpio-legacy-sample", },
    { /* sentinel */ }
};

static int my_pdrv_probe (struct platform_device *pdev)
{
    struct device_node *np = pdev->dev.of_node;

    if (!np)
        return -ENOENT;

    gpio_led = of_get_named_gpio(np, "led-gpios", 0);
    gpio_key0 = of_get_named_gpio(np, "key0-gpios", 0);
    gpio_key1 = of_get_named_gpio(np, "key1-gpios", 0);
    gpio_wkup = of_get_named_gpio(np, "wkup-gpios", 0);

    gpio_request(gpio_led, "led");
    gpio_request(gpio_key0, "key0");
    gpio_request(gpio_key1, "key1");
    gpio_request(gpio_wkup, "wkup");
    gpio_export(gpio_led, 0);
    gpio_export(gpio_key0, 0);
    gpio_export(gpio_key1, 0);

    /*
     * Configure Button GPIOs as input
     *
     * After this, one can call gpio_set_debounce()
     * only if the controller has the feature
     *
     * For example, to debounce  a button with a delay of 200ms
     *  gpio_set_debounce(gpio_btn1, 200);
     */
    gpio_direction_input(gpio_key0);
    gpio_direction_input(gpio_key1);
    gpio_direction_input(gpio_wkup);

    /*
     * Set LED GPIOs as output, with their initial values set to 0
     */
    gpio_direction_output(gpio_led, 0);

    irq = gpio_to_irq(gpio_wkup);
	request_threaded_irq(irq, NULL,\
						key_pushed_irq_handler, \
						IRQF_TRIGGER_FALLING | IRQF_ONESHOT, \
						"KEY_WKUP", NULL);

    pr_info("Hello world!\n");
    return 0;
}

static int my_pdrv_remove(struct platform_device *pdev)
{
    free_irq(irq, NULL);
    gpio_free(gpio_led);
    gpio_free(gpio_key0);
    gpio_free(gpio_key1);
    gpio_free(gpio_wkup);

    pr_info("End of the world\n");
    return 0;
}


static struct platform_driver mypdrv = {
    .probe      = my_pdrv_probe,
    .remove     = my_pdrv_remove,
    .driver     = {
        .name     = "gpio_legacy_sample",
        .of_match_table = of_match_ptr(gpio_dt_ids),  
        .owner    = THIS_MODULE,
    },
};
module_platform_driver(mypdrv);

MODULE_AUTHOR("YM");
MODULE_LICENSE("GPL");
