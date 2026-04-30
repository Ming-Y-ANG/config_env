# Libevent IO FD 详细工作流程

## 目录

- [一、架构概览](#一架构概览)
- [二、核心数据结构](#二核心数据结构)
- [三、初始化阶段](#三初始化阶段)
- [四、注册 IO 事件](#四注册-io-事件)
- [五、事件分派（Dispatch）](#五事件分派dispatch)
- [六、事件激活](#六事件激活)
- [七、回调执行](#七回调执行)
- [八、删除 IO 事件](#八删除-io-事件)
- [九、完整调用链总结](#九完整调用链总结)
- [十、关键设计要点](#十关键设计要点)

---

## 一、架构概览

Libevent 的 IO 事件处理采用**分层架构**：

```
用户层 API
    ├── event_new / event_add / event_del
    └── 操作 struct event 对象

事件管理层 (event.c)
    ├── event_add_nolock_ / event_del_nolock_
    ├── 管理事件状态（插入、活跃、超时队列）
    └── 调用 evmap 进行 fd 映射管理

事件映射层 (evmap.c)
    ├── evmap_io_add_ / evmap_io_del_ / evmap_io_active_
    ├── 维护 fd -> event 链表映射
    └── 计算读写计数，决定是否需要通知后端

后端层 (epoll.c / kqueue.c / select.c)
    ├── add / del / dispatch
    └── 实际调用 epoll_ctl / kevent / select
```

---

## 二、核心数据结构

### 2.1 struct event（事件对象）

```c
struct event {
    struct event_callback ev_evcallback;
    evutil_socket_t ev_fd;        // 监听的 fd
    short ev_events;              // 事件类型：EV_READ | EV_WRITE | EV_CLOSED | EV_PERSIST
    short ev_res;                 // 触发结果（回调时告知哪些事件就绪）
    int ev_flags;                 // 状态标志：EVLIST_INIT | EVLIST_INSERTED | EVLIST_ACTIVE
    
    // IO 事件链表指针
    LIST_ENTRY(event) ev_io_next;
    
    // 超时相关
    struct timeval ev_timeout;
    union {
        struct { struct timeval ev_timeout; } ev_io;
        struct { int ev_ncalls; int *ev_pncalls; } ev_signal;
    } ev_;
};
```

### 2.2 struct evmap_io（单个 fd 的事件聚合）

```c
struct evmap_io {
    struct event_dlist events;    // 监听该 fd 的所有 event 链表
    ev_uint16_t nread;            // 监听 EV_READ 的 event 数量
    ev_uint16_t nwrite;           // 监听 EV_WRITE 的 event 数量
    ev_uint16_t nclose;           // 监听 EV_CLOSED 的 event 数量
};
```

### 2.3 struct event_io_map（fd 映射表）

```c
#ifdef _WIN32
// Windows 上 fd 不连续，使用哈希表
HT_HEAD(event_io_map, event_map_entry);
#else
// Unix 上 fd 通常是连续整数，使用数组
struct event_signal_map {
    void **entries;    // 索引 = fd，值 = evmap_io*
    int nentries;
};
#define event_io_map event_signal_map
#endif
```

### 2.4 struct eventop（后端操作表）

```c
struct eventop {
    const char *name;
    void *(*init)(struct event_base *);
    int (*add)(struct event_base *, evutil_socket_t fd, short old, short events, void *fdinfo);
    int (*del)(struct event_base *, evutil_socket_t fd, short old, short events, void *fdinfo);
    int (*dispatch)(struct event_base *, struct timeval *);
    void (*dealloc)(struct event_base *);
    int need_reinit;
    enum event_method_feature features;
    size_t fdinfo_len;    // 每个 fd 需要额外分配的后端私有数据大小
};
```

**以 epoll 为例**：
```c
const struct eventop epollops = {
    "epoll",
    epoll_init,              // 创建 epoll fd
    epoll_nochangelist_add,  // epoll_ctl ADD/MOD
    epoll_nochangelist_del,  // epoll_ctl DEL
    epoll_dispatch,          // epoll_wait
    epoll_dealloc,
    1,                       // need_reinit（fork 后需要重新初始化）
    EV_FEATURE_ET|EV_FEATURE_O1|EV_FEATURE_EARLY_CLOSE,
    0                        // fdinfo_len = 0，epoll 不需要额外 fd 数据
};
```

---

## 三、初始化阶段

### 3.1 event_base 创建

```c
struct event_base *event_base_new(void)
    └── event_base_new_with_config(config)
            ├── 选择最佳后端（evsel）
            │       优先级：epoll > kqueue > devpoll > evport > poll > select
            │       └── base->evsel = &epollops
            ├── 初始化 IO 映射表
            │       └── evmap_io_initmap_(&base->io)
            ├── 初始化信号映射表
            │       └── evmap_signal_initmap_(&base->sigmap)
            ├── 初始化超时 min-heap
            │       └── min_heap_ctor_(&base->timeheap)
            ├── 创建后端私有数据
            │       └── base->evbase = base->evsel->init(base)
            │               └── epoll_init(base)
            │                       ├── epfd = epoll_create1(EPOLL_CLOEXEC)
            │                       ├── 初始化 events 数组
            │                       └── sigfd_init_() 或 evsig_init_()
            └── 初始化活跃事件队列（activequeues）
```

### 3.2 epoll_init 详解

```c
static void *epoll_init(struct event_base *base)
{
    epoll_handle epfd = epoll_create1(EPOLL_CLOEXEC);
    
    struct epollop *epollop = mm_calloc(1, sizeof(struct epollop));
    epollop->epfd = epfd;
    epollop->events = mm_calloc(INITIAL_NEVENT, sizeof(struct epoll_event));
    epollop->nevents = INITIAL_NEVENT;
    
    // 根据环境变量或标志选择是否使用 changelist 优化
    if (EVENT_EPOLL_USE_CHANGELIST)
        base->evsel = &epollops_changelist;
    
    // 初始化信号处理（signalfd 或 socketpair）
    if (sigfd_init_(base) < 0)
        evsig_init_(base);
    
    return epollop;
}
```

**关键设计**：
- `epollop` 是 epoll 后端私有数据，挂在 `base->evbase` 上
- `events` 数组用于接收 `epoll_wait` 返回的就绪事件
- `nevents` 初始为 32，满时自动翻倍（直到 MAX_NEVENT=4096）
- **changelist 优化**：批量收集 fd 变化，在 `dispatch` 前一次性应用，减少 epoll_ctl 调用次数

---

## 四、注册 IO 事件

### 4.1 用户层 API

```c
struct event *ev = event_new(base, fd, EV_READ|EV_PERSIST, callback, arg);
event_add(ev, NULL);   // 无限期监听
// 或
event_add(ev, &tv);    // 带超时
```

### 4.2 event_assign 初始化事件

```c
int event_assign(struct event *ev, struct event_base *base, evutil_socket_t fd,
    short events, void (*callback)(evutil_socket_t, short, void *), void *arg)
{
    ev->ev_base = base;
    ev->ev_callback = callback;
    ev->ev_arg = arg;
    ev->ev_fd = fd;
    ev->ev_events = events;
    ev->ev_res = 0;
    ev->ev_flags = EVLIST_INIT;    // 标记为已初始化
    
    if (events & EV_PERSIST) {
        ev->ev_closure = EV_CLOSURE_EVENT_PERSIST;
    } else {
        ev->ev_closure = EV_CLOSURE_EVENT;
    }
    
    min_heap_elem_init_(ev);       // 初始化 minheap 索引为无效值
    ev->ev_pri = base->nactivequeues / 2;  // 默认中间优先级
    
    return 0;
}
```

### 4.3 event_add_nolock_ 核心逻辑

```c
int event_add_nolock_(struct event *ev, const struct timeval *tv, int tv_is_absolute)
{
    struct event_base *base = ev->ev_base;
    int res = 0, notify = 0;
    
    // 步骤 1：将事件添加到 evmap（如果尚未添加）
    if ((ev->ev_events & (EV_READ|EV_WRITE|EV_CLOSED|EV_SIGNAL)) &&
        !(ev->ev_flags & (EVLIST_INSERTED|EVLIST_ACTIVE|EVLIST_ACTIVE_LATER))) {
        
        if (ev->ev_events & (EV_READ|EV_WRITE|EV_CLOSED))
            res = evmap_io_add_(base, ev->ev_fd, ev);
        else if (ev->ev_events & EV_SIGNAL)
            res = evmap_signal_add_(base, (int)ev->ev_fd, ev);
        
        if (res != -1)
            event_queue_insert_inserted(base, ev);  // 标记为已插入
        if (res == 1)
            notify = 1;  // 需要唤醒事件循环线程
    }
    
    // 步骤 2：处理超时（如果有）
    if (res != -1 && tv != NULL) {
        // ... 超时处理逻辑（见 common timeout 文档）
    }
    
    // 如果需要，唤醒正在等待的事件循环线程
    if (res != -1 && notify && EVBASE_NEED_NOTIFY(base))
        evthread_notify_base(base);
    
    return res;
}
```

### 4.4 evmap_io_add_ 映射层核心

```c
int evmap_io_add_(struct event_base *base, evutil_socket_t fd, struct event *ev)
{
    const struct eventop *evsel = base->evsel;
    struct event_io_map *io = &base->io;
    struct evmap_io *ctx = NULL;
    int nread, nwrite, nclose, retval = 0;
    short res = 0, old = 0;
    
    // 确保数组/哈希表中有该 fd 的槽位
    GET_IO_SLOT_AND_CTOR(ctx, io, fd, evmap_io, evmap_io_init, evsel->fdinfo_len);
    
    nread = ctx->nread;
    nwrite = ctx->nwrite;
    nclose = ctx->nclose;
    
    // 计算当前已注册的事件类型
    if (nread)  old |= EV_READ;
    if (nwrite) old |= EV_WRITE;
    if (nclose) old |= EV_CLOSED;
    
    // 判断新 event 是否会引入新的事件类型
    if (ev->ev_events & EV_READ) {
        if (++nread == 1)      // 从 0 变成 1，首次注册 READ
            res |= EV_READ;
    }
    if (ev->ev_events & EV_WRITE) {
        if (++nwrite == 1)     // 从 0 变成 1，首次注册 WRITE
            res |= EV_WRITE;
    }
    if (ev->ev_events & EV_CLOSED) {
        if (++nclose == 1)     // 从 0 变成 1，首次注册 CLOSED
            res |= EV_CLOSED;
    }
    
    // 安全检查：不能混合边缘触发和水平触发
    if ((old_ev = LIST_FIRST(&ctx->events)) &&
        (old_ev->ev_events & EV_ET) != (ev->ev_events & EV_ET)) {
        event_warnx("Tried to mix edge-triggered and non-edge-triggered");
        return -1;
    }
    
    // 【关键】如果有新的事件类型，通知后端注册
    if (res) {
        void *extra = ((char*)ctx) + sizeof(struct evmap_io);
        if (evsel->add(base, ev->ev_fd, old, (ev->ev_events & EV_ET) | res, extra) == -1)
            return (-1);
        retval = 1;  // 通知调用者：后端已更新，可能需要唤醒 dispatch
    }
    
    // 更新计数并插入链表
    ctx->nread = nread;
    ctx->nwrite = nwrite;
    ctx->nclose = nclose;
    LIST_INSERT_HEAD(&ctx->events, ev, ev_io_next);
    
    return retval;
}
```

**核心逻辑说明**：

1. **惰性注册**：只有该 fd **首次**监听某种事件（如 READ）时，才调用后端 `add`
2. **事件聚合**：同一 fd 可以有多个 event，每个监听不同/相同的事件
3. **ET/LT 不可混用**：同一 fd 上所有 event 要么全是 ET，要么全是 LT
4. **`res` 的含义**：返回 1 表示后端被更新，event_add 需要唤醒正在 `dispatch` 的线程

### 4.5 后端 add（epoll_nochangelist_add）

```c
static int epoll_nochangelist_add(struct event_base *base, evutil_socket_t fd,
    short old, short events, void *p)
{
    struct event_change ch;
    ch.fd = fd;
    ch.old_events = old;
    ch.read_change = ch.write_change = ch.close_change = 0;
    
    if (events & EV_WRITE)
        ch.write_change = EV_CHANGE_ADD | (events & EV_ET);
    if (events & EV_READ)
        ch.read_change = EV_CHANGE_ADD | (events & EV_ET);
    if (events & EV_CLOSED)
        ch.close_change = EV_CHANGE_ADD | (events & EV_ET);
    
    return epoll_apply_one_change(base, base->evbase, &ch);
}
```

```c
static int epoll_apply_one_change(struct event_base *base, struct epollop *epollop,
    const struct event_change *ch)
{
    struct epoll_event epev;
    int op, events = 0;
    
    // 通过查表确定 op（ADD/DEL/MOD）和 events（EPOLLIN/EPOLLOUT/EPOLLRDHUP）
    idx = EPOLL_OP_TABLE_INDEX(ch);
    op = epoll_op_table[idx].op;
    events = epoll_op_table[idx].events;
    
    if (events & EV_CHANGE_ET)
        events |= EPOLLET;   // 边缘触发
    
    epev.data.fd = ch->fd;
    epev.events = events;
    
    if (epoll_ctl(epollop->epfd, op, ch->fd, &epev) == 0)
        return 0;
    
    // 错误处理：MOD 失败可能是 fd 关闭重开，重试 ADD
    // ADD 失败 EEXIST 可能是 dup 导致的，重试 MOD
    // DEL 失败 ENOENT/EBADF 可以忽略（fd 已关闭）
}
```

---

## 五、事件分派（Dispatch）

### 5.1 event_base_loop 主循环

```c
int event_base_loop(struct event_base *base, int flags)
{
    while (!done) {
        // 1. 计算下一次超时时间
        tv_p = &tv;
        if (!N_ACTIVE_CALLBACKS(base) && !(flags & EVLOOP_NONBLOCK))
            timeout_next(base, &tv_p);  // 从 minheap 获取最早超时时间
        else
            evutil_timerclear(&tv);      // 有活跃事件，非阻塞 poll
        
        // 2. 调用 prepare watchers
        // ...
        
        // 3. 核心：调用后端 dispatch 等待事件
        res = evsel->dispatch(base, tv_p);
        
        // 4. 调用 check watchers
        // ...
        
        // 5. 处理超时事件
        timeout_process(base);
        
        // 6. 处理活跃事件（回调）
        if (N_ACTIVE_CALLBACKS(base))
            event_process_active(base);
    }
}
```

### 5.2 epoll_dispatch 详解

```c
static int epoll_dispatch(struct event_base *base, struct timeval *tv)
{
    struct epollop *epollop = base->evbase;
    struct epoll_event *events = epollop->events;
    int i, res;
    
    // 计算超时参数
#if defined(EVENT__HAVE_EPOLL_PWAIT2)
    struct timespec ts;
    TIMEVAL_TO_TIMESPEC(tv, &ts);
#else
    long timeout = evutil_tv_to_msec_(tv);
    if (timeout > MAX_EPOLL_TIMEOUT_MSEC)
        timeout = MAX_EPOLL_TIMEOUT_MSEC;  // Linux 内核限制
#endif
    
    // 【changelist 优化】批量应用之前收集的 fd 变更
    epoll_apply_changes(base);
    event_changelist_remove_all_(&base->changelist, base);
    
    // 释放锁，避免在 epoll_wait 阻塞时持有全局锁
    EVBASE_RELEASE_LOCK(base, th_base_lock);
    
    // 等待内核事件
#if defined(EVENT__HAVE_EPOLL_PWAIT2)
    res = epoll_pwait2(epollop->epfd, events, epollop->nevents, tv ? &ts : NULL, NULL);
#else
    res = epoll_wait(epollop->epfd, events, epollop->nevents, timeout);
#endif
    
    // 重新获取锁
    EVBASE_ACQUIRE_LOCK(base, th_base_lock);
    
    if (res == -1) {
        if (errno != EINTR) return -1;
        return 0;
    }
    
    // 处理返回的就绪事件
    for (i = 0; i < res; i++) {
        int what = events[i].events;
        short ev = 0;
        
        // 跳过 timerfd（用于精确计时）
        if (events[i].data.fd == epollop->timerfd) continue;
        
        // 将 epoll 事件转换为 libevent 事件标志
        if (what & EPOLLERR) {
            ev = EV_READ | EV_WRITE;     // 错误时同时报告读写
        } else if ((what & EPOLLHUP) && !(what & EPOLLRDHUP)) {
            ev = EV_READ | EV_WRITE;     // HUP 但无 RDHUP
        } else {
            if (what & EPOLLIN)   ev |= EV_READ;
            if (what & EPOLLOUT)  ev |= EV_WRITE;
            if (what & EPOLLRDHUP) ev |= EV_CLOSED;
        }
        
        if (!ev) continue;
        
        // 【关键】激活该 fd 上所有匹配的 event
        evmap_io_active_(base, events[i].data.fd, ev | EV_ET);
    }
    
    // 如果事件数组用完，扩容一倍（指数增长）
    if (res == epollop->nevents && epollop->nevents < MAX_NEVENT) {
        int new_nevents = epollop->nevents * 2;
        epollop->events = mm_realloc(...);
        epollop->nevents = new_nevents;
    }
    
    return 0;
}
```

**关键设计**：
1. **锁的释放与重新获取**：`epoll_wait` 阻塞期间不持有 `th_base_lock`，允许其他线程 `event_add`
2. **changelist 批量应用**：在 `epoll_wait` 前一次性应用所有 `epoll_ctl` 变更，减少系统调用
3. **事件数组动态扩容**：初始 32，满时翻倍，上限 4096
4. **EPOLLERR/EPOLLHUP 处理**：错误时同时报告 EV_READ | EV_WRITE，让用户处理

---

## 六、事件激活

### 6.1 evmap_io_active_

```c
void evmap_io_active_(struct event_base *base, evutil_socket_t fd, short events)
{
    struct event_io_map *io = &base->io;
    struct evmap_io *ctx;
    struct event *ev;
    
    GET_IO_SLOT(ctx, io, fd, evmap_io);
    if (NULL == ctx) return;
    
    // 遍历该 fd 上所有已注册的 event
    LIST_FOREACH(ev, &ctx->events, ev_io_next) {
        // 检查 event 关注的事件是否和就绪事件有交集
        if (ev->ev_events & (events & ~EV_ET))
            event_active_nolock_(ev, ev->ev_events & events, 1);
    }
}
```

**说明**：
- 同一 fd 可能有多个 event（如一个读 event、一个写 event）
- 每个 event 只被激活**一次**（`ncalls = 1`），即使多个事件同时就绪
- `events & ~EV_ET` 去除边缘触发标志，因为 ET 只是通知方式，不影响事件匹配

### 6.2 event_active_nolock_

```c
void event_active_nolock_(struct event *ev, int res, short ncalls)
{
    struct event_base *base = ev->ev_base;
    
    // 如果已经在活跃队列中，合并结果
    if (ev->ev_flags & EVLIST_ACTIVE) {
        ev->ev_res |= res;   // 合并事件类型
        return;
    }
    
    // 设置结果和触发次数
    ev->ev_res = res;
    ev->ev_ncalls = ncalls;
    ev->ev_pncalls = NULL;
    
    // 如果新事件的优先级高于当前正在处理的优先级，设置继续标志
    if (ev->ev_pri < base->event_running_priority)
        base->event_continue = 1;
    
    // 加入活跃队列
    event_callback_activate_nolock_(base, event_to_event_callback(ev));
}
```

**活跃队列结构**：
```c
struct event_base {
    struct evcallback_list *activequeues;  // 按优先级分配的队列数组
    int nactivequeues;                      // 优先级数量（默认 1）
};
```

---

## 七、回调执行

### 7.1 event_process_active

```c
static int event_process_active(struct event_base *base)
{
    struct evcallback_list *activeq = NULL;
    int i, c = 0;
    
    // 计算最大处理时间（如果有配置）
    if (base->max_dispatch_time.tv_sec >= 0) {
        gettime(base, &tv);
        evutil_timeradd(&base->max_dispatch_time, &tv, &tv);
        endtime = &tv;
    }
    
    // 按优先级从高到低（数值从小到大）处理
    for (i = 0; i < base->nactivequeues; ++i) {
        if (TAILQ_FIRST(&base->activequeues[i]) != NULL) {
            base->event_running_priority = i;
            activeq = &base->activequeues[i];
            
            // 高优先级队列无限制，低优先级队列限制回调数量
            if (i < limit_after_prio)
                c = event_process_active_single_queue(base, activeq, INT_MAX, NULL);
            else
                c = event_process_active_single_queue(base, activeq, maxcb, endtime);
            
            if (c > 0) break;  // 处理了一个真实事件，不继续低优先级
        }
    }
    
    base->event_running_priority = -1;
    return c;
}
```

**优先级策略**：
- 低数值 = 高优先级（0 是最高优先级）
- 高优先级队列处理完所有事件后，才处理低优先级
- 如果高优先级队列处理了一个**非内部事件**，立即停止（防止低优先级饥饿）

### 7.2 event_process_active_single_queue

```c
static int event_process_active_single_queue(struct event_base *base,
    struct evcallback_list *activeq, int max_to_process, const struct timeval *endtime)
{
    for (evcb = TAILQ_FIRST(activeq); evcb; evcb = TAILQ_FIRST(activeq)) {
        struct event *ev = NULL;
        
        if (evcb->evcb_flags & EVLIST_INIT) {
            ev = event_callback_to_event(evcb);
            
            // 从活跃队列移除
            if (ev->ev_events & EV_PERSIST || ev->ev_flags & EVLIST_FINALIZING)
                event_queue_remove_active(base, evcb);
            else
                event_del_nolock_(ev, EVENT_DEL_NOBLOCK);  // 非持久事件：自动删除
        } else {
            event_queue_remove_active(base, evcb);
        }
        
        base->current_event = evcb;
        
        // 根据 closure 类型分发
        switch (evcb->evcb_closure) {
        case EV_CLOSURE_EVENT_SIGNAL:
            event_signal_closure(base, ev);
            break;
            
        case EV_CLOSURE_EVENT_PERSIST:
            event_persist_closure(base, ev);
            break;
            
        case EV_CLOSURE_EVENT: {
            void (*evcb_callback)(evutil_socket_t, short, void *);
            short res;
            evcb_callback = *ev->ev_callback;
            res = ev->ev_res;
            EVBASE_RELEASE_LOCK(base, th_base_lock);  // 释放锁！
            evcb_callback(ev->ev_fd, res, ev->ev_arg);
            break;
        }
        // ...
        }
        
        base->current_event = NULL;
    }
}
```

### 7.3 普通 IO 事件回调（EV_CLOSURE_EVENT）

```c
case EV_CLOSURE_EVENT: {
    // 从 event 中提取回调和结果
    void (*cb)(evutil_socket_t, short, void *) = ev->ev_callback;
    short res = ev->ev_res;        // EV_READ | EV_WRITE 等
    evutil_socket_t fd = ev->ev_fd;
    void *arg = ev->ev_arg;
    
    // 释放锁后调用用户回调
    EVBASE_RELEASE_LOCK(base, th_base_lock);
    cb(fd, res, arg);
    // 注意：回调返回后，锁未重新获取！
    // 下一段代码在 for 循环开头会处理
}
```

**为什么释放锁？**
- 用户回调可能调用 `event_add()` / `event_del()` / `event_base_loopbreak()`
- 这些 API 需要获取 `th_base_lock`
- 如果在回调中持有锁，会导致死锁

### 7.4 持久 IO 事件回调（EV_CLOSURE_EVENT_PERSIST）

```c
static inline void event_persist_closure(struct event_base *base, struct event *ev)
{
    void (*cb)(evutil_socket_t, short, void *) = ev->ev_callback;
    evutil_socket_t fd = ev->ev_fd;
    short res = ev->ev_res;
    void *arg = ev->ev_arg;
    
    // 释放锁调用回调
    EVBASE_RELEASE_LOCK(base, th_base_lock);
    cb(fd, res, arg);
    
    // 如果设置了 io_timeout，重新调度超时
    if (ev->ev_io_timeout.tv_sec || ev->ev_io_timeout.tv_usec) {
        // 计算下一次超时时间
        // 重新添加到超时队列
    }
}
```

**持久事件特点**：
- 回调执行后**不会**自动删除
- 下次 `dispatch` 时仍然监听
- 支持同时设置 IO 事件和超时（`ev_io_timeout`）

---

## 八、删除 IO 事件

### 8.1 用户层 API

```c
event_del(ev);       // 普通删除
event_free(ev);      // 先 event_del，再释放内存
```

### 8.2 event_del_nolock_

```c
int event_del_nolock_(struct event *ev, int blocking)
{
    struct event_base *base = ev->ev_base;
    
    // 如果正在执行回调，且不是当前线程，可能需要等待
    if (blocking && base->current_event == event_to_event_callback(ev))
        // 等待回调完成...
    
    // 从 evmap 中删除
    if (ev->ev_events & (EV_READ|EV_WRITE|EV_CLOSED)) {
        res = evmap_io_del_(base, ev->ev_fd, ev);
    } else if (ev->ev_events & EV_SIGNAL) {
        res = evmap_signal_del_(base, (int)ev->ev_fd, ev);
    }
    
    if (res != -1)
        event_queue_remove_inserted(base, ev);
    
    // 如果有超时，从超时队列删除
    if (ev->ev_flags & EVLIST_TIMEOUT)
        event_queue_remove_timeout(base, ev);
    
    // 如果在活跃队列，移除
    if (ev->ev_flags & EVLIST_ACTIVE)
        event_queue_remove_active(base, event_to_event_callback(ev));
    
    return res;
}
```

### 8.3 evmap_io_del_

```c
int evmap_io_del_(struct event_base *base, evutil_socket_t fd, struct event *ev)
{
    const struct eventop *evsel = base->evsel;
    struct event_io_map *io = &base->io;
    struct evmap_io *ctx;
    int nread, nwrite, nclose, retval = 0;
    short res = 0, old = 0;
    
    GET_IO_SLOT(ctx, io, fd, evmap_io);
    
    nread = ctx->nread;
    nwrite = ctx->nwrite;
    nclose = ctx->nclose;
    
    if (nread)  old |= EV_READ;
    if (nwrite) old |= EV_WRITE;
    if (nclose) old |= EV_CLOSED;
    
    // 递减计数，如果某种事件计数归零，通知后端删除
    if (ev->ev_events & EV_READ) {
        if (--nread == 0) res |= EV_READ;
    }
    if (ev->ev_events & EV_WRITE) {
        if (--nwrite == 0) res |= EV_WRITE;
    }
    if (ev->ev_events & EV_CLOSED) {
        if (--nclose == 0) res |= EV_CLOSED;
    }
    
    if (res) {
        void *extra = ((char*)ctx) + sizeof(struct evmap_io);
        if (evsel->del(base, ev->ev_fd, old, (ev->ev_events & EV_ET) | res, extra) == -1)
            retval = -1;
        else
            retval = 1;
    }
    
    ctx->nread = nread;
    ctx->nwrite = nwrite;
    ctx->nclose = nclose;
    LIST_REMOVE(ev, ev_io_next);
    
    return retval;
}
```

**删除策略**：
- 惰性注销：只有某种事件的**最后一个监听者**被删除时，才调用后端 `del`
- 如果删除后 `evmap_io` 链表为空，不会立即释放内存（下次添加同 fd 可复用）

---

## 九、完整调用链总结

### 9.1 注册阶段

```
用户代码
    │
    ├── event_new(base, fd, EV_READ|EV_PERSIST, cb, arg)
    │       └── event_assign(ev, base, fd, events, cb, arg)
    │               ├── ev->ev_fd = fd
    │               ├── ev->ev_events = EV_READ|EV_PERSIST
    │               ├── ev->ev_closure = EV_CLOSURE_EVENT_PERSIST
    │               └── ev->ev_flags = EVLIST_INIT
    │
    └── event_add(ev, NULL)
            └── event_add_nolock_(ev, NULL, 0)
                    │
                    ├── 检查：未插入，且有 EV_READ/WRITE/CLOSED
                    │
                    ├── evmap_io_add_(base, fd, ev)
                    │       │
                    │       ├── GET_IO_SLOT_AND_CTOR(ctx, io, fd, evmap_io)
                    │       │       └── fd 首次出现：创建 evmap_io 节点
                    │       │
                    │       ├── old = ctx 当前监听的事件类型（READ/WRITE/CLOSED）
                    │       │
                    │       ├── 新 event 监听 EV_READ
                    │       │       └── ++nread == 1（首次注册 READ）
                    │       │           └── res |= EV_READ
                    │       │
                    │       ├── if (res) 后端 add
                    │       │       └── evsel->add(base, fd, old, EV_READ|EV_ET, extra)
                    │       │               └── epoll_nochangelist_add()
                    │       │                       └── epoll_apply_one_change()
                    │       │                               ├── 查表得到 op=ADD, events=EPOLLIN
                    │       │                               └── epoll_ctl(epfd, ADD, fd, &epev)
                    │       │
                    │       ├── ctx->nread = 1
                    │       └── LIST_INSERT_HEAD(&ctx->events, ev)  // 挂入链表
                    │
                    ├── event_queue_insert_inserted(base, ev)
                    │       └── ev->ev_flags |= EVLIST_INSERTED
                    │
                    └── 无 timeout，跳过超时处理
```

### 9.2 触发阶段

```
内核检测到 fd 可读
    │
    └── epoll_wait 返回，events[i] = { fd, EPOLLIN }
            │
            └── epoll_dispatch()
                    │
                    ├── what = EPOLLIN
                    ├── ev = EV_READ（转换 epoll 事件为 libevent 标志）
                    │
                    └── evmap_io_active_(base, fd, ev|EV_ET)
                            │
                            ├── GET_IO_SLOT(ctx, io, fd, evmap_io)
                            │
                            └── LIST_FOREACH(ev, &ctx->events, ev_io_next)
                                    ├── ev1: ev_events = EV_READ|EV_PERSIST
                                    │       ev_events & (events & ~EV_ET) = EV_READ & EV_READ = true
                                    │       └── event_active_nolock_(ev1, EV_READ, 1)
                                    │               ├── ev->ev_res = EV_READ
                                    │               └── event_callback_activate_nolock_()
                                    │                       └── TAILQ_INSERT_TAIL(&base->activequeues[pri], evcb)
                                    │
                                    └── ev2: ev_events = EV_WRITE
                                            ev_events & EV_READ = false
                                            └── 不匹配，跳过
```

### 9.3 回调阶段

```
event_base_loop()
    │
    ├── dispatch() 返回，发现 N_ACTIVE_CALLBACKS > 0
    │
    └── event_process_active(base)
            │
            ├── 遍历 activequeues[0] ~ activequeues[n-1]
            │
            ├── activequeues[0] 非空
            │       └── event_process_active_single_queue(base, activeq, INT_MAX, NULL)
            │               │
            │               ├── evcb = TAILQ_FIRST(activeq)
            │               │
            │               ├── 从队列移除
            │               │       ├── 持久事件：event_queue_remove_active()
            │               │       └── 非持久：event_del_nolock_() // 自动删除
            │               │
            │               ├── base->current_event = evcb
            │               │
            │               ├── switch(EV_CLOSURE_EVENT_PERSIST)
            │               │       └── event_persist_closure(base, ev)
            │               │               ├── cb = ev->ev_callback
            │               │               ├── res = EV_READ
            │               │               ├── EVBASE_RELEASE_LOCK(base, th_base_lock)
            │               │               └── cb(fd, EV_READ, arg)   // 用户回调！
            │               │
            │               └── base->current_event = NULL
            │
            └── c > 0，跳出循环（不处理低优先级）
```

### 9.4 删除阶段

```
用户代码
    │
    └── event_del(ev)
            └── event_del_nolock_(ev, EVENT_DEL_AUTOBLOCK)
                    │
                    ├── evmap_io_del_(base, fd, ev)
                    │       │
                    │       ├── GET_IO_SLOT(ctx, io, fd, evmap_io)
                    │       │
                    │       ├── --nread == 0（该 fd 最后一个 READ 监听者）
                    │       │       └── res |= EV_READ
                    │       │
                    │       ├── if (res)
                    │       │       └── evsel->del(base, fd, old, EV_READ, extra)
                    │       │               └── epoll_nochangelist_del()
                    │       │                       └── epoll_apply_one_change(op=DEL)
                    │       │                               └── epoll_ctl(epfd, DEL, fd, NULL)
                    │       │
                    │       ├── ctx->nread = 0
                    │       └── LIST_REMOVE(ev, ev_io_next)
                    │
                    ├── event_queue_remove_inserted(base, ev)
                    │       └── ev->ev_flags &= ~EVLIST_INSERTED
                    │
                    └── 如果 event 在活跃队列：event_queue_remove_active()
```

---

## 十、关键设计要点

### 10.1 evmap 的"惰性"设计

| 操作 | 触发条件 | 目的 |
|------|---------|------|
| 后端 `add` | 某 fd **首次**监听某类事件 | 减少 epoll_ctl 调用 |
| 后端 `del` | 某 fd **最后**一个某类事件被移除 | 减少 epoll_ctl 调用 |
| `evmap_io` 创建 | fd 首次有事件 | 按需分配内存 |
| `evmap_io` 销毁 | 从不主动销毁 | 复用内存，fd 可能很快被重用 |

### 10.2 线程安全模型

```
┌─────────────────────────────────────────────────────┐
│                    th_base_lock                       │
│  (保护 event_base 的所有数据结构)                     │
└─────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
   event_add()      event_del()      event_base_loop()
        │                 │                 │
        ▼                 ▼                 ▼
   获取锁              获取锁            dispatch()
   修改 evmap          修改 evmap        │
   修改 timeheap       修改 activequeues  ▼
   释放锁              释放锁           epoll_wait()
                                         │ (阻塞，不持有锁)
                                         ▼
                                      返回后重新获取锁
```

- **`epoll_wait` 期间不持有锁**：允许其他线程并发 `event_add/del`
- **回调执行前释放锁**：防止用户代码死锁
- **内部事件（EVLIST_INTERNAL）不参与 notify**：避免不必要的线程唤醒

### 10.3 边缘触发（ET）vs 水平触发（LT）

```c
// 注册时
if (ev->ev_events & EV_ET) {
    // 边缘触发：epoll_ctl 时设置 EPOLLET
}

// dispatch 时
evmap_io_active_(base, fd, ev | EV_ET);  // EV_ET 标志会传递给 event

// 回调时
if (ev->ev_events & EV_ET) {
    // 用户需要循环读取直到 EAGAIN
}
```

**ET 模式注意事项**：
- 同一 fd 上所有 event 必须**统一** ET 或 LT（libevent 会检查并报错）
- ET 事件触发后，如果数据未处理完，不会再次通知，直到新数据到达
- libevent 不会在 ET 模式下自动重新激活，完全依赖用户代码处理

### 10.4 事件合并策略

```c
// evmap_io_active_ 中
if (ev->ev_events & (events & ~EV_ET))
    event_active_nolock_(ev, ev->ev_events & events, 1);
```

- 同一 fd 上的多个 event 可能同时被激活（如一个监听 READ，一个监听 WRITE）
- 但**每个 event 只激活一次**，即使多种事件同时就绪
- 回调参数 `what` 告知哪些事件就绪：`EV_READ | EV_WRITE`

### 10.5 多路复用后端的选择

libevent 根据平台自动选择最佳后端：

| 后端 | 平台 | 特性 |
|------|------|------|
| epoll | Linux | O(1), 支持 ET, 支持 EPOLLRDHUP |
| kqueue | BSD/macOS | O(1), 支持 EVFILT_READ/WRITE/SIGNAL |
| devpoll | Solaris | 较早的 O(1) 方案 |
| evport | Solaris 10+ | 高性能 |
| poll | 通用 | O(n), 无 fd 数量限制（相对 select） |
| select | 通用 | O(n), fd 数量受限（1024/2048） |
| wepoll | Windows | 用户态 epoll，基于 IOCP |

---

## 十一、总结

Libevent 的 IO FD 处理流程体现了**分层、惰性、聚合**的设计哲学：

1. **用户层**：提供简单直观的 `event_new/add/del` API
2. **管理层**：统一处理超时、活跃队列、线程安全
3. **映射层**：`evmap_io` 聚合同一 fd 的多个事件，惰性调用后端
4. **后端层**：专注与内核交互（epoll_wait/epoll_ctl），批量优化

这种设计使得：
- **同一 fd 多事件**高效处理（只注册一次 epoll）
- **频繁的 add/del**开销最小化（计数器判断是否需要系统调用）
- **跨平台**只需替换后端层，上层代码完全不变
