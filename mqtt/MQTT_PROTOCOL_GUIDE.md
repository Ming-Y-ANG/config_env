# MQTT 协议详解：原理与工作流程

## 目录

1. [什么是 MQTT](#什么是-mqtt)
2. [核心概念](#核心概念)
3. [MQTT 报文类型](#mqtt-报文类型)
4. [工作流程详解](#工作流程详解)
5. [QoS 服务质量等级](#qos-服务质量等级)
6. [高级特性](#高级特性)
7. [MQTT vs 其他协议](#mqtt-vs-其他协议)
8. [实际应用场景](#实际应用场景)
9. [安全机制](#安全机制)
10. [总结](#总结)

---

## 什么是 MQTT

**MQTT**（Message Queuing Telemetry Transport，消息队列遥测传输）是一种基于**发布/订阅（Publish/Subscribe）**模式的轻量级消息传输协议，由 IBM 于 1999 年发布，2014 年成为 OASIS 标准。

### 设计目标

- **轻量高效**：协议头部最小仅 2 字节，适合带宽受限、网络不稳定的场景
- **低功耗**：保持长连接但开销极小，适合电池供电设备
- **不可靠网络友好**：内置重连、断线恢复、消息重传机制
- **异步通信**：发送方和接收方无需同时在线

### 版本演进

| 版本 | 年份 | 关键特性 |
|------|------|---------|
| MQTT 3.1 | 2010 | 基础发布/订阅 |
| MQTT 3.1.1 | 2014 | OASIS 标准，最广泛使用的版本 |
| MQTT 5.0 | 2019 | 新增用户属性、共享订阅、消息过期、主题别名等 |

---

## 核心概念

### 1. 发布/订阅模式（Pub/Sub）

MQTT 采用**发布/订阅**模式，与传统**请求/响应**模式有本质区别：

```
传统 HTTP（请求/响应）：
  客户端 A ──请求──> 服务器 <──请求── 客户端 B
  客户端 A <--响应-- 服务器 --响应--> 客户端 B
  （A 和 B 必须直接知道对方的存在）

MQTT（发布/订阅）：
  发布者 A ──发布(msg)──> Broker（消息中介）<──订阅── 订阅者 B
  发布者 C ──发布(msg)──> Broker（消息中介）<──订阅── 订阅者 D
  （A 不知道 B 的存在，只关心 Topic）
```

**核心优势**：
- **解耦**：发布者和订阅者互不认识，通过 Broker 间接通信
- **一对多**：一条消息可被多个订阅者接收
- **灵活扩展**：新增客户端不影响现有架构

### 2. 角色定义

#### Broker（消息代理/服务器）

- 接收所有客户端连接
- 接收发布者发来的消息
- 根据 Topic 将消息转发给匹配的订阅者
- 管理客户端会话、订阅关系、保留消息
- **Mosquitto、EMQX、HiveMQ、AWS IoT Core** 都是 Broker 实现

#### Publisher（发布者）

- 向指定 Topic 发送消息
- 不需要知道谁在订阅
- 发送后通常不等待响应（QoS 0）或等待确认（QoS 1/2）

#### Subscriber（订阅者）

- 向 Broker 订阅感兴趣的 Topic
- 接收匹配 Topic 的消息
- 可以订阅多个 Topic，使用通配符

**注意**：一个客户端可以同时是发布者和订阅者。

### 3. Topic（主题）

Topic 是消息的分类标识，使用层级结构，类似文件路径：

```
sensors/living_room/temperature
sensors/living_room/humidity
sensors/kitchen/temperature
devices/lamp_001/status
system/alerts/critical
```

#### 命名规则

- 使用 UTF-8 字符串
- 层级用 `/` 分隔
- 区分大小写
- 不能以 `/` 开头或结尾（可以但一般不推荐）
- 不能包含 `+` 和 `#`（这两个是通配符）

#### 通配符订阅

| 通配符 | 含义 | 示例 |
|--------|------|------|
| `+` | 匹配单个层级 | `sensors/+/temperature` 匹配 `sensors/living_room/temperature` 和 `sensors/kitchen/temperature` |
| `#` | 匹配零个或多个层级（只能在末尾） | `sensors/living_room/#` 匹配该房间下所有传感器 |

**示例**：
```
sensors/+/temperature    → 匹配所有房间的温度
sensors/kitchen/#        → 匹配厨房所有传感器
#                        → 匹配所有消息（慎用）
```

---

## MQTT 报文类型

MQTT 协议定义了 15 种报文（Packet），每种都有特定功能：

| 报文类型 | 方向 | 作用 |
|---------|------|------|
| **CONNECT** | Client → Broker | 请求建立连接 |
| **CONNACK** | Broker → Client | 连接确认 |
| **PUBLISH** | 双向 | 发布消息 |
| **PUBACK** | 双向 | QoS 1 发布确认 |
| **PUBREC** | 双向 | QoS 2 收到发布（第一步） |
| **PUBREL** | 双向 | QoS 2 释放发布（第二步） |
| **PUBCOMP** | 双向 | QoS 2 完成发布（第三步） |
| **SUBSCRIBE** | Client → Broker | 订阅请求 |
| **SUBACK** | Broker → Client | 订阅确认 |
| **UNSUBSCRIBE** | Client → Broker | 取消订阅 |
| **UNSUBACK** | Broker → Client | 取消订阅确认 |
| **PINGREQ** | Client → Broker | 心跳请求 |
| **PINGRESP** | Broker → Client | 心跳响应 |
| **DISCONNECT** | Client → Broker | 断开连接 |
| **AUTH** | 双向 | MQTT 5.0 认证交换 |

### 报文结构

每个 MQTT 报文由**固定报头（Fixed Header）+ 可变报头（Variable Header）+ 有效载荷（Payload）**组成：

```
+--------+--------+--------+--------+
| 固定报头 | 可变报头 |  有效载荷  |
+--------+--------+--------+--------+
  2-5字节    不定长      不定长
```

**固定报头**包含：
- 报文类型（4 bits）
- 标志位（4 bits，如 QoS、Retain、DUP）
- 剩余长度（1-4 字节，变长编码）

---

## 工作流程详解

### 阶段 1：建立连接（CONNECT / CONNACK）

```
客户端                                              Broker
   |                                                   |
   |  CONNECT                                          |
   |  ├── client_id: "sensor_001"                      |
   |  ├── clean_session: true                          |
   |  ├── keep_alive: 60                               |
   |  ├── username: "user"                             |
   |  ├── password: "pass"                             |
   |  ├── will_topic: "system/alerts"                  |
   |  ├── will_message: "sensor_001 offline"           |
   |  └── will_qos: 1                                  |
   |-------------------------------------------------->|
   |                                                   |
   |                                          CONNACK  |
   |                                          ├── session_present: false
   |                                          └── reason_code: 0 (Success)
   |<--------------------------------------------------|
   |                                                   |
```

#### CONNECT 报文关键字段

| 字段 | 说明 |
|------|------|
| `client_id` | 客户端唯一标识，Broker 用它来识别客户端 |
| `clean_session` | `true` = 清除之前的会话；`false` = 恢复会话 |
| `keep_alive` | 心跳间隔（秒），0 表示禁用 |
| `username/password` | 认证凭据 |
| `will_topic/message/qos/retain` | 遗嘱消息：客户端异常断开时，Broker 自动发布 |

#### 连接结果码（CONNACK）

| 代码 | 含义 |
|------|------|
| 0 | 连接成功 |
| 1 | 协议版本错误 |
| 2 | 无效的 Client ID |
| 3 | 服务器不可用 |
| 4 | 用户名或密码错误 |
| 5 | 未授权 |

### 阶段 2：订阅主题（SUBSCRIBE / SUBACK）

```
客户端                                              Broker
   |                                                   |
   |  SUBSCRIBE                                        |
   |  ├── topic: "sensors/+/temperature"               |
   |  └── qos: 1                                       |
   |-------------------------------------------------->|
   |                                                   |
   |                                          SUBACK   |
   |                                          └── granted_qos: [1]
   |<--------------------------------------------------|
   |                                                   |
```

客户端可以一次订阅多个 Topic，每个 Topic 指定自己的 QoS。

### 阶段 3：发布消息（PUBLISH）

```
发布者                                              Broker                                              订阅者
   |                                                   |                                                   |
   |  PUBLISH                                          |                                                   |
   |  ├── topic: "sensors/living_room/temperature"     |                                                   |
   |  ├── payload: "24.5"                              |                                                   |
   |  ├── qos: 1                                       |                                                   |
   |  └── retain: false                                |                                                   |
   |-------------------------------------------------->|                                                   |
   |                                                   |  PUBLISH                                          |
   |                                                   |  ├── topic: "sensors/living_room/temperature"     |
   |                                                   |  ├── payload: "24.5"                              |
   |                                                   |  └── qos: 1 (max of pub_qos and sub_qos)          |
   |                                                   |-------------------------------------------------->|
   |  PUBACK                                           |                                                   |
   |<--------------------------------------------------|  PUBACK                                           |
   |                                                   |<--------------------------------------------------|
```

**关键规则**：
- 实际使用的 QoS = `min(发布者 QoS, 订阅者 QoS)`
- 如果订阅者 QoS 为 0，即使发布者发 QoS 1，订阅者也只按 QoS 0 接收

### 阶段 4：心跳保活（PINGREQ / PINGRESP）

```
客户端                                              Broker
   |                                                   |
   |  PINGREQ                                          |
   |-------------------------------------------------->|
   |  PINGRESP                                         |
   |<--------------------------------------------------|
   |                                                   |
   (每隔 keep_alive 秒发送一次)
```

如果在 `1.5 * keep_alive` 秒内 Broker 没收到任何报文（包括 PINGREQ），就认为客户端**已断开**，触发遗嘱消息。

### 阶段 5：断开连接（DISCONNECT）

```
客户端                                              Broker
   |                                                   |
   |  DISCONNECT                                       |
   |-------------------------------------------------->|
   |                                                   |
```

**正常断开**：发送 DISCONNECT，Broker **不发布**遗嘱消息。

**异常断开**（网络故障、客户端崩溃、超时）：Broker 检测到后，**发布遗嘱消息**。

---

## QoS 服务质量等级

QoS（Quality of Service）定义了消息传递的可靠性保障，分 3 个级别：

### QoS 0 — 最多一次（At Most Once）

```
发布者        Broker        订阅者
   |            |             |
   |  PUBLISH   |             |
   |----------->|  PUBLISH    |
   |            |------------>|
   |            |             |
```

- **特点**：发完就忘，无确认
- **开销**：最低（仅 1 个报文）
- **场景**：高频 telemetry、传感器数据、日志采集
- **风险**：消息可能丢失（网络故障时）

### QoS 1 — 至少一次（At Least Once）

```
发布者        Broker        订阅者
   |            |             |
   |  PUBLISH   |             |
   |----------->|  PUBLISH    |
   |            |------------>|
   |  PUBACK    |  PUBACK     |
   |<-----------|<------------|
   |            |             |
```

- **特点**：保证送达，但可能重复
- **开销**：中等（2 个报文）
- **场景**：命令下发、状态更新、需要可靠但可容忍重复的场景
- **去重**：应用层需要处理重复消息（如通过消息 ID）

**注意**：如果 PUBACK 丢失，发布者会重发 PUBLISH，导致 Broker 收到重复消息并转发给订阅者。

### QoS 2 — 恰好一次（Exactly Once）

```
发布者        Broker        订阅者
   |            |             |
   |  PUBLISH   |             |
   |----------->|  PUBLISH    |
   |  PUBREC    |------------>|
   |<-----------|  PUBREC     |
   |  PUBREL    |<------------|
   |----------->|  PUBREL     |
   |  PUBCOMP   |------------>|
   |<-----------|  PUBCOMP    |
   |            |<------------|
   |            |             |
```

**四步握手**：
1. **PUBLISH**：发布者发送消息
2. **PUBREC**：Broker 收到，回执收到（Recipient Received）
3. **PUBREL**：发布者释放消息（Release），Broker 可以分发
4. **PUBCOMP**：Broker 完成处理（Complete）

- **特点**：保证不丢失、不重复
- **开销**：最高（4 个报文）
- **场景**：支付、关键指令、金融交易

### QoS 选择建议

| 场景 | 推荐 QoS | 原因 |
|------|---------|------|
| 温度传感器（每秒上报） | 0 | 丢几条不影响，追求低延迟低功耗 |
| 设备开关命令 | 1 | 命令必须到达，重复执行无害 |
| 门锁控制 | 2 | 必须精确执行一次，不能重复开锁 |
| 固件升级通知 | 1 | 需要可靠到达，重复通知无害 |

---

## 高级特性

### 1. 保留消息（Retained Message）

```
发布者 -> Broker: PUBLISH topic="room/temp", payload="25", retain=true

新订阅者 -> Broker: SUBSCRIBE topic="room/temp"
Broker -> 新订阅者: PUBLISH payload="25" (立即收到最后一条保留消息)
```

- 每个 Topic **只保留最后一条** retain=true 的消息
- 新订阅者加入时**立即收到**保留消息（即使消息是很久以前发布的）
- 常用于设备状态、配置信息（"当前温度是多少？"）
- 清空保留消息：发送该 Topic 的空 payload + retain=true

### 2. 遗嘱消息（Last Will and Testament, LWT）

```
连接时设置：
  will_topic = "system/status"
  will_message = "device_001 offline"
  will_qos = 1
  will_retain = true

正常断开：发送 DISCONNECT → 不触发遗嘱
异常断开：网络中断、崩溃、超时 → Broker 自动发布遗嘱
```

- 让其他客户端知道某个设备"掉线了"
- 常用于设备在线状态监控

### 3. 会话保持（Clean Session = false）

```
第一次连接（clean_session=false）：
  Client: CONNECT(client_id="dev1", clean_session=false)
  Broker: CONNACK(session_present=false)
  Client: SUBSCRIBE(topic="cmd/dev1", qos=1)
  Client: (网络断开)

重新连接（clean_session=false）：
  Client: CONNECT(client_id="dev1", clean_session=false)
  Broker: CONNACK(session_present=true)  ← 恢复会话！
  Broker: → 自动重发断开期间未送达的 QoS 1/2 消息
```

- Broker 保存：订阅列表、未确认的 QoS 1/2 消息
- 客户端断线重连后，**自动恢复**之前的状态
- MQTT 5.0 中细分为 `Clean Start` + `Session Expiry Interval`

### 4. MQTT 5.0 新特性

| 特性 | 说明 |
|------|------|
| **用户属性（User Properties）** | 自定义键值对，随报文传输，类似 HTTP Header |
| **消息过期（Message Expiry）** | 消息在 Broker 上保留的最长时间，过期丢弃 |
| **主题别名（Topic Alias）** | 用 2 字节数字代替长 Topic 名，减少传输开销 |
| **共享订阅（Shared Subscription）** | 多个客户端共享一个订阅，负载均衡 |
| **流量控制（Flow Control）** | 客户端可限制接收速率 |
| **reason code** | 更详细的错误信息 |

---

## MQTT vs 其他协议

### MQTT vs HTTP

| 特性 | MQTT | HTTP |
|------|------|------|
| 模式 | 发布/订阅 | 请求/响应 |
| 连接 | 长连接（TCP） | 短连接（每次请求新建） |
| 头部开销 | 2-5 字节 | 数百字节 |
| 实时性 | 推送（即时） | 轮询（延迟） |
| 双向通信 | 原生支持 | 需要 WebSocket 或长轮询 |
| 一对多 | 原生支持 | 需自行实现 |
| 适用场景 | IoT、消息推送 | REST API、网页浏览 |

### MQTT vs CoAP

| 特性 | MQTT | CoAP |
|------|------|------|
| 传输层 | TCP | UDP |
| 可靠性 | 内置 QoS | 需应用层实现 |
| 开销 | 极低 | 极低 |
| 适用场景 | 稳定网络、需要可靠传输 | 受限网络、UDP 环境 |

### MQTT vs WebSocket

WebSocket = TCP 字节流 + 轻量级帧封装 + 全双工消息语义，本质上是跑在 TCP 上的应用层协议。

实际中常组合使用：**MQTT over WebSocket**（浏览器客户端通过 WS 连接 MQTT Broker）。

---

## 实际应用场景

### 1. 智能家居

```
温度传感器 ──MQTT──> Broker <──MQTT── 手机 App
     ↑                                    |
     └────────  自动调节空调  ──────────────┘
```

- 传感器定期发布 `home/living_room/temperature`
- App 订阅显示当前温度
- 规则引擎订阅后自动触发空调

### 2. 工业物联网（IIoT）

```
PLC 设备 ──MQTT──> 边缘网关 ──MQTT──> 云端 Broker
   ↑                                      |
   └──────  远程控制指令  <────────────────┘
```

- 设备上报运行状态、故障告警
- 云端下发配置更新、控制指令
- 利用 QoS 1/2 确保指令可靠到达

### 3. 即时消息/通知推送

```
App 服务器 ──MQTT──> Broker <──MQTT── 用户手机
                         ↑
                    多设备同步
```

- 比传统轮询更省电、更实时
- 微信、Facebook Messenger 早期曾用 MQTT

### 4. 车联网

```
车载终端 ──MQTT──> 云平台
     ↑
   实时位置、油耗、故障码
```

- 高移动性、弱网络环境下保持连接
- 遗嘱消息标记车辆"失联"

---

## 安全机制

### 1. 传输层安全（TLS/SSL）

```
客户端 <--TLS 加密隧道--> Broker
```

- 防止窃听、篡改、中间人攻击
- 端口 8883（MQTT over TLS）
- 端口 443（MQTT over WebSocket over TLS）

### 2. 认证机制

| 方式 | 说明 |
|------|------|
| **用户名/密码** | CONNECT 报文中携带 |
| **TLS 客户端证书** | 双向认证，安全性最高 |
| **Token/JWT** | MQTT 5.0 增强认证支持 |

### 3. 授权（ACL）

Broker 通过访问控制列表限制客户端权限：

```
user sensor_001
  topic read sensors/+/temperature
  topic write sensors/living_room/temperature

deny user anonymous
  topic #
```

### 4. 最佳实践

- 始终使用 TLS（生产环境）
- 使用强密码或客户端证书
- 限制客户端权限（最小权限原则）
- 启用 Broker 的日志和监控
- 定期更换凭据

---

## 总结

### MQTT 的核心设计哲学

1. **简单**：协议精简，实现成本低
2. **轻量**：头部极小，适合资源受限设备
3. **可靠**：内置 QoS、会话保持、遗嘱机制
4. **灵活**：发布/订阅模式天然支持一对多、多对多

### 学习路径建议

1. **理解 Pub/Sub 模式** — 与 HTTP 请求/响应对比
2. **掌握 Topic 层级和通配符** — 设计合理的主题结构
3. **理解 QoS 三种级别** — 根据场景选择合适的可靠性
4. **实践保留消息和遗嘱** — 处理设备状态
5. **学习会话保持** — 处理断线重连
6. **了解 MQTT 5.0 新特性** — 现代 MQTT 开发必备

### 一句话概括

> **MQTT 是一个轻量级的、基于发布/订阅模式的、专为不可靠网络设计的消息协议，通过 Broker 实现发布者和订阅者的解耦，并通过 QoS 机制提供分级可靠性保障。**
