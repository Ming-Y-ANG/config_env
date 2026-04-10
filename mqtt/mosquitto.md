## 1. MQTT介绍

1. 由IBM在90年代开发，主要有以下特点：

   - 服务器拥有高并发，能够接入大量的终端设备，可以支持长连接(基于TCP)，具有一定的实时性

   - 单次传输数据量小，传输不能出错

   - 能够适应网络环境不稳定的场景，如高延迟，网络间歇性中断等

   - 使用发布/订阅的消息模式，提供一对多的消息发布

   - 根据数据的重要程度和特性，设置不同等级的服务质量（session），有三种服务质量：

     - QoS0 - 最多一次，消息发布完全依赖于底层的TCP/IP网络，可能会出现消息丢失和重复的情况，主要应用于对消息要求不高的场景

     - QoS1 - 至少一次，保证消息到达，但可能会出现重复

     - QoS2 - 只有一次，确保消息只到达一次，不允许消息重复和丢失，适用于一些计费场景

2. 框架组成，服务器和客户端：

   - MQTT服务器/代理(broker)，能够存储转发数据

   - 消息的发布方，同时也能够订阅消息 - 客户端

   - 消息的订阅方，同时也能够发布消息 - 客户端

     ![image-20210915162751666](C:\Users\inhand\AppData\Roaming\Typora\typora-user-images\image-20210915162751666.png)

