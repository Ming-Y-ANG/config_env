# Libevent Bufferevent 实现原理详解

## 目录

- [一、概述](#一概述)
- [二、架构设计](#二架构设计)
- [三、核心数据结构](#三核心数据结构)
- [四、创建与初始化](#四创建与初始化)
- [五、数据流详解](#五数据流详解)
- [六、水位线（Watermark）机制](#六水位线watermark机制)
- [七、超时机制](#七超时机制)
- [八、回调触发机制](#八回调触发机制)
- [九、挂起（Suspend）机制](#九挂起suspend机制)
- [十、Bufferevent 类型](#十bufferevent-类型)
- [十一、完整调用链](#十一完整调用链)
- [十二、关键设计要点](#十二关键设计要点)

---

## 一、概述

**Bufferevent** 是 libevent 提供的高级 IO 抽象，它将底层的：
- **Socket fd**
- **读写缓冲区（evbuffer）**
- **事件监听（event）**
- **超时管理**

封装成一个统一的对象。用户只需关心**"读 input buffer、写 output buffer"**，底层的**非阻塞读写、事件分派、缓冲区管理**全部由 bufferevent 自动处理。

**核心价值**：
- 避免手动管理 `EAGAIN`、`EINTR` 等复杂逻辑
- 内置读写缓冲，解耦生产/消费速率
- 统一的事件回调模型（read/write/event）
- 支持 SSL、filter、pair 等多种变体

---

## 二、架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                      Bufferevent                             │
│  ┌──────────────┐                    ┌──────────────┐       │
│  │  Input Buffer │ ◄── socket read   │ Output Buffer│       │
│  │   (evbuffer)  │                   │  (evbuffer)  │──►    │
│  └──────┬────────┘                   └──────┬───────┘       │
│         │                                   │               │
│         ▼                                   ▼               │
│  ┌──────────────┐                    ┌──────────────┐       │
│  │   read_cb    │                    │   write_cb   │       │
│  └──────────────┘                    └──────────────┘       │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    eventcb (error/EOF/connected)        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  ev_read    │  │  ev_write   │  │  timeout events     │ │
│  │  (event)    │  │  (event)    │  │                     │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │   Socket fd  │
                    └──────────────┘
```

**设计哲学**：
- **输入缓冲**：用户从 `input` 读取，libevent 自动从 socket 填充
- **输出缓冲**：用户向 `output` 写入，libevent 自动向 socket 发送
- **事件驱动**：所有操作由 `ev_read`、`ev_write` 事件触发，无数据时不消耗 CPU

---

## 三、核心数据结构

### 3.1 struct bufferevent（公共结构）

```c
struct bufferevent {
    struct event_base *ev_base;          // 关联的 event_base
    const struct bufferevent_ops *be_ops; // 类型操作表（虚函数表）
    
    struct event ev_read;                // 读事件（socket 可读/超时）
    struct event ev_write;               // 写事件（socket 可写/超时）
    
    struct evbuffer *input;              // 输入缓冲区（用户读，libevent 写）
    struct evbuffer *output;             // 输出缓冲区（用户写，libevent 读）
    
    struct event_watermark wm_read;      // 读水位线
    struct event_watermark wm_write;     // 写水位线
    
    bufferevent_data_cb readcb;          // 读回调
    bufferevent_data_cb writecb;         // 写回调
    bufferevent_event_cb errorcb;        // 事件/错误回调
    void *cbarg;                         // 回调参数
    
    struct timeval timeout_read;         // 读超时
    struct timeval timeout_write;        // 写超时
    
    short enabled;                       // 启用的方向：EV_READ | EV_WRITE
};
```

### 3.2 struct bufferevent_private（私有扩展）

```c
struct bufferevent_private {
    struct bufferevent bev;              // 公共部分（必须放第一个）
    
    struct evbuffer_cb_entry *read_watermarks_cb;  // input buffer 的水位线回调
    
    // 延迟回调标志
    unsigned readcb_pending : 1;         // readcb 待执行
    unsigned writecb_pending : 1;        // writecb 待执行
    short eventcb_pending;               // eventcb 待执行的事件掩码
    
    // 挂起标志（位图）
    bufferevent_suspend_flags read_suspended;   // 读挂起原因
    bufferevent_suspend_flags write_suspended;  // 写挂起原因
    
    unsigned connecting : 1;             // 正在连接中
    unsigned connection_refused : 1;     // 连接被拒绝
    
    struct event_callback deferred;      // 延迟回调对象
    enum bufferevent_options options;    // 创建选项
    int refcnt;                          // 引用计数
    void *lock;                          // 线程锁
    
    ev_ssize_t max_single_read;          // 单次最大读取量
    ev_ssize_t max_single_write;         // 单次最大写入量
    
    struct bufferevent_rate_limit *rate_limiting;  // 限速信息
};
```

### 3.3 struct bufferevent_ops（类型操作表）

```c
struct bufferevent_ops {
    const char *type;
    off_t mem_offset;                    // bev 在实现结构中的偏移
    int (*enable)(struct bufferevent *, short);
    int (*disable)(struct bufferevent *, short);
    void (*unlink)(struct bufferevent *);
    void (*destruct)(struct bufferevent *);
    int (*adj_timeouts)(struct bufferevent *);
    int (*flush)(struct bufferevent *, short, enum bufferevent_flush_mode);
    int (*ctrl)(struct bufferevent *, enum bufferevent_ctrl_op, union bufferevent_ctrl_data *);
};
```

**类型区分**：
```c
#define BEV_IS_SOCKET(bevp) ((bevp)->be_ops == &bufferevent_ops_socket)
#define BEV_IS_FILTER(bevp) ((bevp)->be_ops == &bufferevent_ops_filter)
#define BEV_IS_PAIR(bevp)   ((bevp)->be_ops == &bufferevent_ops_pair)
#define BEV_IS_SSL(bevp)    (!memcmp((bevp)->be_ops->type, "ssl", 3))
```

---

## 四、创建与初始化

### 4.1 Socket Bufferevent 创建

```c
struct bufferevent *bufferevent_socket_new(
    struct event_base *base, 
    evutil_socket_t fd, 
    int options)
{
    struct bufferevent_private *bufev_p = mm_calloc(1, sizeof(*bufev_p));
    
    // 初始化公共部分（创建 input/output evbuffer 等）
    bufferevent_init_common_(bufev_p, base, &bufferevent_ops_socket, options);
    
    struct bufferevent *bufev = &bufev_p->bev;
    
    // 标记 output buffer 会 drain 到 fd
    evbuffer_set_flags(bufev->output, EVBUFFER_FLAG_DRAINS_TO_FD);
    
    // 注册底层 socket 事件
    event_assign(&bufev->ev_read, base, fd,
        EV_READ|EV_PERSIST|EV_FINALIZE, bufferevent_readcb, bufev);
    event_assign(&bufev->ev_write, base, fd,
        EV_WRITE|EV_PERSIST|EV_FINALIZE, bufferevent_writecb, bufev);
    
    // output buffer 添加回调：有数据写入时自动触发写事件
    evbuffer_add_cb(bufev->output, bufferevent_socket_outbuf_cb, bufev);
    
    // 冻结 buffer：用户只能读 input，只能写 output
    evbuffer_freeze(bufev->input, 0);   // 禁止用户添加数据到 input
    evbuffer_freeze(bufev->output, 1);  // 禁止用户删除 output 的数据
    
    return bufev;
}
```

### 4.2 公共初始化

```c
int bufferevent_init_common_(struct bufferevent_private *bufev_p,
    struct event_base *base, const struct bufferevent_ops *ops,
    enum bufferevent_options options)
{
    struct bufferevent *bufev = &bufev_p->bev;
    
    // 创建 input/output evbuffer
    bufev->input = evbuffer_new();
    bufev->output = evbuffer_new();
    
    bufev_p->refcnt = 1;
    bufev->ev_base = base;
    bufev->be_ops = ops;
    
    // 默认只启用写（EV_READ 需要用户显式 enable）
    bufev->enabled = EV_WRITE;
    
    // 初始化延迟回调
    event_deferred_cb_init_(&bufev_p->deferred, priority,
        bufferevent_run_deferred_callbacks_locked, bufev_p);
    
    // 设置 parent（用于 evbuffer 回调找到所属的 bufferevent）
    evbuffer_set_parent_(bufev->input, bufev);
    evbuffer_set_parent_(bufev->output, bufev);
    
    return 0;
}
```

**设计要点**：
- `EV_FINALIZE`：bufferevent 释放时自动清理事件
- `enabled = EV_WRITE`：默认可写，读需要显式 `bufferevent_enable(bev, EV_READ)`
- buffer 冻结：确保数据流向正确（用户读 input，libevent 写 input；用户写 output，libevent 读 output）

---

## 五、数据流详解

### 5.1 读路径（Socket → Input Buffer → User）

```
Socket 有数据到达
    │
    ▼
epoll_wait 返回（fd 可读）
    │
    ▼
ev_read 事件触发 → bufferevent_readcb(fd, EV_READ, bev)
    │
    ├── 检查超时
    ├── 检查水位线（wm_read.high）
    │       └── 如果 input 已达到高水位，暂停读取
    │
    ├── evbuffer_read(input, fd, howmuch)
    │       └── 循环 read()/recv() 直到 EAGAIN
    │
    ├── 扣除限速令牌
    │
    └── bufferevent_trigger_nolock_(bev, EV_READ, 0)
            │
            ├── input 长度 >= wm_read.low?
            │       └── 触发 readcb
            │
            └── input 长度 >= wm_read.high?
                    └── 暂停读（高水位保护）

用户代码（readcb 中）
    │
    ├── bufferevent_read(bev, buf, len)
    │       └── evbuffer_remove(input, buf, len)
    │
    └── 如果 input 长度 < wm_read.high
            └── 恢复读（取消暂停）
```

**核心函数**：`bufferevent_readcb`

```c
static void bufferevent_readcb(evutil_socket_t fd, short event, void *arg)
{
    struct bufferevent *bufev = arg;
    struct evbuffer *input = bufev->input;
    int res;
    ev_ssize_t howmuch = -1;
    
    // 1. 超时处理
    if (event == EV_TIMEOUT) {
        what |= BEV_EVENT_TIMEOUT;
        goto error;
    }
    
    // 2. 计算可读上限（受限于高水位线）
    if (bufev->wm_read.high != 0) {
        howmuch = bufev->wm_read.high - evbuffer_get_length(input);
        if (howmuch <= 0) {
            bufferevent_wm_suspend_read(bufev);  // 达到高水位，暂停
            goto done;
        }
    }
    
    // 3. 限速检查
    howmuch = bufferevent_get_read_max_(bufev_p);
    
    // 4. 从 socket 读取数据到 input buffer
    evbuffer_unfreeze(input, 0);
    res = evbuffer_read(input, fd, (int)howmuch);
    evbuffer_freeze(input, 0);
    
    if (res == -1) {
        if (EVUTIL_ERR_RW_RETRIABLE(err))
            goto reschedule;  // EAGAIN，下次再读
        what |= BEV_EVENT_ERROR;
    } else if (res == 0) {
        what |= BEV_EVENT_EOF;  // 对端关闭
    }
    
    if (res <= 0)
        goto error;
    
    // 5. 限速记账
    bufferevent_decrement_read_buckets_(bufev_p, res);
    
    // 6. 触发读回调（如果达到低水位线）
    bufferevent_trigger_nolock_(bufev, EV_READ, 0);
    
    // 7. 重置读超时
    BEV_RESET_GENERIC_READ_TIMEOUT(bufev);
    
 error:
    bufferevent_disable(bufev, EV_READ);
    bufferevent_run_eventcb_(bufev, what, 0);
}
```

### 5.2 写路径（User → Output Buffer → Socket）

```
用户代码
    │
    ├── bufferevent_write(bev, data, size)
    │       └── evbuffer_add(output, data, size)
    │
    └── output buffer 数据增加
            │
            └── 触发 evbuffer 回调：bufferevent_socket_outbuf_cb
                    │
                    └── 如果 EV_WRITE 已启用且未挂起
                            └── event_add(&ev_write, timeout)
                                    │
                                    └── 注册 socket 可写事件

Socket 可写
    │
    ▼
ev_write 事件触发 → bufferevent_writecb(fd, EV_WRITE, bev)
    │
    ├── 检查超时
    ├── 检查是否正在连接（connecting）
    │       └── 如果是，处理连接完成（BEV_EVENT_CONNECTED）
    │
    ├── evbuffer_write_atmost(output, fd, atmost)
    │       └── 循环 write()/send() 直到 EAGAIN 或 buffer 空
    │
    ├── 扣除限速令牌
    │
    ├── 如果 output 已空
    │       └── event_del(&ev_write)  // 无需监听可写
    │
    └── bufferevent_trigger_nolock_(bev, EV_WRITE, 0)
            │
            └── output 长度 <= wm_write.low?
                    └── 触发 writecb
```

**核心函数**：`bufferevent_writecb`

```c
static void bufferevent_writecb(evutil_socket_t fd, short event, void *arg)
{
    struct bufferevent *bufev = arg;
    int res = 0;
    ev_ssize_t atmost = -1;
    
    // 1. 超时处理
    if (event == EV_TIMEOUT) {
        what |= BEV_EVENT_TIMEOUT;
        goto error;
    }
    
    // 2. 处理异步连接完成
    if (bufev_p->connecting) {
        c = evutil_socket_finished_connecting_(fd);
        bufev_p->connecting = 0;
        if (c > 0) {
            bufferevent_run_eventcb_(bufev, BEV_EVENT_CONNECTED, 0);
        }
    }
    
    // 3. 限速检查
    atmost = bufferevent_get_write_max_(bufev_p);
    
    // 4. 从 output buffer 写入 socket
    if (evbuffer_get_length(bufev->output)) {
        evbuffer_unfreeze(bufev->output, 1);
        res = evbuffer_write_atmost(bufev->output, fd, atmost);
        evbuffer_freeze(bufev->output, 1);
        
        if (res == -1) {
            if (EVUTIL_ERR_RW_RETRIABLE(err))
                goto reschedule;
            what |= BEV_EVENT_ERROR;
        }
        
        bufferevent_decrement_write_buckets_(bufev_p, res);
    }
    
    // 5. 如果 output 已空，删除写事件监听（节省 CPU）
    if (evbuffer_get_length(bufev->output) == 0) {
        event_del(&bufev->ev_write);
    }
    
    // 6. 触发写回调（如果 output 低于低水位线）
    bufferevent_trigger_nolock_(bufev, EV_WRITE, 0);
    
    // 7. 重置写超时
    BEV_RESET_GENERIC_WRITE_TIMEOUT(bufev);
}
```

### 5.3 Output Buffer 自动写触发

```c
static void bufferevent_socket_outbuf_cb(struct evbuffer *buf,
    const struct evbuffer_cb_info *cbinfo, void *arg)
{
    struct bufferevent *bufev = arg;
    
    // 有数据被添加到 output buffer
    if (cbinfo->n_added &&
        (bufev->enabled & EV_WRITE) &&           // 写已启用
        !event_pending(&bufev->ev_write, EV_WRITE, NULL) &&  // 未监听可写
        !bufev_p->write_suspended) {             // 未挂起
        
        // 开始监听 socket 可写事件
        bufferevent_add_event_(&bufev->ev_write, &bufev->timeout_write);
    }
}
```

**关键设计**：
- output 有数据时自动监听可写事件
- output 空时自动停止监听（避免无效 epoll 通知）
- 用户只管 `bufferevent_write()`，底层自动调度发送

---

## 六、水位线（Watermark）机制

水位线用于**流量控制**，防止缓冲区无限增长。

### 6.1 读水位线（Read Watermark）

```c
struct event_watermark {
    size_t low;   // 低水位线
    size_t high;  // 高水位线
};
```

| 条件 | 行为 |
|------|------|
| `input.len < low` | 不触发 `readcb`（数据太少，等攒够） |
| `input.len >= low` | 触发 `readcb` |
| `input.len >= high` | **暂停读**（从 socket 停止读取，保护内存） |
| `input.len < high`（用户读取后） | **恢复读** |

**设置**：
```c
bufferevent_setwatermark(bev, EV_READ, low, high);
```

**实现**：
```c
// input buffer 添加 evbuffer 回调
static void bufferevent_inbuf_wm_cb(struct evbuffer *buf,
    const struct evbuffer_cb_info *cbinfo, void *arg)
{
    struct bufferevent *bufev = arg;
    size_t size = evbuffer_get_length(buf);
    
    if (size >= bufev->wm_read.high)
        bufferevent_wm_suspend_read(bufev);   // 暂停读
    else
        bufferevent_wm_unsuspend_read(bufev); // 恢复读
}
```

### 6.2 写水位线（Write Watermark）

| 条件 | 行为 |
|------|------|
| `output.len > low` | 不触发 `writecb`（buffer 里还有数据） |
| `output.len <= low` | 触发 `writecb`（buffer 已排空或低于低水位） |

**注意**：写水位线**没有 high**，因为 output buffer 过大通常由用户控制写入速率。

**设置**：
```c
bufferevent_setwatermark(bev, EV_WRITE, low, 0);  // high 忽略
```

### 6.3 默认水位线

- **读**：`low = 0, high = 0`（无限制，有数据就触发 readcb）
- **写**：`low = 0`（output 空了才触发 writecb）

---

## 七、超时机制

### 7.1 超时事件

```c
struct bufferevent {
    struct timeval timeout_read;   // 读超时
    struct timeval timeout_write;  // 写超时
    struct event ev_read;          // 同时承担超时功能
    struct event ev_write;         // 同时承担超时功能
};
```

**实现原理**：
- `ev_read` 和 `ev_write` 既是 **IO 事件**（socket 可读/可写），也是 **超时事件**
- 当设置超时时，`event_add(&ev_read, &timeout_read)` 同时监听可读和超时

### 7.2 设置超时

```c
int bufferevent_set_timeouts(struct bufferevent *bufev,
    const struct timeval *timeout_read,
    const struct timeval *timeout_write)
{
    // 保存超时值
    if (timeout_read) bufev->timeout_read = *timeout_read;
    else evutil_timerclear(&bufev->timeout_read);
    
    if (timeout_write) bufev->timeout_write = *timeout_write;
    else evutil_timerclear(&bufev->timeout_write);
    
    // 通知实现层调整事件
    bufev->be_ops->adj_timeouts(bufev);
}
```

### 7.3 超时触发

```c
// 在读回调中
if (event == EV_TIMEOUT) {
    what |= BEV_EVENT_TIMEOUT;
    goto error;  // 触发 errorcb
}
```

### 7.4 超时重置

每次成功读写后，自动重置超时计时器：

```c
#define BEV_RESET_GENERIC_READ_TIMEOUT(bev) \
    do { \
        if (evutil_timerisset(&(bev)->timeout_read)) \
            event_add(&(bev)->ev_read, &(bev)->timeout_read); \
    } while (0)
```

**含义**：如果在 `timeout_read` 时间内没有任何数据到达，触发超时。每次有数据到达，重新计时。

---

## 八、回调触发机制

### 8.1 三种回调

```c
typedef void (*bufferevent_data_cb)(struct bufferevent *bev, void *ctx);
typedef void (*bufferevent_event_cb)(struct bufferevent *bev, short what, void *ctx);

struct bufferevent {
    bufferevent_data_cb readcb;    // 数据可读（input >= wm_read.low）
    bufferevent_data_cb writecb;   // 数据已写（output <= wm_write.low）
    bufferevent_event_cb errorcb;  // 事件（EOF/ERROR/TIMEOUT/CONNECTED）
};
```

### 8.2 直接触发 vs 延迟触发

**直接触发**（默认）：
```c
bufferevent_trigger_nolock_(bev, EV_READ, 0);
// 直接调用：bev->readcb(bev, bev->cbarg);
```

**延迟触发**（`BEV_OPT_DEFER_CALLBACKS`）：
```c
bufferevent_trigger_nolock_(bev, EV_READ, BEV_OPT_DEFER_CALLBACKS);
// 标记 pending，调度 deferred callback
p->readcb_pending = 1;
SCHEDULE_DEFERRED(p);  // 在 event_base_loop 的下一次迭代中执行
```

**延迟回调执行**：
```c
static void bufferevent_run_deferred_callbacks_locked(...)
{
    // 按固定顺序执行：connected → readcb → writecb → errorcb
    
    if (eventcb_pending & BEV_EVENT_CONNECTED)
        errorcb(bev, BEV_EVENT_CONNECTED, cbarg);
    
    if (readcb_pending)
        readcb(bev, cbarg);
    
    if (writecb_pending)
        writecb(bev, cbarg);
    
    if (eventcb_pending)
        errorcb(bev, eventcb_pending, cbarg);
}
```

**延迟触发的好处**：
- 避免在 epoll 回调中执行大量用户代码，减少事件循环阻塞
- 多个事件合并为一次回调执行
- 配合 `BEV_OPT_UNLOCK_CALLBACKS` 可在回调中释放锁，避免死锁

### 8.3 触发条件判断

```c
static inline void bufferevent_trigger_nolock_(struct bufferevent *bufev,
    short iotype, int options)
{
    // 读触发条件：input 长度 >= 低水位线（或忽略水位线）
    if ((iotype & EV_READ) && 
        ((options & BEV_TRIG_IGNORE_WATERMARKS) ||
         evbuffer_get_length(bufev->input) >= bufev->wm_read.low))
        bufferevent_run_readcb_(bufev, options);
    
    // 写触发条件：output 长度 <= 低水位线（或忽略水位线）
    if ((iotype & EV_WRITE) &&
        ((options & BEV_TRIG_IGNORE_WATERMARKS) ||
         evbuffer_get_length(bufev->output) <= bufev->wm_write.low))
        bufferevent_run_writecb_(bufev, options);
}
```

---

## 九、挂起（Suspend）机制

### 9.1 挂起原因（位图）

```c
#define BEV_SUSPEND_WM          0x01  // 水位线限制
#define BEV_SUSPEND_BW          0x02  // 带宽限制（单 bev）
#define BEV_SUSPEND_BW_GROUP    0x04  // 带宽限制（组）
#define BEV_SUSPEND_LOOKUP      0x08  // DNS 解析中
#define BEV_SUSPEND_FILT_READ   0x10  // Filter 暂停读
```

### 9.2 挂起与恢复

```c
void bufferevent_suspend_read_(struct bufferevent *bufev, bufferevent_suspend_flags what)
{
    struct bufferevent_private *p = BEV_UPCAST(bufev);
    
    // 如果之前未挂起，先禁用底层读事件
    if (!p->read_suspended)
        bufev->be_ops->disable(bufev, EV_READ);
    
    // 标记挂起原因
    p->read_suspended |= what;
}

void bufferevent_unsuspend_read_(struct bufferevent *bufev, bufferevent_suspend_flags what)
{
    struct bufferevent_private *p = BEV_UPCAST(bufev);
    
    // 清除挂起原因
    p->read_suspended &= ~what;
    
    // 所有原因都清除了，且用户启用了读，恢复底层读事件
    if (!p->read_suspended && (bufev->enabled & EV_READ))
        bufev->be_ops->enable(bufev, EV_READ);
}
```

**使用场景**：
- **高水位线**：input buffer 太满，暂停读直到用户消费数据
- **限速**：令牌桶空了，暂停读/写直到令牌补充
- **DNS 解析**：异步解析 hostname 时暂停读写

### 9.3 Enable/Disable 与 Suspend 的关系

```
用户调用 bufferevent_enable(bev, EV_READ)
    │
    ├── bufev->enabled |= EV_READ        // 标记用户想要读
    │
    └── 如果 !read_suspended              // 没有被挂起
            └── bev->be_ops->enable()     // 真正注册 epoll 读事件

用户调用 bufferevent_disable(bev, EV_READ)
    │
    ├── bufev->enabled &= ~EV_READ       // 标记用户不想要读
    │
    └── bev->be_ops->disable()           // 注销 epoll 读事件
```

**关键区别**：
- `enabled`：用户的**意愿**
- `suspended`：系统的**限制**
- 只有两者都允许时，底层事件才真正注册

---

## 十、Bufferevent 类型

### 10.1 Socket Bufferevent（最常用）

```c
struct bufferevent *bev = bufferevent_socket_new(base, fd, options);
bufferevent_setcb(bev, readcb, writecb, eventcb, arg);
bufferevent_enable(bev, EV_READ|EV_WRITE);
```

- 基于 socket fd
- 支持 connect/accept
- 支持 `bufferevent_socket_connect_hostname()`（异步 DNS + 连接）

### 10.2 Paired Bufferevent（管道）

```c
struct bufferevent *pair[2];
bufferevent_pair_new(base, options, pair);
// pair[0] 写入的数据 pair[1] 可以读取，反之亦然
```

- 两个 bufferevent 互相连接
- 不经过 socket，内存中直接传递
- 用于线程间通信、测试

### 10.3 Filter Bufferevent（数据转换）

```c
struct bufferevent *bev_filter = bufferevent_filter_new(
    underlying_bev,
    input_filter,   // 对 input 数据做转换
    output_filter,  // 对 output 数据做转换
    options, freed_cb, arg);
```

- 在底层 bufferevent 之上添加数据转换层
- 用途：压缩/解压、加密/解密、协议编解码

### 10.4 SSL Bufferevent（TLS 加密）

```c
struct bufferevent *bev_ssl = bufferevent_openssl_socket_new(
    base, fd, ssl, BUFFEREVENT_SSL_CONNECTING, options);
```

- 透明 SSL/TLS 加密
- 自动处理握手、重协商
- 对上层代码完全透明（仍是 read/write cb 模型）

---

## 十一、完整调用链

### 11.1 创建与连接

```
用户代码
    │
    ├── bufferevent_socket_new(base, -1, BEV_OPT_CLOSE_ON_FREE)
    │       ├── mm_calloc(bufev_private)
    │       ├── bufferevent_init_common_()
    │       │       ├── evbuffer_new(input)
    │       │       ├── evbuffer_new(output)
    │       │       ├── bev->enabled = EV_WRITE
    │       │       └── event_deferred_cb_init(deferred)
    │       ├── event_assign(ev_read, base, fd, EV_READ|EV_PERSIST, readcb, bev)
    │       ├── event_assign(ev_write, base, fd, EV_WRITE|EV_PERSIST, writecb, bev)
    │       └── evbuffer_add_cb(output, outbuf_cb, bev)
    │
    ├── bufferevent_setcb(bev, readcb, writecb, eventcb, arg)
    │
    ├── bufferevent_socket_connect(bev, sa, socklen)
    │       ├── fd = evutil_socket_(AF_INET, SOCK_STREAM|NONBLOCK, 0)
    │       ├── evutil_socket_connect_(&fd, sa, socklen)
    │       ├── bufferevent_setfd(bev, fd)
    │       └── be_socket_enable(bev, EV_WRITE)  // 监听可写（连接完成）
    │               └── event_add(&ev_write, NULL)
    │
    └── bufferevent_enable(bev, EV_READ)
            └── be_socket_enable(bev, EV_READ)
                    └── event_add(&ev_read, NULL)
```

### 11.2 读数据完整流程

```
Socket 收到数据
    │
    ▼
epoll_wait 返回（fd 可读）
    │
    ▼
ev_read 事件触发（event_active → activequeues）
    │
    ▼
event_process_active_single_queue()
    │
    ▼
bufferevent_readcb(fd, EV_READ, bev)
    │
    ├── 检查是否超时（event == EV_TIMEOUT?）
    ├── 计算 howmuch = min(wm_read.high - input.len, max_single_read)
    │
    ├── evbuffer_read(input, fd, howmuch)
    │       └── 循环 recv() 直到 EAGAIN
    │           数据被追加到 input buffer
    │
    ├── input buffer 回调触发
    │       └── bufferevent_inbuf_wm_cb()
    │           └── input.len >= wm_read.high?
    │               └── bufferevent_wm_suspend_read()  // 暂停读
    │
    └── bufferevent_trigger_nolock_(bev, EV_READ, 0)
            │
            ├── input.len >= wm_read.low?
            │       └── bufferevent_run_readcb_(bev, 0)
            │               ├── BEV_OPT_DEFER_CALLBACKS?
            │               │       ├── readcb_pending = 1
            │               │       └── SCHEDULE_DEFERRED()  // 延迟执行
            │               └── 否
            │                       └── bev->readcb(bev, cbarg)  // 立即执行
            │
            └── 用户回调中：bufferevent_read(bev, buf, size)
                        └── evbuffer_remove(input, buf, size)
                            │
                            └── input 长度下降
                                └── bufferevent_inbuf_wm_cb()
                                    └── input.len < wm_read.high?
                                        └── bufferevent_wm_unsuspend_read()  // 恢复读
```

### 11.3 写数据完整流程

```
用户代码
    │
    └── bufferevent_write(bev, data, size)
            └── evbuffer_add(output, data, size)
                │
                └── output buffer 数据增加
                    │
                    └── evbuffer 回调：bufferevent_socket_outbuf_cb
                            │
                            ├── cbinfo->n_added > 0?
                            ├── bev->enabled & EV_WRITE?
                            └── !write_suspended?
                                │
                                └── bufferevent_add_event_(&ev_write, timeout)
                                        └── event_add(&ev_write, timeout)
                                            注册 socket 可写监听

Socket 可写
    │
    ▼
ev_write 事件触发
    │
    ▼
bufferevent_writecb(fd, EV_WRITE, bev)
    │
    ├── 检查超时
    ├── 处理连接完成（connecting? BEV_EVENT_CONNECTED）
    ├── atmost = bufferevent_get_write_max_(bev_p)  // 限速
    │
    ├── evbuffer_write_atmost(output, fd, atmost)
    │       └── 循环 send() 直到 EAGAIN 或 buffer 空
    │           数据从 output 发送到 socket
    │
    ├── 如果 output.len == 0
    │       └── event_del(&ev_write)  // 停止监听可写
    │
    └── bufferevent_trigger_nolock_(bev, EV_WRITE, 0)
            │
            └── output.len <= wm_write.low?
                    └── bufferevent_run_writecb_(bev, 0)
                            └── bev->writecb(bev, cbarg)
```

### 11.4 关闭与释放

```
用户代码
    │
    ├── bufferevent_free(bev)
    │       └── bufferevent_decref_and_unlock_(bev)
    │               └── refcnt-- == 0?
    │                       └── bufferevent_finalize_cb_()
    │                               ├── bev->be_ops->unlink(bev)
    │                               ├── bev->be_ops->destruct(bev)
    │                               │       └── be_socket_destruct()
    │                               │               ├── event_del(&ev_read)
    │                               │               ├── event_del(&ev_write)
    │                               │               └── if (BEV_OPT_CLOSE_ON_FREE)
    │                               │                       close(fd)
    │                               ├── evbuffer_free(input)
    │                               ├── evbuffer_free(output)
    │                               └── mm_free(bufev_p)
    │
    └── event_base_loop 结束
```

---

## 十二、关键设计要点

### 12.1 引用计数

```c
bufferevent_incref_(bev);   // 增加引用（如调度延迟回调时）
bufferevent_decref_(bev);   // 减少引用，到 0 时释放
```

**为什么需要引用计数？**
- 延迟回调可能在 `bufferevent_free()` 之后执行
- `bufferevent_free()` 只是减少引用计数，不一定立即释放
- 确保所有 pending 回调执行完才真正释放内存

### 12.2 线程安全

```c
// 创建时启用线程安全
struct bufferevent *bev = bufferevent_socket_new(base, fd, BEV_OPT_THREADSAFE);

// 内部自动加锁
#define BEV_LOCK(b)   EVLOCK_LOCK(BEV_UPCAST(b)->lock, 0)
#define BEV_UNLOCK(b) EVLOCK_UNLOCK(BEV_UPCAST(b)->lock, 0)
```

**加锁范围**：
- 几乎所有公共 API 内部都会 `BEV_LOCK/BEV_UNLOCK`
- 回调执行时可以选择持有锁（默认）或释放锁（`BEV_OPT_UNLOCK_CALLBACKS`）

### 12.3 冻结机制（Freeze）

```c
evbuffer_freeze(bufev->input, 0);   // 禁止从头部删除（用户不能删 input）
evbuffer_freeze(bufev->output, 1);  // 禁止从尾部删除（用户不能删 output）
```

**作用**：
- `input`：用户只能 `drain`（读走数据），libevent 只能 `add`（添加数据）
- `output`：用户只能 `add`（写入数据），libevent 只能 `drain`（发送数据）
- 防止数据流向混乱

### 12.4 零拷贝感

```c
// 用户写入
bufferevent_write(bev, data, size);        // 数据拷贝到 output buffer

// 用户发送另一个 evbuffer 的所有内容
bufferevent_write_buffer(bev, other_buf);  // 可能零拷贝（转移 chain）

// 用户读取
bufferevent_read(bev, buf, size);          // 从 input buffer 拷贝到 buf

// 用户转移 input 到另一个 evbuffer
bufferevent_read_buffer(bev, other_buf);   // 可能零拷贝（转移 chain）
```

`evbuffer` 内部的 chain 引用计数机制使得 `add_buffer` 可以在不拷贝数据的情况下转移整个缓冲区。

### 12.5 错误处理

```c
#define BEV_EVENT_READING    0x01   // 读路径出错
#define BEV_EVENT_WRITING    0x02   // 写路径出错
#define BEV_EVENT_EOF        0x10   // 对端关闭（read 返回 0）
#define BEV_EVENT_ERROR      0x20   // 系统错误（errno）
#define BEV_EVENT_TIMEOUT    0x40   // 超时
#define BEV_EVENT_CONNECTED  0x80   // 连接成功
```

**组合示例**：
- `BEV_EVENT_READING | BEV_EVENT_EOF`：读时遇到对端关闭
- `BEV_EVENT_WRITING | BEV_EVENT_ERROR`：写时系统错误
- `BEV_EVENT_READING | BEV_EVENT_TIMEOUT`：读超时

### 12.6 Connect 状态机

```c
// 发起连接
bufferevent_socket_connect(bev, sa, len)
    └── 非阻塞 connect() 返回 EINPROGRESS
        └── ev_write 监听可写（连接完成信号）
            │
            └── bufferevent_writecb()
                    ├── evutil_socket_finished_connecting_(fd)
                    │       └── getsockopt(SO_ERROR) 检查连接结果
                    ├── c > 0：连接成功
                    │       └── eventcb(bev, BEV_EVENT_CONNECTED)
                    ├── c < 0：连接失败
                    │       └── eventcb(bev, BEV_EVENT_ERROR)
                    └── c == 0：仍在连接中（通常不会发生）
```

### 12.7 与 evbuffer 的关系

```
┌──────────────┐      ┌──────────────┐
│  bufferevent  │      │   evbuffer   │
│              │─────►│              │
│   input      │◄─────│   chains     │
│   output     │◄────►│   callbacks  │
│   readcb     │      │   freeze     │
│   writecb    │      └──────────────┘
└──────────────┘
```

- bufferevent 是 **业务层** 抽象（连接、事件、回调）
- evbuffer 是 **数据层** 抽象（内存链、引用计数、零拷贝）
- bufferevent 内部使用 evbuffer 管理数据，但暴露更高级的接口

---

## 十三、总结

Libevent 的 bufferevent 是一个**精心设计的分层 IO 抽象**：

1. **数据层**：`evbuffer` 负责高效内存管理（chain、引用计数、零拷贝）
2. **事件层**：`event` 负责底层 socket 事件监听（可读、可写、超时）
3. **业务层**：`bufferevent` 将两者结合，提供**"写 output、读 input"**的简单模型

**核心设计亮点**：
- **自动读写**：用户无需处理 `EAGAIN`，bufferevent 自动重试
- **水位线控制**：防止内存无限增长，支持背压（backpressure）
- **延迟回调**：避免事件循环阻塞，支持多事件合并
- **挂起机制**：多种挂起原因共存（水位线、限速、DNS），位图管理
- **类型多态**：通过 `bufferevent_ops` 虚函数表支持 socket、pair、filter、SSL

> **一句话总结**：bufferevent 是 libevent 中最常用的高级 IO 组件，它将 socket、缓冲区、事件监听封装成一个对象，让用户只需关注**"读 input buffer、写 output buffer、处理三个回调"**，底层的非阻塞读写、重试、超时、流量控制全部由框架自动处理。
