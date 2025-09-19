#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <time.h>
#include <netdb.h>
#include "rs.h"
#include <sys/time.h>
#include <signal.h>

#define DEBUG 0
#define MAGIC_NUM 0x5A
//#define SERVER_IP "38.55.199.15"
#define SERVER_IP "47.109.150.68"
#define SERVER_PORT 8000
#define BUFFER_SIZE 1500
#define SEQ_MAP_SIZE 8192
#define CONN_TIMEOUT 180  // 3分钟超时
#define GATEWAY_ID 0x01  // 网关唯一标识
#define PKT_OFFSET 8
#define PKG_FEC_ENCODE_MIN_LEN 1200
#define GATEWAY_START 0x80

//FEC RS CODE 
#define FEC_RS_K 2
#define FEC_RS_N 1
#define FEC_RS_T 750

typedef struct {
    uint16_t seq_map[SEQ_MAP_SIZE];
    time_t last_update;
} dedup_state_t;

typedef struct {
	uint16_t seq;
	uint16_t plen;
	uint8_t buf[FEC_RS_K + FEC_RS_N][FEC_RS_T];
	uint8_t marks[FEC_RS_K + FEC_RS_N];
	uint8_t cnt;
	uint8_t *pfec_buf[FEC_RS_K + FEC_RS_N];
    time_t last_update;
} fec_dedup_state_t;

typedef struct {
	uint8_t magic;
	uint8_t fec_rs:2;
	uint8_t fec_idx:3;
	uint8_t fec_num:3;
	uint8_t gw;
	uint8_t apn;
	uint16_t seq;
	uint16_t plen;
	union {
		uint8_t buf[BUFFER_SIZE];
		uint8_t fec_buf[FEC_RS_K + FEC_RS_N][FEC_RS_T];
	}payload;
}__attribute__((__packed__))tun_pkg_t;

dedup_state_t dedup_state;
fec_dedup_state_t fec_dedup_state[SEQ_MAP_SIZE];
struct sockaddr_in serv_addr;
pthread_mutex_t dedup_mutex = PTHREAD_MUTEX_INITIALIZER;
int gl_fec = 0;
int gl_exit_flag = 0;

#define UDP_SBATCH_SIZE (FEC_RS_K + FEC_RS_N)
#define UDP_WORKER 2
//#define TUN_QUEUES (UDP_WORKER + 1) 
#define TUN_QUEUES (1) //muti queue cannot work, why?
int tun_fds[TUN_QUEUES];
int sock_apn[UDP_WORKER];
int udp_workers[UDP_WORKER];
pthread_t tid_apn[UDP_WORKER];
struct udp_packet_t {
	uint8_t magic;
	uint8_t fec_rs:2;
	uint8_t fec_idx:3;
	uint8_t fec_num:3;
	uint8_t gw;
	uint8_t apn;
	uint16_t seq;
	uint16_t plen;
	uint8_t buf[FEC_RS_T];
}__attribute__((__packed__));

typedef struct {
	struct mmsghdr msgs[UDP_SBATCH_SIZE];
	struct iovec iovecs[UDP_SBATCH_SIZE];
	struct udp_packet_t packet[UDP_SBATCH_SIZE];
} udp_sbuf_t;

udp_sbuf_t udp_sbuf[UDP_WORKER];

void udp_sbuf_init(void)
{
	for(int i = 0; i < UDP_WORKER; i++){
		for (int j = 0; j < UDP_SBATCH_SIZE; j++) {
			udp_sbuf[i].iovecs[j].iov_base = &udp_sbuf[i].packet[j];
			udp_sbuf[i].iovecs[j].iov_len = sizeof(udp_sbuf[i].packet[j]);

			memset(&udp_sbuf[i].msgs[j].msg_hdr, 0, sizeof(struct msghdr));
			udp_sbuf[i].msgs[j].msg_hdr.msg_iov = &udp_sbuf[i].iovecs[j];
			udp_sbuf[i].msgs[j].msg_hdr.msg_iovlen = 1;
			udp_sbuf[i].msgs[j].msg_hdr.msg_name = &serv_addr;
			udp_sbuf[i].msgs[j].msg_hdr.msg_namelen = sizeof(struct sockaddr_in);
		}
	}
}