3. MQTT主题模式：
   - MQTT通过主题对消息进行分类
   - 主题的本质就是一个UTF-8的字符串
   - 主题可以通过反斜杠体现层级关系
   - 主题不需要创建，可以直接使用
   - 主题还可以通过通配符进行过滤，过滤主要用于消息的订阅
     - +号可以过滤一个层级
     - *号只能出现在主题的最后，表示过滤任意级别的层级，如：
       - 一个主题为  a/b，  表示 a 目录下的 b 设备
       - +/b  表示任意目录下的b设备
       - a/*  表示a目录下的所有设备

## 2.MQTT协议

1. MQTT属于基于TCP的应用层的协议

2. MQTT报文格式：

   - 固定控制报头
   - 剩余数据长度：
     - 可变长度报头
     - 有效数据载荷
   - 帧格式：

   | 固定控制报头（1 字节） | 剩余数据长度（1~4 字节） | 可变长度数据报头（0~n 字节） | 有效数据载荷（0~n 字节） |
   | :--------------------: | :----------------------: | :--------------------------: | :----------------------: |

   1. **固定控制报头**：

      每个MQTT控制报文都包含一个固定报头

      > - | **Bit** |       **7**       | **6** | **5** | **4** |       **3**       | **2** | **1** | **0** |
      >   | :-----: | :---------------: | :---: | :---: | :---: | :---------------: | :---: | :---: | :---: |
      >   |  byte   | 报文类型 - 4~7 位 |       |       |       | 报文标志 - 0~3 位 |       |       |       |

      - **报文类型定义**：

        |  **名字**   | **值** | **报文流动方向** |              **描述**               |
        | :---------: | :----: | :--------------: | :---------------------------------: |
        |  Reserved   |   0    |       禁止       |                保留                 |
        |   CONNECT   |   1    |  客户端到服务端  |        客户端请求连接服务端         |
        |   CONNACK   |   2    |  服务端到客户端  |            连接报文确认             |
        |   PUBLISH   |   3    |  两个方向都允许  |              发布消息               |
        |   PUBACK    |   4    |  两个方向都允许  |       QoS1  消息发布收到确认        |
        |   PUBREC    |   5    |  两个方向都允许  |     发布收到（保证交付第一步）      |
        |   PUBREL    |   6    |  两个方向都允许  |     发布释放（保证交付第二步）      |
        |   PUBCOMP   |   7    |  两个方向都允许  | QoS2 消息发布完成（保证交互第三步） |
        |  SUBSCRIBE  |   8    |  客户端到服务端  |           客户端订阅请求            |
        |   SUBACK    |   9    |  服务端到客户端  |          订阅请求报文确认           |
        | UNSUBSCRIBE |   10   |  客户端到服务端  |         客户端取消订阅请求          |
        |  UNSUBACK   |   11   |  服务端到客户端  |          取消订阅报文确认           |
        |   PINGREQ   |   12   |  客户端到服务端  |              心跳请求               |
        |  PINGRESP   |   13   |  服务端到客户端  |              心跳响应               |
        | DISCONNECT  |   14   |  客户端到服务端  |           客户端断开连接            |
        |  Reserved   |   15   |       禁止       |                保留                 |

      - **报文标志定义**：

        | **控制报文** |  **固定报头标志**  | **Bit 3** | **Bit 2** | **Bit 1** | **Bit 0** |
        | :----------: | :----------------: | :-------: | :-------: | :-------: | :-------: |
        |   CONNECT    |      Reserved      |     0     |     0     |     0     |     0     |
        |   CONNACK    |      Reserved      |     0     |     0     |     0     |     0     |
        |   PUBLISH    | Used in MQTT 3.1.1 |    DUP    |    QoS    |    QoS    |  RETAIN   |
        |    PUBACK    |      Reserved      |     0     |     0     |     0     |     0     |
        |    PUBREC    |      Reserved      |     0     |     0     |     0     |     0     |
        |    PUBREL    |      Reserved      |     0     |     0     |     1     |     0     |
        |   PUBCOMP    |      Reserved      |     0     |     0     |     0     |     0     |
        |  SUBSCRIBE   |      Reserved      |     0     |     0     |     1     |     0     |
        |    SUBACK    |      Reserved      |     0     |     0     |     0     |     0     |
        | UNSUBSCRIBE  |      Reserved      |     0     |     0     |     1     |     0     |
        |   UNSUBACK   |      Reserved      |     0     |     0     |     0     |     0     |
        |   PINGREQ    |      Reserved      |     0     |     0     |     0     |     0     |
        |   PINGRESP   |      Reserved      |     0     |     0     |     0     |     0     |
        |  DISCONNECT  |      Reserved      |     0     |     0     |     0     |     0     |

        - DUP = 控制报文的重复分发标志
        - QoS = PUBLISH报文的服务质量等级
        - RETAIN = PUBLISH报文的保留标志

        PUBLISH控制报文中的DUP, QoS和RETAIN标志的描述见 手册3.3.1节。

   2. **剩余数据长度**：

      剩余长度（Remaining Length）表示当前报文剩余部分的字节数，包括可变报头和负载的数据。剩余长度**不包括用于编码剩余长度字段本身的字节数**

      剩余长度字段使用一个变长度编码方案，对小于128的值它使用单字节编码，更大的值按下面的方式处理：

      ​		低7位有效位用于编码数据，最高有效位用于指示是否有更多的字节，因此每个字节可以编码128个数值和一个*延续位（continuation bit）*。剩余长度字段最大4个字节，最小为1字节。

      > **注**：
      >
      > **剩余长度的计数方法可理解为128进制的计数方法（满128进1）**，编码采用的是**大端字节序列**，十进制数64，不到128，0x40能就够表示，十进制数字321(=65+2*128)被编码为两个字节，第一个字节为65+128 = 0xC1（低位）, 第二个字节为0x02（高位）.

      | **字节数** |            **最小值**            |             **最大值**             |                 表示范围                 |
      | :--------: | :------------------------------: | :--------------------------------: | :--------------------------------------: |
      |     1      |             0 (0x00)             |             127 (0x7F)             |                0 ~ 128 -1                |
      |     2      |         128 (0x80, 0x01)         |         16383 (0xFF, 0x7F)         |             128 ~ 128*128-1              |
      |     3      |     16384 (0x80, 0x80, 0x01)     |     2097151 (0xFF, 0xFF, 0x7F)     |      128 * 128 ~ 128 * 128 *128 -1       |
      |     4      | 2097152 (0x80, 0x80, 0x80, 0x01) | 268435455 (0xFF, 0xFF, 0xFF, 0x7F) | 128 * 128 *128 ~ 128 * 128 *128 * 128 -1 |

   3. **可变长数据报头**：

      某些MQTT控制报文包含一个可变报头部分，它在固定报头和负载之间，内容根据报文类型的不同而不同，主要有以下几个大类：

      - 协议名称
      - 协议级别
      - 连接标志
      - 保活时间
      - 连接标识

      包含报文标识符的控制报文：

      | **控制报文** | **报文标识符字段**  |
      | :----------: | :-----------------: |
      |   CONNECT    |       不需要        |
      |   CONNACK    |       不需要        |
      |   PUBLISH    | 需要（如果QoS > 0） |
      |    PUBACK    |        需要         |
      |    PUBREC    |        需要         |
      |    PUBREL    |        需要         |
      |   PUBCOMP    |        需要         |
      |  SUBSCRIBE   |        需要         |
      |    SUBACK    |        需要         |
      | UNSUBSCRIBE  |        需要         |
      |   UNSUBACK   |        需要         |
      |   PINGREQ    |       不需要        |
      |   PINGRESP   |       不需要        |
      |  DISCONNECT  |       不需要        |

   4. **有效载荷**：

      某些MQTT控制报文在报文的最后部分包含一个有效载荷：

      | **控制报文** | **有效载荷** |
      | :----------: | :----------: |
      |   CONNECT    |     需要     |
      |   CONNACK    |    不需要    |
      |   PUBLISH    |     可选     |
      |    PUBACK    |    不需要    |
      |    PUBREC    |    不需要    |
      |    PUBREL    |    不需要    |
      |   PUBCOMP    |    不需要    |
      |  SUBSCRIBE   |     需要     |
      |    SUBACK    |     需要     |
      | UNSUBSCRIBE  |     需要     |
      |   UNSUBACK   |    不需要    |
      |   PINGREQ    |    不需要    |
      |   PINGRESP   |    不需要    |
      |  DISCONNECT  |    不需要    |



## 3. MQTT通信流程

1. 服务端：
   - 作为发送信息的客户端和请求订阅的客户端的中介，理论上应该是一台服务器
   - 接收来自客户端的网络连接
   - 接收客户端发布的应用消息
   - 处理客户端订阅和取消订阅的请求
   - 转发消息给符合条件的已订阅客户端
2. 客户端：
   - 通过网络连接到服务端，一般为终端设备
   - 发布应用消息给其他的客户端
   - 订阅相关的应用消息
   - 取消订阅，移除接收相关应用消息的请求
   - 从服务器端断开连接
3. 通信流程：
   - QoS0: 通过 PUBLISH 将消息发送给服务端，然后由服务端对消息进行转发，该过程只进行一次，可能会出现信息丢失的情况（最多一次）
   - QoS1: 通过 PUBLISH 将消息发送给服务端，会等待服务端返回一个PUBACK信息，如果未收到应答信息，会重发消息，该过程可能会进行多次，导致服务端收到重复的消息（至少一次  - 应用于一些开关量）
   - QoS2: 通过 PUBLISH 将消息发送给服务端，会等待服务端返回一个PUBREC (消息被记录)应答，客户端收到该应答，会发送一个PUBREL（消息释放），服务端收到该消息后，会返回一个PUBCOMP(发布完成)的应答，共计4次握手（只到达一次，适用于一些计费场景）

## 4.  mosquitto MQTT代理服务器 - ubuntu16.04

- 源码地址：

  ```shell
  git clone https://github.com/eclipse/mosquitto.git
  ```

- 安装依赖：

  ```shell
  git clone https://github.com/DaveGamble/cJSON.git
  cd cJSON/
  mkdir build
  cd build/
  cmake ..
  make
  make install
  
  apt install openssl   # ssl加密
  apt install libssl-dev  #开发所用的头文件和库
  ```

  安装完后，直接在mosquitto目录下执行：

  ```shell
  make
  make install
  ```

- 服务器端 mosquitto.conf 配置文件设置：

  ```shell
  allow_anonymous  false   			# 禁止匿名登陆
  password_file    < file path >  	# 存放用户登录密码配置文件
  
  #指定各种用于加密所用的证书文件存放路径
  #cafile is used to define the path to a file containing the PEM encoded CA certificates that are trusted when checking #incoming client certificates.
  #CA根证书 用于给服务器代理和客户端进行签名
  cafile    < file path >  
  
  #the PEM encoded server certificate. This option and keyfile must be present to enable certificate based TLS encryption.
  #服务器证书 通过CA证书与服务端代理的密钥签名生成
  certfile  < file path >
  
  #the PEM encoded server key. This option and certfile must be present to enable certificate based TLS encryption
  #服务器密钥 通过openSSL生成
  keyfile	  < file path >
  
  #双向认证的配置
  require_certificate  true
  use_identity_as_username true
  ```

- 证书及密钥的生成(注：此处来自于博客还未验证)：

  - 自己生成的证书不被有权威的CA根证书信任，生成自签名CA根证书：

    - 使用des3加密rsa的私钥，生成2048 位密码：

      ```shell
      openssl genrsa -des3 -out ca.key 2048
      ```

    - 用生成的私钥加密，指定有效期为10年，生成 CA 根证书：

      ```shell
      openssl req -new -x509 -days 3650 -key ca.key -out ca.crt  #配置文件的cafile
      ```

  - 用生成的CA根证书签名，生成服务端证书：

    - 生成服务器端的key：

      ```shell
      openssl genrsa -out server.key 2048     #配置文件的keyfile
      ```

    - 生成csr（Certificate signing request，证书签名申请）文件：

      ```shell
      openssl req -new -out server.csr -key server.key
      ```

    - 签名生成服务器证书

      ```shell
      openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650 #配置文件的keyfile
      ```

  - 用生成的CA根证书签名，生成客户端证书：

    - 生成客户端的key：

      ```shell
      openssl genrsa -out client.key 2048
      ```

    - 生成 csr 文件:

      ```shell
      openssl req -new -out client.csr -key client.key
      ```

    - 签名生成客户端证书：

      ```shell
      openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 3650
      ```

      > 注：
      >
      > Can't load /home/xxxx/.rnd into RNG
      >
      > ```shell
      > cd /xxxx
      > openssl rand -writerand .rnd
      > ```

  

- 服务端创建用户：

  ```shell
  mosquitto_passwd [-H sha512 | -H sha512-pbkdf2] [-c] -b passwordfile username password #向存放密码文件写入用户和密码
  ```

- mosquitto安全通信：

  - 应用层：通过用户名和密码验证客户端
  - 传输层：通过SSL/TLS加密（常用openssl），不仅可以实现身份验证，还可以保证数据安全
    - 单向验证： 客户端验证服务端证书，只需要服务端拥有CA证书即可
    - 双向验证：服务器和客户端互相验证，要求双方都拥有证书
  - 网络层：采用VPN专线（成本高，一般不采用）

  
