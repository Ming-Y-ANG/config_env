#include <linux/module.h>
#include <linux/init.h>
#include <linux/sched.h>
#include <linux/time.h>
#include <linux/delay.h>
#include<linux/workqueue.h>

static DECLARE_WAIT_QUEUE_HEAD(my_wq);
static int condition = 0;

/* declare a work queue*/
static struct work_struct wrk;

static void work_handler(struct work_struct *work)
{ 
    pr_info("Waitqueue module handler %s\n", __FUNCTION__);
    msleep(3000);
    pr_info("Wake up the sleeping module\n");
    condition = 1;
	/*
	 * wake up one process sleeping in the wait queue if
	 * CONDITION above has become true
	 */
    wake_up_interruptible(&my_wq);
}

static int __init my_init(void)
{
    pr_info("Wait queue example\n");

    INIT_WORK(&wrk, work_handler);
    schedule_work(&wrk);

    pr_info("Going to sleep %s\n", __FUNCTION__);
	/*
	 * block the current task (process) in the wait queue if CONDITION is false
	 * wait_event_interruptible does not continuously poll, but simply evaluates the
	 * condition when it is called. If the condition is false, the process is put into a
	 * TASK_INTERRUPTIBLE state and removed from the run queue. The condition is then only
	 * rechecked each time you call wake_up_interruptible in the wait queue. If the condition
	 * is true when wake_up_interruptible runs, a process in the wait queue will be
	 * awakened, and its state set to TASK_RUNNING. Processes are awakened in the order they are
	 * put to sleep. To awaken all processes waiting in the queue, you should use
	 * wake_up_interruptible_all
	 * In fact, the main functions are wait_event, wake_up, and wake_up_all.
	 * They are used with processes in the queue in an exclusive
	 * (TASK_UNINTERRUPTIBLE) wait, since they can't be interrupted by the signal. They
	 * should be used only for critical tasks. Interruptible functions are just
	 * optional (but recommended). Since they can be interrupted by signals, you
	 * should check their return value. A nonzero value means your sleep has
	 * been interrupted by some sort of signal, and the driver should return
	 * ERESTARTSYS.
	 */
    wait_event_interruptible(my_wq, condition != 0);

    pr_info("woken up by the work job\n");
    return 0;
}

void my_exit(void)
{
    pr_info("waitqueue example cleanup\n");
}

module_init(my_init);
module_exit(my_exit);
MODULE_AUTHOR("John Madieu <john.madieu@gmail.com>");
MODULE_LICENSE("GPL");