#define UDP_RBATCH_SIZE 16
typedef struct {
	struct mmsghdr msgs[UDP_RBATCH_SIZE];
	struct iovec iovecs[UDP_RBATCH_SIZE];
	char buffer[UDP_RBATCH_SIZE][BUFFER_SIZE];
	struct sockaddr_in addr[UDP_RBATCH_SIZE];
} udp_rbuf_t;

udp_rbuf_t udp_rbuf[UDP_WORKER];

void udp_rbuf_init(void)
{
	for(int i = 0; i < UDP_WORKER; i++){
		for (int j = 0; j < UDP_RBATCH_SIZE; j++) {
			udp_rbuf[i].iovecs[j].iov_base = udp_rbuf[i].buffer[j];
			udp_rbuf[i].iovecs[j].iov_len = sizeof(udp_rbuf[i].buffer[j]);

			memset(&udp_rbuf[i].msgs[j].msg_hdr, 0, sizeof(struct msghdr));
			udp_rbuf[i].msgs[j].msg_hdr.msg_iov = &udp_rbuf[i].iovecs[j];
			udp_rbuf[i].msgs[j].msg_hdr.msg_iovlen = 1;
			udp_rbuf[i].msgs[j].msg_hdr.msg_name = &udp_rbuf[i].addr[j];
			udp_rbuf[i].msgs[j].msg_hdr.msg_namelen = sizeof(struct sockaddr_in);
		}
	}
}

void dump_bytes(void *_buf, int len)
{
	uint8_t *buf = (uint8_t *)_buf;
	for(int i = 0; i < len; i++){
		if(i % 25 == 0){
			printf("\n");
		}
		printf("%02X ", buf[i]);
	}

	printf("\n");
}

in_addr_t host_to_ip(const char *host)
{
    // 1. 检查是否是合法的 IPv4 点分十进制格式
    struct in_addr ipv4_addr;
    if (inet_pton( AF_INET,  host,  &ipv4_addr) == 1) {
        return ipv4_addr.s_addr; // 已经是网络字节序
    }

    // 2. 如果不是 IPv4，尝试解析域名
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET; // 仅 IPv4
    hints.ai_socktype = SOCK_STREAM; // TCP（避免返回多个无关记录）

    int ret = getaddrinfo(host, NULL, &hints, &res);
    if (ret != 0) {
        fprintf(stderr, "DNS failed: %s\n", gai_strerror(ret));
        return INADDR_NONE;
    }

    // 3. 提取第一个 IPv4 地址
    struct sockaddr_in *addr = (struct sockaddr_in *)res->ai_addr;
    in_addr_t result = addr->sin_addr.s_addr;

    freeaddrinfo(res); // 释放内存
    return result;
}

int get_br1_lan_addr(char *buf, int len)
{
	 struct ifreq ifr;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    strncpy(ifr.ifr_name, "br1", IFNAMSIZ);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) {
        perror("ioctl(SIOCGIFFLAGS)");
        close(fd);
        return -1;
    }

    if (ioctl(fd, SIOCGIFADDR, &ifr) < 0) {
        perror("ioctl(SIOCGIFADDR)");
        close(fd);
        return -1;
    }
    struct sockaddr_in *ipaddr = (struct sockaddr_in *)&ifr.ifr_addr;
	uint32_t ip_net = ntohl(ipaddr->sin_addr.s_addr);
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &ipaddr->sin_addr, ip, sizeof(ip));

    if (ioctl(fd, SIOCGIFNETMASK, &ifr) < 0) {
        perror("ioctl(SIOCGIFNETMASK)");
        close(fd);
        return -1;
    }

    struct sockaddr_in *netmask = (struct sockaddr_in *)&ifr.ifr_netmask;
    char mask[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &netmask->sin_addr, mask, sizeof(mask));
	uint32_t mask_net = ntohl(netmask->sin_addr.s_addr);

    char lan[INET_ADDRSTRLEN];
	struct in_addr lan_addr;
	uint32_t network_net = ip_net & mask_net;
	lan_addr.s_addr = htonl(network_net);
    inet_ntop(AF_INET, &lan_addr, lan, sizeof(lan));
	uint32_t mask1 = ntohl(netmask->sin_addr.s_addr);
    int cidr = 0;
    while (mask1 & 0x80000000) {
        cidr++;
        mask1 <<= 1;
    }

	snprintf(buf, len, "%s/%d", lan, cidr);

    close(fd);

	return 0;
}

