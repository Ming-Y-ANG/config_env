# Libevent Signal 处理机制详解

## 目录

- [一、设计思想](#一设计思想)
- [二、核心数据结构](#二核心数据结构)
- [三、初始化流程](#三初始化流程)
- [四、注册信号事件](#四注册信号事件)
- [五、信号触发流程](#五信号触发流程)
- [六、事件循环处理](#六事件循环处理)
- [七、执行用户回调](#七执行用户回调)
- [八、完整调用链](#八完整调用链)
- [九、重要注意事项](#九重要注意事项)

---

## 一、设计思想

Libevent 采用经典的 **"socketpair + 信号处理函数"** 模式来解决信号异步安全的问题：

### 1.1 问题背景

- 信号处理函数在**异步上下文**执行，受到严格限制
- 不能调用非异步信号安全的函数（如 `malloc`、`printf` 等）
- 不能直接操作事件循环的数据结构（可能引发死锁或数据竞争）
- 需要一种机制将异步信号转换为同步事件处理

### 1.2 解决方案

```
+-------------+     signal      +------------------+
|   Kernel    | --------------> | evsig_handler()  |
+-------------+                 +------------------+
                                      |
                                      | write(1 byte)
                                      v
                               +-------------+
                               | socketpair  |
                               |   [1]写端   |
                               +-------------+
                                      |
                                      v
                               +-------------+
                               | socketpair  |
                               |   [0]读端   |
                               +-------------+
                                      |
                                      | epoll_wait/kqueue
                                      | 检测到可读
                                      v
                               +------------------+
                               |   evsig_cb()     |
                               | (事件循环线程)    |
                               +------------------+
                                      |
                                      | 激活 signal 事件
                                      v
                               +------------------+
                               |  用户回调函数     |
                               | event_callback   |
                               +------------------+
```

**核心机制**：
- 信号处理函数只向 socketpair 写入信号编号（异步信号安全）
- 事件循环通过 I/O 多路复用检测到 socketpair 可读
- 在主线程中同步调用用户回调（避免异步上下文限制）

---

## 二、核心数据结构

### 2.1 evsig_info（信号管理结构）

```c
// evsignal-internal.h:39
struct evsig_info {
    /* 内部事件，监听 ev_signal_pair[0] 的读事件 */
    struct event ev_signal;
    
    /* Socketpair 用于从信号处理函数发送通知 */
    evutil_socket_t ev_signal_pair[2];
    
    /* 标记是否已将 ev_signal 添加到事件循环 */
    int ev_signal_added;
    
    /* 当前监听的信号数量 */
    int ev_n_signals_added;
    
#ifdef EVENT__HAVE_SYS_SIGNALFD_H
    /* signalfd 支持（Linux 特有） */
    struct event *ev_sigevent[NSIG];
#endif

    /* 保存旧的信号处理函数，用于恢复 */
#ifdef EVENT__HAVE_SIGACTION
    struct sigaction **sh_old;
#else
    ev_sighandler_t **sh_old;
#endif
    /* sh_old 数组大小 */
    int sh_old_max;
};
```

### 2.2 event_signal_map（信号映射表）

```c
// event-internal.h
struct event_signal_map {
    void **entries;      // 信号号 -> evmap_signal* 映射
    int nentries;        // entries 数组大小
};

// evmap.c:68
struct evmap_signal {
    struct event_dlist events;  // 监听该信号的所有事件链表
};
```

### 2.3 event（信号事件结构）

```c
// event_struct.h
struct event {
    struct event_callback ev_evcallback;
    
    evutil_socket_t ev_fd;        // 对于信号事件，fd = 信号编号
    short ev_events;              // EV_SIGNAL | EV_PERSIST
    short ev_res;                 // 触发结果（EV_SIGNAL）
    
    union {
        struct {
            // 信号事件专用字段
            int ev_ncalls;        // 回调需要执行的次数
            int *ev_pncalls;      // 指向 ncalls 的指针（支持删除）
        } ev_signal;
        // ...
    } ev_; 
    
    // 链表指针：用于 sigmap 中的链表
    LIST_ENTRY(event) ev_signal_next;
};
```

---

## 三、初始化流程

### 3.1 event_base 创建时初始化信号子系统

```c
// signal.c:175
int evsig_init_(struct event_base *base)
{
    /*
     * 创建内部 socketpair：
     * - Unix：使用 pipe() 或 socketpair()
     * - Windows：使用 socketpair()
     * - 设置为非阻塞模式
     */
    if (evutil_make_internal_pipe_(base->sig.ev_signal_pair) == -1) {
#ifdef _WIN32
        event_sock_warn(-1, "%s: socketpair", __func__);
        return -1;  // Windows 上非致命
#else
        event_sock_err(1, -1, "%s: socketpair", __func__);
        return -1;
#endif
    }

    /* 清理旧的信号处理函数保存数组 */
    if (base->sig.sh_old) {
        mm_free(base->sig.sh_old);
    }
    base->sig.sh_old = NULL;
    base->sig.sh_old_max = 0;

    /*
     * 初始化内部事件：
     * - 监听 socketpair[0]（读端）
     * - EV_READ | EV_PERSIST：持续监听可读事件
     * - 回调函数：evsig_cb
     * - 回调参数：base（event_base 指针）
     */
    event_assign(&base->sig.ev_signal, base, base->sig.ev_signal_pair[0],
        EV_READ | EV_PERSIST, evsig_cb, base);

    /* 标记为内部事件（不计入用户事件统计） */
    base->sig.ev_signal.ev_flags |= EVLIST_INTERNAL;
    
    /* 设置最高优先级（0），确保信号事件优先处理 */
    event_priority_set(&base->sig.ev_signal, 0);

    /* 注册 signal 后端操作表 */
    base->evsigsel = &evsigops;

    return 0;
}
```

### 3.2 evsigops（信号后端操作表）

```c
// signal.c:96
static const struct eventop evsigops = {
    "signal",        // 名称
    NULL,            // init（不需要）
    evsig_add,       // add：添加信号监听
    evsig_del,       // del：删除信号监听
    NULL,            // dispatch（不需要，依赖 socketpair 的 I/O 事件）
    NULL,            // dealloc
    0, 0, 0          // 标志位
};
```

**说明**：signal 后端不同于 epoll/kqueue 等 I/O 后端，它不直接参与事件分派。真正的分派是通过 socketpair 的 I/O 事件完成的。

---

## 四、注册信号事件

### 4.1 用户 API

```c
// include/event2/event.h
#define evsignal_new(b, x, cb, arg) \
    event_new((b), (x), EV_SIGNAL|EV_PERSIST, (cb), (arg))

#define evsignal_assign(ev, b, x, cb, arg) \
    event_assign((ev), (b), (x), EV_SIGNAL|EV_PERSIST, cb, (arg))

#define evsignal_add(ev, tv) \
    event_add((ev), (tv))

#define evsignal_del(ev) \
    event_del(ev)
```

### 4.2 event_assign 初始化信号事件

```c
// event.c:2204
int event_assign(struct event *ev, struct event_base *base, evutil_socket_t fd,
    short events, void (*callback)(evutil_socket_t, short, void *), void *arg)
{
    // ... 基础初始化 ...
    
    ev->ev_fd = fd;           // 对于信号事件，fd = 信号编号（如 SIGINT）
    ev->ev_events = events;   // EV_SIGNAL | EV_PERSIST
    
    if (events & EV_SIGNAL) {
        ev->ev_closure = EV_CLOSURE_EVENT_SIGNAL;
    }
    // ...
}
```

### 4.3 event_add 添加事件

```c
// event.c:2704
int event_add_nolock_(struct event *ev, const struct timeval *tv, int tv_is_absolute)
{
    // ...
    if ((ev->ev_events & (EV_READ|EV_WRITE|EV_CLOSED|EV_SIGNAL)) &&
        !(ev->ev_flags & (EVLIST_INSERTED|EVLIST_ACTIVE|EVLIST_ACTIVE_LATER))) {
        
        if (ev->ev_events & (EV_READ|EV_WRITE|EV_CLOSED))
            res = evmap_io_add_(base, ev->ev_fd, ev);
        else if (ev->ev_events & EV_SIGNAL)
            res = evmap_signal_add_(base, (int)ev->ev_fd, ev);
            
        if (res != -1)
            event_queue_insert_inserted(base, ev);
    }
    // ...
}
```

### 4.4 evmap_signal_add_ 信号映射添加

```c
// evmap.c:449
int evmap_signal_add_(struct event_base *base, int sig, struct event *ev)
{
    const struct eventop *evsel = base->evsigsel;  // 指向 evsigops
    struct event_signal_map *map = &base->sigmap;
    struct evmap_signal *ctx = NULL;

    /* 检查信号号有效性 */
    if (sig < 0 || sig >= NSIG)
        return (-1);

    /* 确保 sigmap 数组足够大 */
    if (sig >= map->nentries) {
        if (evmap_make_space(map, sig, sizeof(struct evmap_signal *)) == -1)
            return (-1);
    }

    /* 获取或创建该信号号对应的 evmap_signal 槽位 */
    GET_SIGNAL_SLOT_AND_CTOR(ctx, map, sig, evmap_signal, 
        evmap_signal_init, base->evsigsel->fdinfo_len);

    /* 
     * 如果这是第一个监听该信号的事件：
     * - 调用后端 add 操作（evsig_add）
     * - 注册系统信号处理函数
     */
    if (LIST_EMPTY(&ctx->events)) {
        if (evsel->add(base, ev->ev_fd, 0, EV_SIGNAL, ev) == -1)
            return (-1);
    }

    /* 将 event 插入该信号的事件链表头部 */
    LIST_INSERT_HEAD(&ctx->events, ev, ev_signal_next);
    
    return (1);
}
```

### 4.5 evsig_add 注册系统信号处理

```c
// signal.c:288
static int evsig_add(struct event_base *base, evutil_socket_t evsignal,
    short old, short events, void *p)
{
    struct evsig_info *sig = &base->sig;
    
    EVUTIL_ASSERT(evsignal >= 0 && evsignal < NSIG);

    /*
     * 设置全局信号处理状态：
     * 注意：evsig_base 是全局变量，同一时刻只有一个 event_base 
     * 能接收信号。如果多个 event_base 注册信号，会有警告。
     */
    EVSIGBASE_LOCK();
    if (evsig_base != base && evsig_base_n_signals_added) {
        event_warnx("Added a signal to event base %p with signals "
            "already added to event_base %p.  Only one can have "
            "signals at a time with the %s backend.  The base with "
            "the most recently added signal or the most recent "
            "event_base_loop() call gets preference; do "
            "not rely on this behavior in future Libevent versions.",
            (void *)base, (void *)evsig_base, base->evsel->name);
    }
    evsig_base = base;
    evsig_base_n_signals_added = ++sig->ev_n_signals_added;
    evsig_base_fd = base->sig.ev_signal_pair[1];  // 设置全局写端 fd
    EVSIGBASE_UNLOCK();

    event_debug(("%s: %d: changing signal handler", __func__, (int)evsignal));

    /* 
     * 使用 sigaction() 或 signal() 注册信号处理函数：
     * - 保存旧的信号处理函数到 sh_old[evsignal]
     * - 新的处理函数为 evsig_handler
     */
    if (evsig_set_handler_(base, (int)evsignal, evsig_handler) == -1) {
        goto err;
    }

    /*
     * 将内部 ev_signal 事件添加到 event_base：
     * - 监听 socketpair[0]（读端）
     * - 只需要添加一次
     */
    if (!sig->ev_signal_added) {
        if (event_add_nolock_(&sig->ev_signal, NULL, 0))
            goto err;
        sig->ev_signal_added = 1;
    }
    
    return (0);

err:
    EVSIGBASE_LOCK();
    --evsig_base_n_signals_added;
    --sig->ev_n_signals_added;
    EVSIGBASE_UNLOCK();
    return (-1);
}
```

### 4.6 evsig_set_handler_ 保存旧处理函数

```c
// signal.c:238
int evsig_set_handler_(struct event_base *base,
    int evsignal, void (__cdecl *handler)(int))
{
    struct evsig_info *sig = &base->sig;

    /* 确保保存数组足够大 */
    if (evsig_ensure_saved_(sig, evsignal) < 0)
        return (-1);

    /* 分配空间保存旧的处理函数 */
    sig->sh_old[evsignal] = mm_malloc(sizeof *sig->sh_old[evsignal]);
    if (sig->sh_old[evsignal] == NULL) {
        event_warn("malloc");
        return (-1);
    }

    /* 保存旧处理函数并设置新处理函数 */
#ifdef EVENT__HAVE_SIGACTION
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;           // 信号处理函数
#ifdef SA_RESTART
    sa.sa_flags |= SA_RESTART;         // 系统调用自动重启
#endif
    sigfillset(&sa.sa_mask);           // 阻塞所有信号

    if (sigaction(evsignal, &sa, sig->sh_old[evsignal]) == -1) {
        event_warn("sigaction");
        mm_free(sig->sh_old[evsignal]);
        sig->sh_old[evsignal] = NULL;
        return (-1);
    }
#else
    ev_sighandler_t sh = signal(evsignal, handler);
    if (sh == SIG_ERR) {
        event_warn("signal");
        mm_free(sig->sh_old[evsignal]);
        sig->sh_old[evsignal] = NULL;
        return (-1);
    }
    *sig->sh_old[evsignal] = sh;
#endif

    return (0);
}
```

---

## 五、信号触发流程

### 5.1 信号发生时内核调用处理函数

```c
// signal.c:387
static void __cdecl evsig_handler(int sig)
{
    int save_errno = errno;
#ifdef _WIN32
    int socket_errno = EVUTIL_SOCKET_ERROR();
#endif
    ev_uint8_t msg;

    /* 安全检查：是否有 event_base 配置 */
    if (evsig_base == NULL) {
        event_warnx("%s: received signal %d, but have no base configured",
            __func__, sig);
        return;
    }

    /* 
     * 对于非 sigaction 系统（如某些旧系统）：
     * signal() 注册的处理函数只执行一次，需要重新注册
     */
#ifndef EVENT__HAVE_SIGACTION
    signal(sig, evsig_handler);
#endif

    /* 
     * 核心操作：向 socketpair[1] 写入信号编号
     * - write() 是异步信号安全的
     * - 只写 1 字节，即使 socketpair 满也不会阻塞（非阻塞模式）
     */
    msg = sig;
#ifdef _WIN32
    send(evsig_base_fd, (char*)&msg, 1, 0);
#else
    for (;;) {
        /* 
         * 设置 errno 为 EAGAIN：
         * 如果 write 返回 0，errno 不会自动设置，
         * 这里预设为 EAGAIN 以提供有意义的错误信息
         */
        errno = EAGAIN;
        if (0 >= write(evsig_base_fd, &msg, 1)) {
            if (errno == EINTR)
                continue;  // 被中断，重试
            event_warnx("%s: write: %s", __func__, strerror(errno));
        }
        break;
    }
#endif

    /* 恢复 errno，避免影响被中断的代码 */
    errno = save_errno;
#ifdef _WIN32
    EVUTIL_SET_SOCKET_ERROR(socket_errno);
#endif
}
```

**设计要点**：
- 信号处理函数尽可能简单，只做一件事：写 socketpair
- `write()` 是 POSIX 异步信号安全函数
- socketpair 设置为非阻塞，避免信号处理函数阻塞
- 批量信号可能导致写失败（buffer 满），这是可接受的

---

## 六、事件循环处理

### 6.1 后端检测到 socketpair[0] 可读

事件循环（如 `epoll_wait`、`kqueue`、`select` 等）检测到 `ev_signal_pair[0]` 可读，将其标记为活跃事件。

### 6.2 evsig_cb 读取信号数据

```c
// signal.c:132
static void evsig_cb(evutil_socket_t fd, short what, void *arg)
{
    static char signals[1024];  // 静态缓冲区，避免栈溢出
    ev_ssize_t n;
    int i;
    int ncaught[NSIG];          // 统计每个信号触发的次数
    struct event_base *base = arg;

    memset(&ncaught, 0, sizeof(ncaught));

    /* 
     * 批量读取所有信号通知字节：
     * - 循环读取直到没有数据
     * - 一次可能读取多个信号（信号触发很快时）
     */
    while (1) {
#ifdef _WIN32
        n = recv(fd, signals, sizeof(signals), 0);
#else
        n = read(fd, signals, sizeof(signals));
#endif
        if (n == -1) {
            int err = evutil_socket_geterror(fd);
            if (!EVUTIL_ERR_RW_RETRIABLE(err))
                event_sock_err(1, fd, "%s: recv", __func__);
            break;  // EAGAIN 或致命错误
        } else if (n == 0) {
            break;  // 对端关闭
        }

        /* 统计每个信号触发的次数 */
        for (i = 0; i < n; ++i) {
            ev_uint8_t sig = signals[i];
            if (sig < NSIG)
                ncaught[sig]++;
        }
    }

    /* 
     * 激活对应信号的所有事件：
     * - 加锁保护 event_base 数据结构
     * - 按信号编号逐个激活
     */
    EVBASE_ACQUIRE_LOCK(base, th_base_lock);
    for (i = 0; i < NSIG; ++i) {
        if (ncaught[i])
            evmap_signal_active_(base, i, ncaught[i]);
    }
    EVBASE_RELEASE_LOCK(base, th_base_lock);
}
```

### 6.3 evmap_signal_active_ 激活信号事件

```c
// evmap.c:500
void evmap_signal_active_(struct event_base *base, evutil_socket_t sig, int ncalls)
{
    struct event_signal_map *map = &base->sigmap;
    struct evmap_signal *ctx;
    struct event *ev;

    /* 边界检查 */
    if (sig < 0 || sig >= map->nentries)
        return;
    
    GET_SIGNAL_SLOT(ctx, map, sig, evmap_signal);
    if (!ctx)
        return;

    /* 
     * 遍历该信号号对应的所有 event：
     * - 一个信号可以有多个监听者
     * - 每个监听者都会被激活
     */
    LIST_FOREACH(ev, &ctx->events, ev_signal_next)
        event_active_nolock_(ev, EV_SIGNAL, ncalls);
}
```

### 6.4 event_active_nolock_ 将事件加入活跃队列

```c
// event.c:3022
void event_active_nolock_(struct event *ev, int res, short ncalls)
{
    struct event_base *base = ev->ev_base;
    
    EVENT_BASE_ASSERT_LOCKED(base);

    /* 如果事件已经在活跃队列中，合并结果 */
    switch ((ev->ev_flags & (EVLIST_ACTIVE|EVLIST_ACTIVE_LATER))) {
    case EVLIST_ACTIVE:
        ev->ev_res |= res;  // 合并事件类型
        return;
    // ...
    }

    /* 
     * 对于信号事件：
     * - 设置 ev_ncalls = 触发次数
     * - 如果当前正在执行该事件的回调（多线程场景），等待完成
     */
    if (ev->ev_events & EV_SIGNAL) {
#ifndef EVENT__DISABLE_THREAD_SUPPORT
        if (base->current_event == event_to_event_callback(ev) &&
            !EVBASE_IN_THREAD(base)) {
            ++base->current_event_waiters;
            EVTHREAD_COND_WAIT(base->current_event_cond, base->th_base_lock);
        }
#endif
        ev->ev_ncalls = ncalls;
        ev->ev_pncalls = NULL;
    }

    /* 将事件回调加入活跃队列 */
    event_callback_activate_nolock_(base, event_to_event_callback(ev));
}
```

---

## 七、执行用户回调

### 7.1 event_process_active_single_queue

```c
// event.c:1691
static int event_process_active_single_queue(struct event_base *base,
    struct evcallback_list *activeq, int max_to_process, const struct timeval *endtime)
{
    struct event_callback *evcb;
    int count = 0;

    for (evcb = TAILQ_FIRST(activeq); evcb; evcb = TAILQ_FIRST(activeq)) {
        struct event *ev = NULL;
        
        if (evcb->evcb_flags & EVLIST_INIT) {
            ev = event_callback_to_event(evcb);
            
            /* 
             * 从活跃队列移除：
             * - 持久事件（EV_PERSIST）：简单移除，保留在已插入队列
             * - 非持久事件：完全删除
             */
            if (ev->ev_events & EV_PERSIST || ev->ev_flags & EVLIST_FINALIZING)
                event_queue_remove_active(base, evcb);
            else
                event_del_nolock_(ev, EVENT_DEL_NOBLOCK);
        } else {
            event_queue_remove_active(base, evcb);
        }

        base->current_event = evcb;
#ifndef EVENT__DISABLE_THREAD_SUPPORT
        base->current_event_waiters = 0;
#endif

        /* 根据 closure 类型分发处理 */
        switch (evcb->evcb_closure) {
        case EV_CLOSURE_EVENT_SIGNAL:
            EVUTIL_ASSERT(ev != NULL);
            event_signal_closure(base, ev);  // 信号事件走这里
            break;
            
        case EV_CLOSURE_EVENT_PERSIST:
            EVUTIL_ASSERT(ev != NULL);
            event_persist_closure(base, ev);
            break;
            
        case EV_CLOSURE_EVENT: {
            void (*evcb_callback)(evutil_socket_t, short, void *);
            short res;
            EVUTIL_ASSERT(ev != NULL);
            evcb_callback = *ev->ev_callback;
            res = ev->ev_res;
            EVBASE_RELEASE_LOCK(base, th_base_lock);
            evcb_callback(ev->ev_fd, res, ev->ev_arg);
            break;
        }
        // ... 其他 closure 类型
        }
        
        base->current_event = NULL;
    }
    
    return count;
}
```

### 7.2 event_signal_closure 信号事件闭包

```c
// event.c:1392
static inline void event_signal_closure(struct event_base *base, struct event *ev)
{
    short ncalls;
    int should_break;

    /* 
     * 获取需要执行的次数：
     * - ev_ncalls 是信号触发的次数
     * - 如果有 3 次 SIGINT，就调用 3 次回调
     */
    ncalls = ev->ev_ncalls;
    
    /*
     * ev_pncalls 指向栈变量 ncalls：
     * - 这样 event_del() 可以在回调执行期间修改 ncalls 为 0
     * - 实现"在回调中删除事件"的功能
     */
    if (ncalls != 0)
        ev->ev_pncalls = &ncalls;

    /* 
     * 释放锁！
     * 这是关键：用户回调可能很长，甚至调用其他 libevent API
     * 如果在持有锁的情况下调用，会导致死锁
     */
    EVBASE_RELEASE_LOCK(base, th_base_lock);

    /* 循环调用用户回调 */
    while (ncalls) {
        ncalls--;
        ev->ev_ncalls = ncalls;
        if (ncalls == 0)
            ev->ev_pncalls = NULL;

        /* 调用用户注册的回调函数 */
        (*ev->ev_callback)(ev->ev_fd, ev->ev_res, ev->ev_arg);

        /* 检查是否需要退出事件循环 */
        EVBASE_ACQUIRE_LOCK(base, th_base_lock);
        should_break = base->event_break;
        EVBASE_RELEASE_LOCK(base, th_base_lock);

        if (should_break) {
            if (ncalls != 0)
                ev->ev_pncalls = NULL;
            return;
        }
    }
}
```

**关键设计要点**：

1. **ncalls 循环**：信号可能触发多次，需要执行相应次数的回调
2. **ev_pncalls**：允许 `event_del()` 在回调执行期间终止循环
3. **锁管理**：
   - 回调执行前释放 `th_base_lock`
   - 避免死锁（用户回调可能调用 `event_add/del`）
   - 检查 `event_break` 时短暂获取锁

---

## 八、完整调用链

### 8.1 注册阶段

```
用户代码
    |
    v
evsignal_new(base, SIGINT, my_callback, arg)
    |
    +-- event_assign()
    |       ev->ev_fd = SIGINT
    |       ev->ev_events = EV_SIGNAL | EV_PERSIST
    |       ev->ev_closure = EV_CLOSURE_EVENT_SIGNAL
    |
    v
evsignal_add(ev, tv)
    |
    +-- event_add()
    |       |
    |       v
    |   event_add_nolock_()
    |       |
    |       +-- evmap_signal_add_(base, SIGINT, ev)
    |               |
    |               +-- GET_SIGNAL_SLOT_AND_CTOR() // 获取 sigmap[SIGINT]
    |               |
    |               +-- if (LIST_EMPTY(&ctx->events))
    |               |       |
    |               |       v
    |               |   evsel->add() // 即 evsig_add()
    |               |       |
    |               |       +-- evsig_set_handler_(base, SIGINT, evsig_handler)
    |               |       |       sigaction(SIGINT, &sa, sh_old[SIGINT])
    |               |       |
    |               |       +-- event_add_nolock_(&sig->ev_signal)
    |               |               添加 socketpair[0] 读事件到事件循环
    |               |
    |               +-- LIST_INSERT_HEAD(&ctx->events, ev)
    |                       将事件插入 sigmap[SIGINT] 链表
    |
    v
event_queue_insert_inserted(base, ev)
        将事件标记为已插入
```

### 8.2 触发阶段

```
系统调用 kill(pid, SIGINT) 或其他信号来源
    |
    v
内核中断当前进程
    |
    v
evsig_handler(SIGINT)          // 异步信号上下文
    |
    +-- if (evsig_base == NULL) return
    |
    +-- write(evsig_base_fd, &SIGINT, 1)
    |       向 socketpair[1] 写 1 字节（信号编号）
    |
    +-- return  // 信号处理函数结束
    |
    v
内核恢复被中断的代码执行
    |
    v
[被中断的代码继续执行...]
    |
    v
event_base_loop() 继续执行
    |
    +-- dispatch()  // epoll_wait/kqueue/select
    |       |
    |       v
    |   检测到 ev_signal_pair[0] 可读
    |       |
    |       v
    |   evsig_cb(fd=ev_signal_pair[0], EV_READ, base)
    |       |
    |       +-- read(fd, signals, sizeof(signals))
    |       |       批量读取信号通知字节
    |       |
    |       +-- for (i = 0; i < n; i++)
    |       |       ncaught[signals[i]]++
    |       |
    |       +-- for (sig = 0; sig < NSIG; sig++)
    |       |       if (ncaught[sig])
    |       |           evmap_signal_active_(base, sig, ncaught[sig])
    |       |
    |       v
    |   evmap_signal_active_(base, SIGINT, ncalls)
    |       |
    |       +-- LIST_FOREACH(ev, &sigmap[SIGINT]->events, ev_signal_next)
    |       |       event_active_nolock_(ev, EV_SIGNAL, ncalls)
    |       |
    |       v
    |   event_active_nolock_(ev, EV_SIGNAL, ncalls)
    |       ev->ev_ncalls = ncalls
    |       event_callback_activate_nolock_(base, callback)
    |           将回调加入 base->activequeues[pri]
    |
    v
event_process_active(base)
    |
    +-- event_process_active_single_queue()
    |       |
    |       v
    |   case EV_CLOSURE_EVENT_SIGNAL:
    |       event_signal_closure(base, ev)
    |           |
    |           +-- ncalls = ev->ev_ncalls
    |           +-- ev->ev_pncalls = &ncalls
    |           +-- EVBASE_RELEASE_LOCK(base, th_base_lock)
    |           |
    |           +-- while (ncalls--)
    |           |       ev->ev_ncalls = ncalls
    |           |       (*ev->ev_callback)(SIGINT, EV_SIGNAL, arg)
    |           |       // 即 my_callback(SIGINT, EV_SIGNAL, arg)
    |           |
    |           +-- return
    |
    v
event_base_loop() 继续下一轮循环
```

### 8.3 删除阶段

```
用户代码
    |
    v
evsignal_del(ev)
    |
    +-- event_del()
    |       |
    |       v
    |   event_del_nolock_()
    |       |
    |       +-- evmap_signal_del_(base, SIGINT, ev)
    |       |       |
    |       |       +-- LIST_REMOVE(ev, ev_signal_next)
    |       |       |
    |       |       +-- if (LIST_FIRST(&ctx->events) == NULL)
    |       |               evsel->del() // 即 evsig_del()
    |       |
    |       v
    |   evsig_del()
    |       |
    |       +-- evsig_restore_handler_(base, SIGINT)
    |       |       sigaction(SIGINT, sh_old[SIGINT], NULL)
    |       |       恢复旧的信号处理函数
    |       |
    |       +-- 更新 evsig_base_n_signals_added
    |
    v
event_queue_remove_inserted(base, ev)
```

---

## 九、重要注意事项

### 9.1 单 event_base 限制

**问题**：`evsig_base` 是全局变量，同一时刻只有一个 `event_base` 能接收信号。

```c
// signal.c:111
static struct event_base *evsig_base = NULL;
static int evsig_base_n_signals_added = 0;
static evutil_socket_t evsig_base_fd = -1;
```

**影响**：
- 如果向 event_base A 添加 SIGINT，再向 event_base B 添加 SIGTERM
- event_base B 会收到所有信号，event_base A 收不到
- 最后调用 `event_base_loop()` 的 event_base 获得信号处理权

**建议**：
- 一个进程中只使用一个 event_base 处理信号
- 或者使用 `signalfd`（Linux）等更高级的信号处理机制

### 9.2 信号事件默认持久

```c
#define evsignal_new(b, x, cb, arg) \
    event_new((b), (x), EV_SIGNAL|EV_PERSIST, (cb), (arg))
```

- `evsignal_new()` 自动包含 `EV_PERSIST`
- 信号事件默认是持久的，不需要重复添加
- 需要手动调用 `evsignal_del()` 删除

### 9.3 回调中的锁管理

```c
static inline void event_signal_closure(struct event_base *base, struct event *ev)
{
    // ...
    EVBASE_RELEASE_LOCK(base, th_base_lock);  // 释放锁！
    
    while (ncalls) {
        (*ev->ev_callback)(ev->ev_fd, ev->ev_res, ev->ev_arg);
        // 用户回调执行期间不持有锁
        
        EVBASE_ACQUIRE_LOCK(base, th_base_lock);
        should_break = base->event_break;
        EVBASE_RELEASE_LOCK(base, th_base_lock);
    }
}
```

**原因**：
- 用户回调可能调用 `event_add()`、`event_del()` 等 API
- 这些 API 需要获取 `th_base_lock`
- 如果在回调中持有锁，会导致死锁

### 9.4 信号合并与丢失

**场景**：
- 短时间内多次触发同一信号（如快速按 Ctrl+C）
- socketpair 缓冲区满（通常是 64KB）

**行为**：
- 信号编号被写入 socketpair，多次触发会合并
- `evsig_cb()` 统计每个信号触发的次数（`ncaught[sig]`）
- 回调被执行相应次数
- 如果缓冲区满，新的信号通知可能丢失（极少发生）

### 9.5 跨平台差异

| 特性 | Unix/Linux | Windows |
|------|-----------|---------|
| socketpair | `pipe()` 或 `socketpair()` | `socketpair()` |
| 信号处理 | `sigaction()` | `signal()` |
| 写操作 | `write()` | `send()` |
| 读操作 | `read()` | `recv()` |
| 信号编号类型 | `ev_uint8_t` | `ev_uint8_t` |

### 9.6 与 I/O 事件的互斥

```c
event_assign(struct event *ev, struct event_base *base, evutil_socket_t fd,
    short events, void (*callback)(...), void *arg)
{
    if (events & EV_SIGNAL) {
        // 信号事件不能与 READ/WRITE/CLOSED 同时设置
        ev->ev_closure = EV_CLOSURE_EVENT_SIGNAL;
    }
}
```

- `EV_SIGNAL` 不能与 `EV_READ`、`EV_WRITE`、`EV_CLOSED` 同时设置
- 信号事件和 I/O 事件是完全独立的

### 9.7 内部事件优先级

```c
evsig_init_(struct event_base *base)
{
    // ...
    event_priority_set(&base->sig.ev_signal, 0);  // 最高优先级
}
```

- 内部 `ev_signal` 事件优先级设为 0（最高）
- 确保信号事件优先于普通 I/O 事件处理
- 用户事件的默认优先级通常是中间值

### 9.8 线程安全

```c
#ifndef EVENT__DISABLE_THREAD_SUPPORT
static void *evsig_base_lock = NULL;
#endif

#define EVSIGBASE_LOCK() EVLOCK_LOCK(evsig_base_lock, 0)
#define EVSIGBASE_UNLOCK() EVLOCK_UNLOCK(evsig_base_lock, 0)
```

- `evsig_base`、`evsig_base_n_signals_added`、`evsig_base_fd` 受锁保护
- 多线程环境下修改这些全局变量时需要加锁
- 信号处理函数中不获取锁（避免死锁），只使用原子操作或简单赋值

---

## 十、总结

Libevent 的信号处理机制是一个经典的**"异步转同步"**设计：

1. **注册阶段**：使用 `sigaction()` 注册信号处理函数，同时创建 socketpair 监听信号
2. **触发阶段**：信号发生时，处理函数向 socketpair 写入信号编号
3. **处理阶段**：事件循环检测到 socketpair 可读，批量读取信号并激活对应事件
4. **回调阶段**：在主线程中同步调用用户回调，支持多次触发合并和删除中断

这种设计的优势：
- **安全性**：信号处理函数只做异步信号安全的操作
- **灵活性**：支持多信号监听、多次触发合并、回调中删除
- **兼容性**：适用于所有支持 socketpair 和信号的平台

局限性：
- 单 event_base 限制
- socketpair 缓冲区可能满（极少发生）
- 相比 signalfd（Linux）或 kqueue EVFILT_SIGNAL（BSD）效率略低
