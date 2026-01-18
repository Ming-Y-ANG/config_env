#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/gpio.h>                 /* For Legacy integer based GPIO */
#include <linux/interrupt.h>            /* For IRQ */

/*
 * Please choose values that are free on your system
 */
enum {
	GPIO_KEY_WKUP = 0, //PA0
	GPIO_KEY0 = 99, //PG3
	GPIO_LED1 = 83, //PF3
	GPIO_KEY1 = 119, //PH7
};

enum {
	GPIO_DIR_IN,
	GPIO_DIR_OUT,
};

struct gpio_info{
	char *name;
	unsigned int id;
	unsigned int dir;
};

struct gpio_info gpios[] = {
	{
		.name = "KEY_WKUP",
		.id = GPIO_KEY_WKUP,
		.dir = GPIO_DIR_IN,
	},
	{
		.name = "KEY0",
		.id = GPIO_KEY0,
		.dir = GPIO_DIR_IN,
	},
	{
		.name = "LED1",
		.id = GPIO_LED1,
		.dir = GPIO_DIR_OUT,
	},
	{
		.name = "KEY1",
		.id = GPIO_KEY1,
		.dir = GPIO_DIR_IN,
	},
};
static int irq;

static irqreturn_t key_pushed_irq_handler(int irq, void *dev_id)
{
    static int state = 0;

	state = !state;
    gpio_set_value(GPIO_LED1, state);
    pr_info("set LED1 -> %d\n", state);

    return IRQ_HANDLED;
}

static int __init hellowolrd_init(void)
{
	int i;

    /*
     * One could have checked whether the GPIO is valid on the controller or not,
     * using gpio_is_valid() function.
     * Ex:
     *  if (!gpio_is_valid(GPIO_LED_RED)) {
     *       pr_infor("Invalid Red LED\n");
     *       return -ENODEV;
     *   }
     */
	for(i = 0; i < sizeof(gpios)/sizeof(gpios[0]); i++){
		if(!gpio_is_valid(gpios[i].id)) {
			pr_info("invalid gpio(%s): %d\n", gpios[i].name, gpios[i].id);
			continue;
		}
		gpio_request(gpios[i].id, gpios[i].name);
		/*
		 * Configure Button GPIOs as input
		 *
		 * After this, one can call gpio_set_debounce()
		 * only if the controller has the feature
		 *
		 * For example, to debounce  a button with a delay of 200ms
		 *  gpio_set_debounce(GPIO_BTN1, 200);
		 */
		if(gpios[i].dir == GPIO_DIR_IN){
			gpio_direction_input(gpios[i].id);
		}else{
			gpio_direction_output(gpios[i].id, 1);
		}	
	}

    irq = gpio_to_irq(GPIO_KEY_WKUP);
#if 0
	//create a kernel thread to handle irq, process context
	request_threaded_irq(irq, NULL,\
						key_pushed_irq_handler, \
						IRQF_TRIGGER_FALLING | IRQF_ONESHOT, \
						"KEY_WKUP", NULL);
#endif	
	request_irq(irq, key_pushed_irq_handler,\
					IRQF_TRIGGER_FALLING | IRQF_ONESHOT, \
					"KEY_WKUP", NULL);

    pr_info("Hello world!\n");

    return 0;
}

static void __exit hellowolrd_exit(void)
{
	int i;
    free_irq(irq, NULL);
	for(i = 0; i < sizeof(gpios)/sizeof(gpios[0]); i++){
		gpio_free(gpios[i].id);
	}

    pr_info("End of the world\n");
}


module_init(hellowolrd_init);
module_exit(hellowolrd_exit);
MODULE_AUTHOR("YM");
MODULE_LICENSE("GPL");