// 创建TUN设备
int create_tun_device(void) 
{
    struct ifreq ifr;
    int fd, err, i;

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
	if(TUN_QUEUES > 1){
		ifr.ifr_flags |= IFF_MULTI_QUEUE;
	}
    strcpy(ifr.ifr_name, "tun0");

    for (i = 0; i < TUN_QUEUES; i++) {
        if ((fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK)) < 0)
           goto err;
        err = ioctl(fd, TUNSETIFF, (void *)&ifr);
        if (err) {
			perror("ioctl TUNSETIFF failed");
			close(fd);
			goto err;
		}
        tun_fds[i] = fd;
    }

    return 0;
err:
    for (--i; i >= 0; i--)
        close(tun_fds[i]);
    return err;
}

// 绑定Socket到网络接口
int bind_to_interface(int sock, const char *ifname)
{
    if (setsockopt(sock, SOL_SOCKET, SO_BINDTODEVICE, ifname, strlen(ifname)) < 0) {
        printf("SO_BINDTODEVICE failed(%s)\n", ifname);
		close(sock);
		return -1;
    }

	return sock;
}

// 初始化去重状态
void init_dedup_state(void)
{
	memset(dedup_state.seq_map, 0x55AA, sizeof(dedup_state.seq_map));
	dedup_state.last_update = time(NULL);
	for(int i = 0; i < SEQ_MAP_SIZE; i++){
		fec_dedup_state[i].seq = 0xAA55;
		for (int j = 0; j < FEC_RS_K + FEC_RS_N; j++){
			fec_dedup_state[i].pfec_buf[j] = fec_dedup_state[i].buf[j];
		}
	}
}

bool is_duplicate(uint16_t seq) 
{
	bool duplicate = true;
	uint16_t idx = seq % SEQ_MAP_SIZE;
	time_t ts = time(NULL);
    
    pthread_mutex_lock(&dedup_mutex);
    // 清理过期状态
    if (ts - dedup_state.last_update > CONN_TIMEOUT) {
        memset(dedup_state.seq_map, 0x55AA, sizeof(dedup_state.seq_map));
        dedup_state.last_update = ts;
    }
    
    if (seq != dedup_state.seq_map[idx]) {
		dedup_state.seq_map[idx] = seq;
		dedup_state.last_update = ts;
		duplicate = false;
	}
    pthread_mutex_unlock(&dedup_mutex);
    
    return duplicate;
}

