# Libevent Timer 详细工作流程

## 目录

- [一、概述](#一概述)
- [二、Timer 类型](#二timer-类型)
- [三、核心数据结构](#三核心数据结构)
- [四、Timer 初始化与注册](#四timer-初始化与注册)
- [五、主循环中的 Timer 调度](#五主循环中的-timer-调度)
- [六、超时检测与激活](#六超时检测与激活)
- [七、Common Timeout 优化](#七common-timeout-优化)
- [八、完整调用链](#八完整调用链)
- [九、关键设计要点](#九关键设计要点)

---

## 一、概述

Libevent 的 Timer 机制负责管理所有带超时的事件。它支持两种模式：

1. **普通 Timeout**：使用 **min-heap（小根堆）** 管理，适用于任意超时时间
2. **Common Timeout**：使用 **队列（TAILQ）** 管理，适用于大量相同超时时间的场景（如所有 HTTP 请求都设置 30 秒超时）

Timer 的核心设计目标是：
- **高效插入/删除**：O(log n) 的堆操作
- **精准触发**：计算最近的超时时间作为 `epoll_wait` 的等待时长
- **批量处理**：common timeout 避免每个事件单独入堆

---

## 二、Timer 类型

### 2.1 纯超时事件（无 IO）

```c
// 创建纯超时事件
struct event *ev = evtimer_new(base, callback, arg);
event_add(ev, &tv);  // tv = {5, 0} 表示 5 秒后触发
```

底层调用：
```c
event_assign(ev, base, -1, EV_TIMEOUT, callback, arg);
```

- `fd = -1` 表示这不是 IO 事件
- 只有 `EV_TIMEOUT`，没有 `EV_READ/WRITE`

### 2.2 IO 事件带超时

```c
struct event *ev = event_new(base, fd, EV_READ|EV_PERSIST, callback, arg);
event_add(ev, &tv);  // 5 秒内未读数据则触发超时
```

- 同一个 event 同时监听 IO 和超时
- 任一条件满足都会触发回调
- `ev->ev_res` 会标记是 `EV_READ` 还是 `EV_TIMEOUT` 触发的

### 2.3 持久超时事件

```c
struct event *ev = event_new(base, fd, EV_READ|EV_PERSIST, callback, arg);
event_add(ev, &tv);  // 每 tv 时间触发一次
```

- `EV_PERSIST` 表示事件触发后不会自动删除
- IO 触发后，timeout 会被重新计算（从当前时间 + tv）

---

## 三、核心数据结构

### 3.1 min_heap_t（普通超时堆）

```c
// minheap-internal.h
typedef struct min_heap {
    struct event** p;   // 事件指针数组
    size_t n;           // 当前元素数量
    size_t a;           // 数组容量
} min_heap_t;
```

**堆排序依据**：
```c
#define min_heap_elem_greater(a, b) \
    (evutil_timercmp(&(a)->ev_timeout, &(b)->ev_timeout, >))
```

- 按 `ev_timeout`（绝对超时时间）排序
- 堆顶是最近要超时的事件

### 3.2 event_base 中的 timer 相关字段

```c
struct event_base {
    struct min_heap timeheap;                    // 普通超时事件堆
    struct common_timeout_list **common_timeout_queues; // common timeout 队列数组
    int n_common_timeouts;                       // common timeout 数量
    int n_common_timeouts_allocated;             // 数组容量
    
    struct timeval tv_cache;                     // 时间缓存（减少系统调用）
    struct evutil_monotonic_timer monotonic_timer; // 单调时钟
    struct timeval tv_clock_diff;                // monotonic 与 wall time 差值
    time_t last_updated_clock_diff;              // 上次更新时间差
};
```

### 3.3 struct event 中的 timer 字段

```c
struct event {
    struct timeval ev_timeout;        // 绝对超时时间
    union {
        struct {
            struct timeval ev_timeout;
        } ev_io;
        struct {
            int ev_ncalls;
            int *ev_pncalls;
        } ev_signal;
    } ev_;
    
    // min-heap 索引（用于 O(1) 定位在堆中的位置）
    union {
        TAILQ_ENTRY(event) ev_next_with_common_timeout;
        int min_heap_idx;
    } ev_timeout_pos;
};
```

---

## 四、Timer 初始化与注册

### 4.1 event_add 中的 timeout 处理

```c
// event.c:2704
int event_add_nolock_(struct event *ev, const struct timeval *tv, int tv_is_absolute)
{
    // 步骤 1：添加到 IO 映射（如果有 EV_READ/WRITE/CLOSED）
    if (ev->ev_events & (EV_READ|EV_WRITE|EV_CLOSED)) {
        res = evmap_io_add_(base, ev->ev_fd, ev);
    }
    
    // 步骤 2：处理 timeout
    if (res != -1 && tv != NULL) {
        // 持久事件：保存超时值，用于后续重新调度
        if (ev->ev_closure == EV_CLOSURE_EVENT_PERSIST && !tv_is_absolute)
            ev->ev_io_timeout = *tv;
        
        // 移除旧的 timeout
        if (ev->ev_flags & EVLIST_TIMEOUT)
            event_queue_remove_timeout(base, ev);
        
        // 如果事件已经因超时而活跃，从活跃队列移除
        if ((ev->ev_flags & EVLIST_ACTIVE) && (ev->ev_res & EV_TIMEOUT)) {
            event_queue_remove_active(base, event_to_event_callback(ev));
        }
        
        // 计算绝对超时时间
        gettime(base, &now);
        
        int common_timeout = is_common_timeout(tv, base);
        
        if (tv_is_absolute) {
            ev->ev_timeout = *tv;  // 直接使用绝对时间
        } else if (common_timeout) {
            // Common timeout：提取真实时长，保留 magic/idx
            struct timeval tmp = *tv;
            tmp.tv_usec &= MICROSECONDS_MASK;
            evutil_timeradd(&now, &tmp, &ev->ev_timeout);
            ev->ev_timeout.tv_usec |= (tv->tv_usec & ~MICROSECONDS_MASK);
        } else {
            // 普通 timeout：now + tv
            evutil_timeradd(&now, tv, &ev->ev_timeout);
        }
        
        // 插入超时队列
        event_queue_insert_timeout(base, ev);
        
        // 如果是 common timeout 且是队列头部，重新调度内部 timer
        if (common_timeout) {
            struct common_timeout_list *ctl = get_common_timeout_list(base, &ev->ev_timeout);
            if (ev == TAILQ_FIRST(&ctl->events)) {
                common_timeout_schedule(ctl, &now, ev);
            }
        } else {
            // 如果是堆顶，需要唤醒 dispatch（因为可能提前了）
            if (min_heap_elt_is_top_(ev))
                notify = 1;
        }
    }
}
```

### 4.2 event_queue_insert_timeout

```c
static void event_queue_insert_timeout(struct event_base *base, struct event *ev)
{
    ev->ev_flags |= EVLIST_TIMEOUT;
    
    if (is_common_timeout(&ev->ev_timeout, base)) {
        // Common timeout：按超时时间有序插入队列
        struct common_timeout_list *ctl = get_common_timeout_list(base, &ev->ev_timeout);
        insert_common_timeout_inorder(ctl, ev);
    } else {
        // 普通 timeout：入堆
        min_heap_push_(&base->timeheap, ev);
    }
}
```

### 4.3 event_queue_remove_timeout

```c
static void event_queue_remove_timeout(struct event_base *base, struct event *ev)
{
    ev->ev_flags &= ~EVLIST_TIMEOUT;
    
    if (is_common_timeout(&ev->ev_timeout, base)) {
        // 从 common timeout 队列移除
        struct common_timeout_list *ctl = get_common_timeout_list(base, &ev->ev_timeout);
        TAILQ_REMOVE(&ctl->events, ev, ev_timeout_pos.ev_next_with_common_timeout);
    } else {
        // 从 min-heap 移除
        min_heap_erase_(&base->timeheap, ev);
    }
}
```

---

## 五、主循环中的 Timer 调度

### 5.1 event_base_loop 主循环

```c
int event_base_loop(struct event_base *base, int flags)
{
    while (!done) {
        struct timeval tv;
        struct timeval *tv_p = &tv;
        
        // 步骤 1：计算下一次 epoll_wait 的最大等待时间
        if (!N_ACTIVE_CALLBACKS(base) && !(flags & EVLOOP_NONBLOCK)) {
            timeout_next(base, &tv_p);
        } else {
            // 已有活跃事件，非阻塞 poll
            evutil_timerclear(&tv);
        }
        
        // 步骤 2：等待 IO 事件（最多等待 tv_p 时长）
        res = evsel->dispatch(base, tv_p);
        
        // 步骤 3：处理超时事件
        timeout_process(base);
        
        // 步骤 4：处理活跃事件（IO + 超时回调）
        if (N_ACTIVE_CALLBACKS(base))
            event_process_active(base);
    }
}
```

### 5.2 timeout_next：计算等待时间

```c
static int timeout_next(struct event_base *base, struct timeval **tv_p)
{
    struct timeval now;
    struct event *ev;
    struct timeval *tv = *tv_p;
    
    // 获取堆顶事件（最近要超时的）
    ev = min_heap_top_(&base->timeheap);
    
    if (ev == NULL) {
        // 没有 timeout 事件，epoll_wait 可以无限等待
        *tv_p = NULL;
        return 0;
    }
    
    // 获取当前时间
    gettime(base, &now);
    
    if (evutil_timercmp(&ev->ev_timeout, &now, <=)) {
        // 已经有事件超时了！epoll_wait 立即返回（不阻塞）
        evutil_timerclear(tv);
        return 0;
    }
    
    // 计算剩余时间 = 超时时间 - 当前时间
    evutil_timersub(&ev->ev_timeout, &now, tv);
    
    // tv 现在就是 epoll_wait 应该等待的最长时间
    return 0;
}
```

**设计要点**：
- `tv_p = NULL`：没有 timeout 事件，可以无限等待 IO
- `tv = {0, 0}`：已有事件超时，立即返回不阻塞
- `tv = 剩余时间`：精确等待到下一个超时事件发生

### 5.3 dispatch 中的时间处理（以 epoll 为例）

```c
static int epoll_dispatch(struct event_base *base, struct timeval *tv)
{
    // 将 timeval 转换为 epoll_wait 需要的格式
#if defined(EVENT__HAVE_EPOLL_PWAIT2)
    struct timespec ts;
    TIMEVAL_TO_TIMESPEC(tv, &ts);
    res = epoll_pwait2(epollop->epfd, events, nevents, tv ? &ts : NULL, NULL);
#else
    long timeout = evutil_tv_to_msec_(tv);
    if (timeout > MAX_EPOLL_TIMEOUT_MSEC)
        timeout = MAX_EPOLL_TIMEOUT_MSEC;  // Linux 内核限制
    res = epoll_wait(epollop->epfd, events, nevents, timeout);
#endif
}
```

---

## 六、超时检测与激活

### 6.1 timeout_process：激活超时事件

```c
static void timeout_process(struct event_base *base)
{
    struct timeval now;
    struct event *ev;
    
    if (min_heap_empty_(&base->timeheap))
        return;
    
    gettime(base, &now);
    
    // 循环检查堆顶事件，直到没有超时事件
    while ((ev = min_heap_top_(&base->timeheap))) {
        int was_active = ev->ev_flags & (EVLIST_ACTIVE|EVLIST_ACTIVE_LATER);
        
        // 如果堆顶事件还没到时间，后面的更不会到（堆性质）
        if (evutil_timercmp(&ev->ev_timeout, &now, >))
            break;
        
        // 从 timeout 队列移除
        if (!was_active)
            event_del_nolock_(ev, EVENT_DEL_NOBLOCK);  // 从所有队列移除
        else
            event_queue_remove_timeout(base, ev);       // 只从 timeout 队列移除
        
        // 激活事件
        event_active_nolock_(ev, EV_TIMEOUT, 1);
    }
}
```

**关键逻辑**：
1. 获取当前时间 `now`
2. 循环检查堆顶事件的 `ev_timeout`
3. 如果 `ev_timeout <= now`，说明已超时，激活它
4. 由于是最小堆，一旦堆顶未超时，后续事件必然也未超时，立即退出

### 6.2 事件激活后的处理

```c
void event_active_nolock_(struct event *ev, int res, short ncalls)
{
    struct event_base *base = ev->ev_base;
    
    // 设置触发结果
    ev->ev_res = res;  // EV_TIMEOUT
    
    // 加入活跃队列
    event_callback_activate_nolock_(base, event_to_event_callback(ev));
}
```

### 6.3 回调执行时的超时处理

```c
// event_process_active_single_queue
case EV_CLOSURE_EVENT: {
    void (*cb)(evutil_socket_t, short, void *) = ev->ev_callback;
    short res = ev->ev_res;  // EV_TIMEOUT
    
    EVBASE_RELEASE_LOCK(base, th_base_lock);
    cb(ev->ev_fd, res, ev->ev_arg);  // 用户回调！
    // 回调中可通过 (res & EV_TIMEOUT) 判断是否超时触发
}
```

---

## 七、Common Timeout 优化

### 7.1 为什么需要 Common Timeout？

**问题**：如果服务器有 10000 个连接，每个都设置 30 秒超时：
- 普通方式：10000 个 event 入堆，每次插入/删除 O(log n)
- 大量事件的超时时间相同或接近，堆操作冗余

**优化**：将相同超时时间的事件放入一个队列，只用一个内部 timer 管理

### 7.2 创建 Common Timeout

```c
const struct timeval *
event_base_init_common_timeout(struct event_base *base, const struct timeval *duration)
{
    // 检查是否已有相同 duration 的 common timeout
    for (i = 0; i < base->n_common_timeouts; ++i) {
        if (duration->tv_sec == ctl->duration.tv_sec &&
            duration->tv_usec == (ctl->duration.tv_usec & MICROSECONDS_MASK))
            return &ctl->duration;  // 已存在，返回已有的
    }
    
    // 创建新的 common_timeout_list
    new_ctl = mm_calloc(1, sizeof(struct common_timeout_list));
    TAILQ_INIT(&new_ctl->events);
    
    // 编码 duration：真实时间 + magic + idx
    new_ctl->duration.tv_sec = duration->tv_sec;
    new_ctl->duration.tv_usec = duration->tv_usec 
        | COMMON_TIMEOUT_MAGIC 
        | (base->n_common_timeouts << COMMON_TIMEOUT_IDX_SHIFT);
    
    // 创建内部事件：用于触发该 common timeout 队列
    evtimer_assign(&new_ctl->timeout_event, base, common_timeout_callback, new_ctl);
    new_ctl->timeout_event.ev_flags |= EVLIST_INTERNAL;
    event_priority_set(&new_ctl->timeout_event, 0);
    new_ctl->base = base;
    
    base->common_timeout_queues[base->n_common_timeouts++] = new_ctl;
    
    return &new_ctl->duration;
}
```

### 7.3 Common Timeout 回调

```c
static void common_timeout_callback(evutil_socket_t fd, short what, void *arg)
{
    struct timeval now;
    struct common_timeout_list *ctl = arg;
    struct event_base *base = ctl->base;
    struct event *ev = NULL;
    
    EVBASE_ACQUIRE_LOCK(base, th_base_lock);
    gettime(base, &now);
    
    while (1) {
        ev = TAILQ_FIRST(&ctl->events);
        
        // 检查队首事件是否已超时
        if (!ev || ev->ev_timeout.tv_sec > now.tv_sec ||
            (ev->ev_timeout.tv_sec == now.tv_sec &&
             (ev->ev_timeout.tv_usec & MICROSECONDS_MASK) > now.tv_usec))
            break;
        
        // 从队列移除并激活
        was_active = ev->ev_flags & (EVLIST_ACTIVE|EVLIST_ACTIVE_LATER);
        if (!was_active)
            event_del_nolock_(ev, EVENT_DEL_NOBLOCK);
        else
            event_queue_remove_timeout(base, ev);
        
        event_active_nolock_(ev, EV_TIMEOUT, 1);
    }
    
    // 如果队列还有事件，重新调度内部 timer
    if (ev)
        common_timeout_schedule(ctl, &now, ev);
    
    EVBASE_RELEASE_LOCK(base, th_base_lock);
}
```

### 7.4 Common Timeout 的调度

```c
static void common_timeout_schedule(struct common_timeout_list *ctl,
    const struct timeval *now, struct event *head)
{
    struct timeval timeout = head->ev_timeout;
    timeout.tv_usec &= MICROSECONDS_MASK;  // 去掉 magic/idx
    event_add_nolock_(&ctl->timeout_event, &timeout, 1);  // 1 = absolute
}
```

**工作流程**：
1. 用户调用 `event_base_init_common_timeout(base, &tv_100ms)` 创建 common timeout
2. 返回的 `struct timeval *` 带有 magic/idx 编码
3. 用户用这个指针作为 `event_add(ev, common_tv)` 的参数
4. event 被插入 `common_timeout_list->events` 队列（按超时时间排序）
5. 如果 event 是队首（最早超时），调度内部 `timeout_event`
6. 内部 timer 触发时，遍历队列，激活所有已超时的事件
7. 如果队列还有事件，重新调度内部 timer 到下一个事件的时间

---

## 八、完整调用链

### 8.1 注册 Timer

```
用户代码
    │
    ├── event_new(base, -1, EV_TIMEOUT, cb, arg)  或
    │   event_new(base, fd, EV_READ, cb, arg) + event_add(ev, &tv)
    │
    └── event_add(ev, &tv)
            └── event_add_nolock_(ev, &tv, 0)
                    │
                    ├── 如果有 IO 事件：evmap_io_add_()
                    │
                    ├── gettime(base, &now)
                    │
                    ├── 计算绝对超时时间
                    │       ├── tv_is_absolute: ev_timeout = tv
                    │       ├── common_timeout: ev_timeout = now + (tv & mask)
                    │       │                   保留 magic/idx 在 tv_usec
                    │       └── 普通 timeout: ev_timeout = now + tv
                    │
                    ├── event_queue_insert_timeout(base, ev)
                    │       ├── common_timeout?
                    │       │       └── insert_common_timeout_inorder(ctl, ev)
                    │       │               TAILQ_INSERT_TAIL/AFTER()
                    │       └── 普通 timeout
                    │               └── min_heap_push_(&base->timeheap, ev)
                    │
                    └── common_timeout && 是队首?
                            └── common_timeout_schedule(ctl, &now, ev)
                                    └── event_add_nolock_(&ctl->timeout_event, &timeout, 1)
                                            └── min_heap_push_(&base->timeheap, &ctl->timeout_event)
```

### 8.2 主循环调度

```
event_base_loop()
    │
    ├── timeout_next(base, &tv_p)
    │       ├── ev = min_heap_top_(&base->timeheap)
    │       ├── ev == NULL?
    │       │       └── *tv_p = NULL  // 无限等待
    │       ├── gettime(base, &now)
    │       ├── ev_timeout <= now?
    │       │       └── tv = {0, 0}   // 已有超时，立即返回
    │       └── ev_timeout - now = tv  // 精确等待时间
    │
    ├── evsel->dispatch(base, tv_p)   // epoll_wait(tv_p)
    │       └── 阻塞等待 tv 时间，或 IO 事件到达
    │
    ├── timeout_process(base)
    │       ├── gettime(base, &now)
    │       └── while (ev = min_heap_top())
    │               ├── ev_timeout > now? break
    │               ├── event_queue_remove_timeout(base, ev)
    │               │       ├── common? TAILQ_REMOVE()
    │               │       └── 普通: min_heap_erase_()
    │               └── event_active_nolock_(ev, EV_TIMEOUT, 1)
    │                       └── TAILQ_INSERT_TAIL(&activequeues[pri], evcb)
    │
    └── event_process_active(base)
            └── event_process_active_single_queue()
                    └── case EV_CLOSURE_EVENT:
                            EVBASE_RELEASE_LOCK()
                            cb(fd, EV_TIMEOUT, arg)   // 用户回调！
```

### 8.3 Common Timeout 触发

```
epoll_wait 返回（ctl->timeout_event 超时）
    │
    └── evmap_io_active_() / timeout_process()  // timeout_event 是内部 timer
            └── event_active_nolock_(&ctl->timeout_event, EV_TIMEOUT, 1)
                    └── event_process_active()
                            └── common_timeout_callback(fd, EV_TIMEOUT, ctl)
                                    │
                                    ├── gettime(base, &now)
                                    │
                                    ├── while (ev = TAILQ_FIRST(&ctl->events))
                                    │       ├── ev_timeout > now? break
                                    │       ├── event_queue_remove_timeout(base, ev)
                                    │       └── event_active_nolock_(ev, EV_TIMEOUT, 1)
                                    │
                                    └── if (队列非空)
                                            common_timeout_schedule(ctl, &now, ev)
                                                    └── 重新设置内部 timer
```

---

## 九、关键设计要点

### 9.1 绝对时间 vs 相对时间

| 类型 | 存储方式 | 计算时机 |
|------|---------|---------|
| `ev_timeout` | 绝对时间（相对于 epoch） | `event_add` 时计算 |
| `ev_io_timeout` | 相对时间（间隔） | 持久事件重新调度时使用 |

**为什么用绝对时间？**
- 避免每次检查都重新计算
- 系统时间被修改时（NTP 同步），绝对时间更直观
- 但需要注意系统时间回拨问题（libevent 有缓存机制）

### 9.2 时间缓存机制

```c
struct event_base {
    struct timeval tv_cache;      // 缓存时间，减少 gettimeofday 调用
};

// dispatch 前：清除缓存
clear_time_cache(base);

// dispatch 后：更新缓存
update_time_cache(base);

// timeout_process 中使用缓存时间
gettime(base, &now);  // 优先使用 tv_cache
```

- 减少 `gettimeofday()`/`clock_gettime()` 系统调用次数
- 在一次循环迭代中，所有 timer 操作使用同一时间基准

### 9.3 单调时钟（Monotonic Clock）

```c
struct evutil_monotonic_timer {
    int monotonic_clock;  // CLOCK_MONOTONIC 或 -1
};
```

- 使用 `CLOCK_MONOTONIC` 避免系统时间被修改导致的混乱
- 维护 `tv_clock_diff` 将单调时间映射到 wall time
- 如果系统不支持单调时钟，退化为 `gettimeofday()`

### 9.4 Timer 精度

| 因素 | 影响 |
|------|------|
| `gettimeofday()` 精度 | 微秒级（但受系统调度影响） |
| `epoll_wait` 精度 | 毫秒级（timeout 参数是 int ms） |
| `epoll_pwait2` | 纳秒级（Linux 5.11+） |
| `timerfd` | 纳秒级（配合 `EVENT_BASE_FLAG_PRECISE_TIMER`） |
| 系统负载 | 内核调度延迟 |

**实际精度**：通常在 1-10 毫秒范围，除非使用 `PRECISE_TIMER` + `timerfd`。

### 9.5 超时与 IO 的关系

```c
// 场景：event_add(ev, &tv)，ev 同时有 EV_READ 和 EV_TIMEOUT

// 可能的结果：
ev->ev_res = EV_READ;           // IO 先到达，超时取消
ev->ev_res = EV_TIMEOUT;        // 超时先到达，IO 取消
ev->ev_res = EV_READ | EV_TIMEOUT;  // 两者同时（极少）

// 用户回调中判断：
if (what & EV_READ) { /* 处理读 */ }
if (what & EV_TIMEOUT) { /* 处理超时 */ }
```

**注意**：
- IO 和 timeout 是独立的触发条件
- 一旦任一条件满足，event 就被激活
- 回调中需要根据 `ev_res` 判断具体原因

### 9.6 持久事件的超时重调度

```c
// EV_PERSIST 事件触发后：
static inline void event_persist_closure(struct event_base *base, struct event *ev)
{
    if (ev->ev_io_timeout.tv_sec || ev->ev_io_timeout.tv_usec) {
        // 重新计算超时时间
        struct timeval run_at, now;
        gettime(base, &now);
        
        // 从上次调度时间 + 间隔（而非从 now + 间隔）
        evutil_timeradd(&ev->ev_timeout, &ev->ev_io_timeout, &run_at);
        
        if (evutil_timercmp(&run_at, &now, <)) {
            // 如果已经过期，立即触发
            ev->ev_timeout = now;
        } else {
            ev->ev_timeout = run_at;
        }
        
        event_queue_insert_timeout(base, ev);
    }
}
```

**关键设计**：
- 持久事件的超时基于**上次调度时间**（而非上次触发时间）
- 这保证定时精度，避免累积误差
- 如果处理耗时超过间隔，超时时间会被调整为 "now"（立即再次触发）

### 9.7 min-heap vs common timeout 对比

| 特性 | 普通 min-heap | Common timeout |
|------|--------------|----------------|
| 适用场景 | 任意、分散的超时时间 | 大量相同超时时间 |
| 插入复杂度 | O(log n) | O(1)（链表尾部） |
| 删除复杂度 | O(log n) | O(1)（已知前驱） |
| 检查超时 | O(k log n)（k 个超时） | O(k)（线性扫描队列） |
| 内存占用 | 一个堆 | 堆（内部 timer）+ 多个队列 |
| 典型用例 | 随机超时 | HTTP 连接超时、心跳超时 |

---

## 十、总结

Libevent 的 Timer 机制是一个**分层、高效、可扩展**的设计：

1. **普通 Timer** 使用 **min-heap** 管理，保证 O(log n) 的插入/删除和 O(1) 的堆顶查询
2. **Common Timeout** 使用 **队列** 优化大量相同超时时间的场景，减少堆操作
3. **主循环** 通过 `timeout_next` 精确计算 `epoll_wait` 等待时间，实现 Timer 与 IO 的高效融合
4. **时间缓存** 和 **单调时钟** 保证精度和性能
5. **持久事件** 基于上次调度时间重算超时，避免累积误差

> **一句话总结**：Libevent 通过 min-heap 管理普通超时事件，用队列优化 common timeout，在主循环中将最近的超时时间传递给后端（epoll_wait），实现 IO 与 Timer 的统一调度。超时事件在 `timeout_process` 中批量检测并激活，最终通过活跃队列执行用户回调。