bool fec_recv_done(uint16_t seq, tun_pkg_t *pkg, reed_solomon *rs, fec_dedup_state_t **ofec) 
{
	bool done = false;
	uint16_t idx = seq % SEQ_MAP_SIZE;
	time_t ts = time(NULL);
	fec_dedup_state_t *fec = &fec_dedup_state[idx];
    uint16_t plen = ntohs(pkg->plen);
    
    pthread_mutex_lock(&dedup_mutex);

	if(fec->seq != seq){
		fec->seq = seq;
		fec->plen = plen;
		fec->cnt = 0;
		memset(fec->marks, 1, sizeof(fec->marks));
	}

	if(fec->cnt < FEC_RS_K) {
		memcpy(fec->buf[pkg->fec_idx], pkg->payload.buf, FEC_RS_T);
		//printf("FEC RS recv seq %d, pkgid: %d, plen:%d\n", seq, pkg->fec_idx, fec->plen);
		//mark recv
		fec->marks[pkg->fec_idx] = 0;
		fec->cnt++;
		fec->last_update = ts;
		if(fec->cnt >= FEC_RS_K){//recv done
			int ret = reed_solomon_decode(rs, fec->pfec_buf, fec->marks,  FEC_RS_K + FEC_RS_N, FEC_RS_T);
			if(ret != 0){
				printf("FEC RS decode failed\n");
			}else{
				done = true;
				*ofec = fec;
#if DEBUG
				for(int i = 0; i < FEC_RS_K; i++){
					dump_bytes(fec->buf[i], FEC_RS_T);
				}
#endif
			}
		}
	}

    pthread_mutex_unlock(&dedup_mutex);
    
    return done;
}

// 接收线程函数
void *receiver_thread(void *arg) 
{
	int id = *(int *)arg;
    struct sockaddr_in src_addr;
    socklen_t addr_len = sizeof(src_addr);
	int tun_fd;

	if(id < 0 || id >= UDP_WORKER){
		printf("invalid worker id-> %d\n", id);
		return NULL;
	}

	if(TUN_QUEUES > 1){
		tun_fd = tun_fds[id+1];
	}else{
		tun_fd = tun_fds[0];
	}

	reed_solomon *rs = reed_solomon_new(FEC_RS_K, FEC_RS_N);
	if(!rs){
		printf("%s:create rs codec failed\n", __func__);
		return NULL;
	}

    int sock = sock_apn[id];
	struct mmsghdr *msgs = udp_rbuf[id].msgs;
    while (1) {
		if(gl_exit_flag) break;
		int n = recvmmsg(sock, msgs, UDP_RBATCH_SIZE, 0, NULL);
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				usleep(1000);
				continue;
			};
			perror("recvmmsg");
			continue;
		}
		//printf("udp recv %d pack\n", n);
		for (int i = 0; i < n; i++) {
			int len = msgs[i].msg_len;
			tun_pkg_t *msg = msgs[i].msg_hdr.msg_iov->iov_base;
			if (len < PKT_OFFSET || msg->magic != MAGIC_NUM || msg->gw != GATEWAY_ID) continue;
			uint16_t seq = ntohs(msg->seq);
			int plen = len - PKT_OFFSET;
			uint8_t *pbuf = msg->payload.buf;
			if(msg->fec_rs){//FEC RS frame
				fec_dedup_state_t *fec = NULL;
				if(fec_recv_done(seq, msg, rs, &fec)){
					plen = fec->plen;
					pbuf = (uint8_t *)fec->buf;
				}else{
					continue;
				}
			}else {
				// 序列号去重
				if (is_duplicate(seq)) {
					//printf("Duplicate packet (seq: %u) dropped\n", seq);
					continue;
				}
			}

			printf("[%u]udp->tun %d\n", seq, plen);
			// 写入TUN设备
			if (write(tun_fd, pbuf, plen) < 0) {
				perror("write to tun");
			}
		}
    }
	printf("recv thread(%d) exit...\n", id);
	if(rs) reed_solomon_release(rs); 	
	close(sock);
    sock = sock_apn[id] = -1;
    return NULL;
}

// 发送数据包
static void send_packet(void *data, int len, reed_solomon *rs, uint8_t **pfec_buf)
{
    static uint16_t sequence = 0;
	uint16_t plen = len;
	tun_pkg_t *pkg = (tun_pkg_t *)data;
	static int first = 1;

	if(gl_fec && len > PKG_FEC_ENCODE_MIN_LEN) {
		pkg->fec_rs = 1;
		pkg->fec_num = FEC_RS_K + FEC_RS_N;
	}else{
		pkg->fec_rs = 0;
	}
	pkg->gw = GATEWAY_ID;
	if(first){
		pkg->gw |= GATEWAY_START; //notify server clean packet sequence
		first = 0;
	}
	pkg->seq = htons(sequence++);
	pkg->plen = htons(plen);

	printf("[%u]tun->udp %d\n", sequence, plen);
	if(pkg->fec_rs){ //fec encode send
		int ret = reed_solomon_encode(rs, pfec_buf,  FEC_RS_K + FEC_RS_N, FEC_RS_T);
		if(!ret){
			//now roundbin
			int worker = sequence % UDP_WORKER;
			//find next
			if(sock_apn[worker] < 0){
				for(int i = 0; i < UDP_WORKER; i++){
					if(sock_apn[i] > 0){
						worker = i;
						break;
					}
				}
			}
			pkg->apn = worker + 1;
			for(int i = 0; i < UDP_SBATCH_SIZE; i++){
				struct udp_packet_t *msg = &udp_sbuf[worker].packet[i];
				pkg->fec_idx = i;
				//cpoy head
				memcpy(&msg[i], pkg, PKT_OFFSET);
				//printf("send apn%d\n", pkg->apn);
				memcpy(msg[i].buf, pkg->payload.fec_buf[i], FEC_RS_T);
			}
			
			if(UDP_SBATCH_SIZE != sendmmsg(sock_apn[worker], udp_sbuf[worker].msgs, UDP_SBATCH_SIZE, 0)) {
				perror("sendmmsg\n");
			}
		}else{
			printf("FEC RS encode failed\n");
		}
	}else{// send directly
		for(int i = 0; i < UDP_WORKER; i++){
			if(sock_apn[i] > 0){
				pkg->apn = i + 1;
				if (sendto(sock_apn[i], pkg, PKT_OFFSET + plen, 0, 
						  (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
					printf("faied sendto apn%d\n", i + 1);
				}
			}
		}
	}
}

static void set_rules(char *server)
{
	char lan_cidr[32] = {0};
	char cmd[128] = {0};

    system("ifconfig tun0 10.0.0.1 netmask 255.255.255.255 pointopoint 10.0.0.2");
	system("ip link set dev tun0 txqueuelen 2000");
	snprintf(cmd, sizeof(cmd), "ip route add %s dev tun0", server);
	system(cmd);
	if(!get_br1_lan_addr(lan_cidr, sizeof(lan_cidr))){
		printf("get br1 lan: %s\n", lan_cidr);
		//snprintf(cmd, sizeof(cmd), "iptables -t nat -D POSTROUTING -s %s -o tun0 -j SNAT --to-source 10.0.0.1", lan_cidr);
		//system(cmd);
		snprintf(cmd, sizeof(cmd), "iptables -t nat -A POSTROUTING -s %s -o tun0 -j SNAT --to-source 10.0.0.1", lan_cidr);
		system(cmd);
	}
	//for test
	system("ip route add 38.55.199.15 dev tun0");
}

void sig_handler(int sig) 
{
    printf("\n SIGINT exit... \n");
	gl_exit_flag = 1;
}

int main(int argc, char **argv) 
{
	char server[64] = {SERVER_IP};
	in_port_t port = SERVER_PORT;
	tun_pkg_t pkg_buf = {0};
	uint8_t *pfec_buf[FEC_RS_K + FEC_RS_N];
	int c;

    while ((c = getopt(argc, argv, "s:p:fh")) != -1) {
        switch (c) {
        case 'h':
            printf(
                "Usage: %s [options]\n"
                "  -f       	enable FEC RS codec\n"
                "  -s <server>  server address\n"
                "  -p <port> 	service port\n"
                , argv[0]);
            return 1;
        case 's':
			snprintf(server, sizeof(server), "%s", optarg);
            break;
        case 'p':
			port = atoi(optarg); break;
        case 'f':
            gl_fec = 1; break;
        default:
            printf("ignore unknown arg: -%c %s", c, optarg ? optarg : "");
            break;
        }
    }

	reed_solomon *rs = reed_solomon_new(FEC_RS_K, FEC_RS_N);
	if(!rs){
		printf("%s:create rs codec failed\n", __func__);
		return 1;
	}
	for(int i = 0; i < FEC_RS_K + FEC_RS_N; i++){
		pfec_buf[i] = pkg_buf.payload.fec_buf[i];
	}

    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(port);
	serv_addr.sin_addr.s_addr = host_to_ip(server);
	if(serv_addr.sin_addr.s_addr == INADDR_NONE){
		return 1;
	}

	signal(SIGINT, sig_handler);
    //inet_pton(AF_INET, server, &serv_addr.sin_addr);
    srand(time(NULL));
    init_dedup_state();
    int ret = create_tun_device();
    if (ret != 0) {
        printf( "Failed to create TUN device\n");
        return 1;
    }
	printf("Created TUN device: tun0, muti-queue:%d\n", TUN_QUEUES);
	set_rules(server);

	udp_sbuf_init();
	udp_rbuf_init();
	char *apn[] = {"apn01", "apn11", NULL};
	int bind_cnt = 0;
    pthread_t tid_apn01, tid_apn11;
	for(int i = 0, sz = 512 * 1024; i < UDP_WORKER; i++){
		if(apn[i] == NULL) break;
		udp_workers[i] = i;
		sock_apn[i] = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);

		if (sock_apn[i] < 0) {
			perror("socket creation failed");
			return 1;
		}

		if (setsockopt(sock_apn[i],  SOL_SOCKET, SO_RCVBUF, &sz, sizeof(sz)) == -1) {
			perror("setsockopt SO_RCVBUF failed");
			close(sock_apn[i]);
			sock_apn[i] = -1;
			continue;
		}

		if (setsockopt(sock_apn[i],  SOL_SOCKET, SO_SNDBUF, &sz, sizeof(sz)) == -1) {
			perror("setsockopt SO_SNDBUF failed");
			close(sock_apn[i]);
			sock_apn[i] = -1;
			continue;
		}

		sock_apn[i] = bind_to_interface(sock_apn[i], apn[i]);
		if(sock_apn[i] > 0) {
			pthread_create(&tid_apn[i], NULL, receiver_thread, &udp_workers[i]);
			pthread_detach(tid_apn[i]);
			bind_cnt++;
		}
	}

    if (bind_cnt == 0) {
        perror("socket bind interface failed");
        return 1;
    }
    printf("Gateway started. Server: %s:%d, FEC RS(%d)\n", server, port, gl_fec);
	pkg_buf.magic = MAGIC_NUM;
    while (1) {
		if(gl_exit_flag) break;
        int len = read(tun_fds[0], pkg_buf.payload.buf, sizeof(pkg_buf.payload.buf));
        if (len < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(1000);
                continue;
            }
            perror("read from tun");
            break;
        }

		if(len > 0) send_packet(&pkg_buf, len, rs, pfec_buf);
    }

	sleep(1);//wait thread exit
	for(int i = 0; i < TUN_QUEUES; i++){
		if(tun_fds[i] > 0) close(tun_fds[i]);
	}

	for(int i = 0; i < UDP_WORKER; i++){
		if(sock_apn[i] > 0) close(sock_apn[i]);
	}

	if(rs) reed_solomon_release(rs);

	char lan_cidr[32] = {0}, cmd[128] = {0};
	if(!get_br1_lan_addr(lan_cidr, sizeof(lan_cidr))){
		snprintf(cmd, sizeof(cmd), "iptables -t nat -D POSTROUTING -s %s -o tun0 -j SNAT --to-source 10.0.0.1", lan_cidr);
		system(cmd);
	}
	printf("main thread exit ...\n");

    return 0;
}

