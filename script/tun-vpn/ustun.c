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
#include <ih_list.h>
#include "rs.h"
#include <sys/time.h>
#include <sys/uio.h>
#include <netinet/ip.h> 
#include <linux/version.h>
#include <signal.h>


#ifdef SEG_TRACE
extern void setup_sigsegv(void);
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,1,0)
//kernel 5.1+ support io_uring
#include <liburing.h>
#define USE_IO_URING
#endif

#define MAGIC_NUM 0x5A
#define SERVER_PORT 8000
#define BUFFER_SIZE 1500
#define SEQ_MAP_SIZE 8192
#define CONN_TIMEOUT 180  // 3 minutes
#define PKT_OFFSET 8
#define UDP_WORKER 2
#define PKG_FEC_ENCODE_MIN_LEN 1200
#define GATEWAY_START 0x80
#define GATEWAY_ID_MASK 0x7F
#define MAX_GW_APN 2 //dual modem

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
	uint8_t *pfec_buf[FEC_RS_K + FEC_RS_N];//serialize two-dimensional buf to speed up memory access
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

typedef struct conn_key {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t protocol;
	uint32_t hash_val;
} conn_key_t;

typedef struct gateway_addr {
    struct sockaddr_in addr_apn[MAX_GW_APN];
    time_t last_seen_apn[MAX_GW_APN];
    time_t last_used;
    uint8_t gateway_id;
    struct ih_list_head entries;
} gateway_addr_t;

typedef struct conn_entry {
    conn_key_t key;
    uint8_t gateway_id;
    time_t last_used;
    struct ih_list_head entries;
} conn_entry_t;

static IH_LIST_HEAD(gateway_addrs);   
static IH_LIST_HEAD(conn_table);    

pthread_mutex_t gateway_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t conn_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t dedup_mutex = PTHREAD_MUTEX_INITIALIZER;

int udp_sock[UDP_WORKER];
pthread_t tid_udp[UDP_WORKER];
int udp_workers[UDP_WORKER];
dedup_state_t dedup_state;
fec_dedup_state_t fec_dedup_state[SEQ_MAP_SIZE];
uint16_t port = SERVER_PORT;
int gl_fec = 0;
uint32_t gl_udp_recv_pack[UDP_WORKER];
int gl_debug = 0;
int gl_exit_flag = 0;

static void send_to_gateway(void *data, int len, reed_solomon *rs, uint8_t **pfec_buf);
#ifdef USE_IO_URING
#define TUN_BATCH_SIZE 32
#define TUN_QUEUES 1
struct packet_t {
	tun_pkg_t pack;
	uint8_t *pfec_buf[FEC_RS_K + FEC_RS_N];
};
typedef struct {
	struct io_uring ring;
	struct packet_t msg[TUN_BATCH_SIZE];
} tun_buf_t;
tun_buf_t tun_buf;

void tun_buf_init(int fd)
{
	printf("io_uring init..\n");
	io_uring_queue_init(TUN_BATCH_SIZE, &tun_buf.ring, 0);

	struct packet_t *msg = tun_buf.msg;
	for (int i = 0; i < TUN_BATCH_SIZE; i++) {
		struct io_uring_sqe *sqe = io_uring_get_sqe(&tun_buf.ring);
		io_uring_prep_read(sqe, fd, msg[i].pack.payload.buf, sizeof(msg[i].pack.payload.buf), -1);
		for(int j = 0; j < FEC_RS_K + FEC_RS_N; j++){
			msg[i].pfec_buf[j] = msg[i].pack.payload.fec_buf[j];
		}
		sqe->user_data = (unsigned long)i;
	}
	io_uring_submit(&tun_buf.ring);
}

int io_uring_poll(reed_solomon *rs, int fd)
{
	struct io_uring_cqe *cqe;
	int ret = io_uring_wait_cqe(&tun_buf.ring, &cqe);
	if (ret < 0) {
		perror("io_uring_wait_cqe");
		return -1;
	}
	unsigned head;
	int count = 0;
	io_uring_for_each_cqe(&tun_buf.ring, head, cqe) {
		if(cqe->res == -EAGAIN) continue;
		int idx = (int)cqe->user_data;
		if (cqe->res > 0) {
			count++;
			struct packet_t *pkg = &tun_buf.msg[idx]; 
			send_to_gateway(&pkg->pack, cqe->res, rs, pkg->pfec_buf);
			struct io_uring_sqe *sqe = io_uring_get_sqe(&tun_buf.ring);
			io_uring_prep_read(sqe, fd, pkg->pack.payload.buf, sizeof(pkg->pack.payload.buf), -1);
			sqe->user_data = (unsigned long)idx;
		} else {
			printf("io_uring error: %s\n", strerror(-cqe->res));
		}
	}
	if (count > 0) {
		//printf("tun recv %d pack\n", count);
		io_uring_submit(&tun_buf.ring);
		io_uring_cq_advance(&tun_buf.ring, count);
	}
}
#else
#define TUN_QUEUES (1) //muti tun queue cannot work with io_uring?
#endif
int tun_fds[TUN_QUEUES];

#define UDP_RBATCH_SIZE 32
typedef struct {
	struct mmsghdr msgs[UDP_RBATCH_SIZE];
	struct iovec iovecs[UDP_RBATCH_SIZE];
	char buffer[UDP_RBATCH_SIZE][BUFFER_SIZE];
	struct sockaddr_in client_addr[UDP_RBATCH_SIZE];
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
			udp_rbuf[i].msgs[j].msg_hdr.msg_name = &udp_rbuf[i].client_addr[j];
			udp_rbuf[i].msgs[j].msg_hdr.msg_namelen = sizeof(struct sockaddr_in);
		}
	}
}

#define UDP_SBATCH_SIZE (FEC_RS_K + FEC_RS_N)
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
			//udp_sbuf[i].msgs[j].msg_hdr.msg_name = &serv_addr;
			udp_sbuf[i].msgs[j].msg_hdr.msg_namelen = sizeof(struct sockaddr_in);
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
        if ((fd = open("/dev/net/tun", O_RDWR|O_NONBLOCK)) < 0)
           goto err;
        err = ioctl(fd, TUNSETIFF, (void *)&ifr);
        if (err) {
           close(fd);
           goto err;
        }
        tun_fds[i] = fd;
    }

    //system("ip link set tun0 up");
    //system("ip addr add 10.5.29.1/24 dev tun0");
    system("sysctl -w net.ipv4.ip_forward=1");
	//10.0.0.2-> server, 10.0.0.1-> client
    system("ifconfig tun0 10.0.0.2 netmask 255.255.255.255 pointopoint 10.0.0.1");
	//system("iptables -t nat -A POSTROUTING -s 10.5.29.0/24 -j MASQUERADE");
	//for test
	system("iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE");
	system("iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE");
	system("ip link set dev tun0 txqueuelen 3000");

    return 0;
err:
    for (--i; i >= 0; i--)
        close(tun_fds[i]);
    return err;
}

void init_dedup_state(void)
{
	static time_t last_ts = 0, first = 1;

	time_t ts = time(NULL);
	if(ts - last_ts > 3){
		last_ts = ts;
		printf("==> clean seq maps\n");
		memset(dedup_state.seq_map, 0x55AA, sizeof(dedup_state.seq_map));
		dedup_state.last_update = ts;
		for(int i = 0; i < SEQ_MAP_SIZE; i++){
			fec_dedup_state[i].seq = 0xAA55;
			if(first){
				for (int j = 0; j < FEC_RS_K + FEC_RS_N; j++){
					fec_dedup_state[i].pfec_buf[j] = fec_dedup_state[i].buf[j];
				}
			}
		}
	}
	if(first) first = 0;
}

bool is_duplicate(uint16_t seq) 
{
	bool duplicate = true;
	uint16_t idx = seq % SEQ_MAP_SIZE;
	time_t ts = time(NULL);
    
    pthread_mutex_lock(&dedup_mutex);
    if (ts - dedup_state.last_update > CONN_TIMEOUT) {
        memset(dedup_state.seq_map, 0x55AA, sizeof(dedup_state.seq_map));
        dedup_state.last_update = ts;
    }
    
    if (seq != dedup_state.seq_map[idx]) {
		duplicate = false;
		dedup_state.seq_map[idx] = seq;
		dedup_state.last_update = ts;
	}
    pthread_mutex_unlock(&dedup_mutex);
    
    return duplicate;
}

bool fec_recv_done(uint16_t seq, tun_pkg_t *pkg, reed_solomon *rs, fec_dedup_state_t **ofec) 
{
#define DEGBUG_TIME 0
	bool done = false;
	uint16_t idx = seq % SEQ_MAP_SIZE;
	time_t ts = time(NULL);
	fec_dedup_state_t *fec = &fec_dedup_state[idx];
    uint16_t plen = ntohs(pkg->plen);

#if DEGBUG_TIME
	struct timeval start, end;
	double time_used;
    gettimeofday(&start, NULL); // 记录开始时间
#endif
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
				if(gl_debug > 1){
					for(int i = 0; i < FEC_RS_K; i++){
						dump_bytes(fec->buf[i], FEC_RS_T);
					}
				}
			}
#if DEGBUG_TIME
			gettimeofday(&end, NULL); // 记录结束时间
			time_used = (end.tv_sec - start.tv_sec) + (end.tv_usec - start.tv_usec) / 1000000.0;
			printf("=>decode use: %f s\n", time_used / 20);
#endif
		}
	}

    pthread_mutex_unlock(&dedup_mutex);
    
    return done;
}

// 更新网关地址映射
void update_gateway_map(uint8_t gateway_id, struct sockaddr_in *addr, uint8_t path_id)
{
    gateway_addr_t *gw = NULL;
	time_t ts = time(NULL);

	if(gl_debug > 0){
		printf("update apn path id:%d\n", path_id);
	}
	path_id--;
	if(path_id >= MAX_GW_APN) return;

    pthread_mutex_lock(&gateway_mutex);
    
    ih_list_for_each_entry(gw, &gateway_addrs, entries) {
		if(gateway_id == gw->gateway_id){
			if (gw->last_used > 0) {
				gw->addr_apn[path_id] = *addr;
				gw->last_seen_apn[path_id] = ts;
				gw->last_used = ts;
				pthread_mutex_unlock(&gateway_mutex);
				return;
			}
		}
    }
    
    // 未找到，创建新条目
    gw = malloc(sizeof(gateway_addr_t));
    if (!gw) {
        pthread_mutex_unlock(&gateway_mutex);
        return;
    }
    
    memset(gw, 0, sizeof(*gw));
    IH_INIT_LIST_HEAD(&gw->entries);
    
	gw->addr_apn[path_id] = *addr;
	gw->last_seen_apn[path_id] = ts;
    gw->last_used = ts;
	gw->gateway_id = gateway_id;
    
    ih_list_add(&gw->entries, &gateway_addrs);
    
    pthread_mutex_unlock(&gateway_mutex);
}

gateway_addr_t *get_gateway_addr(uint8_t gateway_id)
{
    gateway_addr_t *gw = NULL;

    pthread_mutex_lock(&gateway_mutex);
    
    ih_list_for_each_entry(gw, &gateway_addrs, entries) {
        if (gw->gateway_id == gateway_id) break;
    }
    
    pthread_mutex_unlock(&gateway_mutex);

    return gw;
}

void cleanup_expired_gateways(int expire) 
{
    pthread_mutex_lock(&gateway_mutex);
    
    gateway_addr_t *gw, *tmp;
    time_t now = time(NULL);
	int cnt;
    
    ih_list_for_each_entry_safe(gw, tmp, &gateway_addrs, entries) {
		cnt = 0;
		for(int i = 0; i < MAX_GW_APN; i++){
			if(gw->last_seen_apn[i] && (now - gw->last_seen_apn[i] > CONN_TIMEOUT)){
				gw->last_seen_apn[i] = 0;
				cnt++;
			}
		}
        if (expire || cnt >= MAX_GW_APN) {
            ih_list_del(&gw->entries);
            free(gw);
        }
    }
    
    pthread_mutex_unlock(&gateway_mutex);
}

void static inline conn_hash_cal(conn_key_t *key, uint8_t *ip_packet)
{
    key->src_ip = *(uint32_t *)(ip_packet + 12);
    key->dst_ip = *(uint32_t *)(ip_packet + 16);
    //key.protocol = ip_packet[9];
#if 0
    uint16_t src_port = 0, dst_port = 0;
    if (protocol == 6 || protocol == 17) { // TCP or UDP
        if (ip_len >= ip_ihl * 4 + 4) {
            src_port = ntohs(*(uint16_t *)(ip_packet + ip_ihl * 4));
            dst_port = ntohs(*(uint16_t *)(ip_packet + ip_ihl * 4 + 2));
        }
    }
    key.src_port = src_port;
    key.dst_port = dst_port;
#endif
	key->hash_val = key->src_ip + key->dst_ip;
}

void update_conn_table(uint8_t gateway_id, struct sockaddr_in *client_addr, 
                      uint8_t *ip_packet,  int ip_len)
{
    // 解析IP头部获取五元组
    //if (ip_len < 20) return; // 最小IP头部长度
    
    uint8_t ip_ver = (ip_packet[0] >> 4) & 0x0F;
    if (ip_ver != 4) return; // 仅支持IPv4
    //uint8_t ip_ihl = ip_packet[0] & 0x0F;
    //if (ip_len < ip_ihl * 4) return; // 无效头部长度
    
    // 创建连接键
    conn_key_t key = {0};
	conn_hash_cal(&key, ip_packet);
    
    pthread_mutex_lock(&conn_mutex);
    
    conn_entry_t *entry;
    ih_list_for_each_entry(entry, &conn_table, entries) {
		//FIXME now hash val is simple
		if(entry->key.hash_val == key.hash_val){
            entry->last_used = time(NULL);
			goto leave;
		}
    }
    
    // 创建新条目
    entry = malloc(sizeof(conn_entry_t));
    if (!entry) {
		goto leave;
    }
    
    entry->key = key;
    entry->gateway_id = gateway_id;
    entry->last_used = time(NULL);
    IH_INIT_LIST_HEAD(&entry->entries);
    
    ih_list_add(&entry->entries, &conn_table);

leave:   
    pthread_mutex_unlock(&conn_mutex);
}

// 根据IP包查找网关
uint8_t find_gateway_for_packet(uint8_t *ip_packet, ssize_t ip_len)
{
    uint8_t gw_id = 0;
    // 解析IP头部获取五元组
    //if (ip_len < 20) return 0; // 最小IP头部长度
    
    uint8_t ip_ver = (ip_packet[0] >> 4) & 0x0F;
    if (ip_ver != 4) return 0; // 仅支持IPv4
    //uint8_t ip_ihl = ip_packet[0] & 0x0F;
    //if (ip_len < ip_ihl * 4) return 0; // 无效头部长度
    
    // 创建连接键（反向）
    conn_key_t key = {0};
	conn_hash_cal(&key, ip_packet);
    
    pthread_mutex_lock(&conn_mutex);
    
    conn_entry_t *entry;
    ih_list_for_each_entry(entry, &conn_table, entries) {
		//FIXME now hash is simple
		if(entry->key.hash_val == key.hash_val){
            gw_id = entry->gateway_id;
            entry->last_used = time(NULL);
			break;
		}
    }
    
    pthread_mutex_unlock(&conn_mutex);

    return gw_id;
}

void cleanup_expired_connections(int expire)
{
    pthread_mutex_lock(&conn_mutex);
    
    conn_entry_t *entry, *tmp;
    time_t now = time(NULL);
    
    ih_list_for_each_entry_safe(entry, tmp, &conn_table, entries) {
        if (expire || (now - entry->last_used > CONN_TIMEOUT)) {
            ih_list_del(&entry->entries);
            free(entry);
        }
    }
    
    pthread_mutex_unlock(&conn_mutex);
}

void *udp_receiver_thread(void *arg)
{
    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);
	int id = *(int *)arg;
	int sock = -1;
	tun_pkg_t pkg = {0};
	int tun_fd;

	if(id < 0 || id >= UDP_WORKER){
		printf("invalid worker id-> %d\n", id);
		return NULL;
	}

	if(TUN_QUEUES > 1){
		tun_fd = tun_fds[id + 1];
	}else{
		tun_fd = tun_fds[0];
	}

	reed_solomon *rs = reed_solomon_new(FEC_RS_K, FEC_RS_N);
	if(!rs){
		printf("%s:create rs codec failed\n", __func__);
		return NULL;
	}


    sock = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    //sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket creation failed");
        return NULL;
    }

    int optval = 1;
	if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval)) == -1) {
        perror("setsockopt SO_REUSEADDR failed");
        close(sock);
		return NULL;
	}
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &optval, sizeof(optval)) == -1) {
        perror("setsockopt SO_REUSEPORT failed");
        close(sock);
		return NULL;
    }
	uint32_t sz = 1024 * 1024;
    /* increase the reception socket size as the default value may lead to a high datagram loss rate */
    if (setsockopt(sock,  SOL_SOCKET, SO_RCVBUF, &sz, sizeof(sz)) == -1) {
        perror("setsockopt SO_RCVBUF failed");
		close(sock);
        return NULL;
    }

    if (setsockopt(sock,  SOL_SOCKET, SO_SNDBUF, &sz, sizeof(sz)) == -1) {
        perror("setsockopt SO_SNDBUF failed");
		close(sock);
        return NULL;
    }
    
    struct sockaddr_in serv_addr;
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    serv_addr.sin_port = htons(port);
    
    if (bind(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
        perror("bind failed");
        close(sock);
        return NULL;
    }
	udp_sock[id] = sock;
    printf("UDP worker %d listening on port %d\n", id, port);
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

		gl_udp_recv_pack[id] += n;
		//printf("udp%d recv %d pack\n", id, n);
		for (int i = 0; i < n; i++) {
			int len = msgs[i].msg_len;
			tun_pkg_t *msg = msgs[i].msg_hdr.msg_iov->iov_base;
			if (len < PKT_OFFSET || msg->magic != MAGIC_NUM) continue;
			int plen = len - PKT_OFFSET;
			uint8_t *pbuf = msg->payload.buf;
			uint16_t seq = ntohs(msg->seq);
			uint8_t gw = msg->gw & GATEWAY_ID_MASK;
			if(msg->gw & GATEWAY_START){
				init_dedup_state();
			}
			update_gateway_map(gw, msgs[i].msg_hdr.msg_name, msg->apn);
			update_conn_table(gw, msgs[i].msg_hdr.msg_name, pbuf, plen);
			if(msg->fec_rs){//FEC RS frame
				fec_dedup_state_t *fec = NULL;
				if(!fec_recv_done(seq, msg, rs, &fec)) continue;
				plen = fec->plen;
				pbuf = (uint8_t *)fec->buf;
			}else {
				if (is_duplicate(seq)) {
					// printf("Duplicate packet (seq: %u) dropped\n", seq);
					continue;
				}
			}
			printf("[%u]udp->tun %d\n", seq, plen);
			if (write(tun_fd, pbuf, plen) < 0) {
				perror("write to tun");
			}
		}
    }
	if(sock > 0) close(sock);
	sock = udp_sock[id] = -1;
	if(rs) reed_solomon_release(rs);
	printf("udp thread %d exit...\n", id);
    return NULL;
}

// 发送响应到网关
static void send_to_gateway(void *data, int len, reed_solomon *rs, uint8_t **pfec_buf)
{
    // 添加头部
    static uint16_t sequence = 0;
	uint16_t plen = len;
	tun_pkg_t *pkg = (tun_pkg_t *)data;
    
    // 查找网关ID
    uint8_t gateway_id = find_gateway_for_packet(pkg->payload.buf, len);
    if (gateway_id == 0) {
		if(gl_debug > 0)
			printf("No gateway found for response\n");
        return;
    }
    
    // 获取网关地址
    gateway_addr_t *gw = get_gateway_addr(gateway_id);
    if (!gw) {
		if(gl_debug > 0)
			printf("Gateway %u not found\n", gateway_id);
        return;
    }
    
	pkg->magic = MAGIC_NUM;
	if(gl_fec && len > PKG_FEC_ENCODE_MIN_LEN) {
		pkg->fec_rs = 1;
		pkg->fec_num = FEC_RS_K + FEC_RS_N;
	}else{
		pkg->fec_rs = 0;
	}
	pkg->gw = gateway_id;
	pkg->seq = htons(sequence++);
	pkg->plen = htons(plen);
    int total_len = len + PKT_OFFSET;
	printf("[%u]tun->udp %d\n", sequence, total_len);
	if(pkg->fec_rs){ //fec encode send
		int ret = reed_solomon_encode(rs, pfec_buf,  FEC_RS_K + FEC_RS_N, FEC_RS_T);
		if(!ret){
			//now roundbin
			int worker = sequence % UDP_WORKER;
			//find next
			if(udp_sock[worker] < 0){
				for(int i = 0; i < UDP_WORKER; i++){
					if(udp_sock[i] > 0){
						worker = i;
						break;
					}
				}
			}
			struct udp_packet_t *pack = udp_sbuf[worker].packet;
			struct mmsghdr *msgs = udp_sbuf[worker].msgs;
			for(int i = 0; i < UDP_SBATCH_SIZE; i++){
				pkg->fec_idx = i;
				//cpoy head
				memcpy(&pack[i], pkg, PKT_OFFSET);
				//printf("send apn%d\n", pkg->apn);
				memcpy(pack[i].buf, pkg->payload.fec_buf[i], FEC_RS_T);
				msgs[i].msg_hdr.msg_name = &gw->addr_apn[worker];
			}

			if(UDP_SBATCH_SIZE != sendmmsg(udp_sock[worker], msgs, UDP_SBATCH_SIZE, 0)) {
				perror("sendmmsg\n");
			}
		}else{
			printf("FEC RS encode failed\n");
		}
	}else{// send directly
		for(int i = 0; i < MAX_GW_APN; i++){
			int udp_sk = i % UDP_WORKER;
			if(gw->last_seen_apn[i] > 0 && udp_sock[udp_sk] > 0){
				sendto(udp_sock[udp_sk], pkg, total_len, 0, 
					  (struct sockaddr *)&gw->addr_apn[i], sizeof(gw->addr_apn[i]));
			}
		}
	}
}

void sig_handler(int sig) 
{
    printf("\n SIGINT exit... \n");
	for(int i = 0; i < UDP_WORKER; i++){
		printf("udp%d -> %u packs\n", i, gl_udp_recv_pack[i]);
	}
	gl_exit_flag = 1;
}

int main(int argc, char **argv) 
{
	int c;
    while ((c = getopt(argc, argv, "p:fhd:")) != -1) {
        switch (c) {
        case 'h':
            printf(
                "Usage: %s [options]\n"
                "  -f       	enable FEC RS codec\n"
                "  -p <port> 	bind port\n"
                "  -d <1-2>     debug\n"
                , argv[0]);
            return 1;
        case 'p':
			port = atoi(optarg); break;
        case 'f':
            gl_fec = 1; break;
        case 'd':
            gl_debug = atoi(optarg); break;
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

	signal(SIGINT, sig_handler);
#ifdef SEG_TRACE
	setup_sigsegv();
#endif
	srand(time(NULL));
	udp_rbuf_init();
	udp_sbuf_init();
	// 初始化去重状态
	init_dedup_state();
	
	// 创建TUN设备
	int ret = create_tun_device();
	if (ret != 0) {
		printf("Failed to create TUN device\n");
		return 1;
	}
	printf("Created TUN device: tun0, muti-queue:%d\n", TUN_QUEUES);
#ifdef USE_IO_URING
	tun_buf_init(tun_fds[0]);
#else
	tun_pkg_t pkg_buf = {0};
	uint8_t *pfec_buf[FEC_RS_K + FEC_RS_N];

	for(int i = 0; i < FEC_RS_K + FEC_RS_N; i++){
		pfec_buf[i] = pkg_buf.payload.fec_buf[i];
	}
#endif

	for(int i = 0; i < UDP_WORKER; i++){
		udp_workers[i] = i;
		pthread_create(&tid_udp[i], NULL, udp_receiver_thread, &udp_workers[i]);
		pthread_detach(tid_udp[i]);
	}

	printf("Server started. Waiting for traffic(FEC RS(%d))...\n", gl_fec);

	time_t last_cleanup = time(NULL);
	//TODO safe exit...
	while (1) {
		if(gl_exit_flag) break;
#ifdef USE_IO_URING
		io_uring_poll(rs, tun_fds[0]);
#else
		int len = read(tun_fds[0], &pkg_buf.payload.buf, sizeof(pkg_buf.payload.buf));
		if (len < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				usleep(1000);
				continue;
			}
			perror("read from tun");
			continue;;
		}

		if(len > 0) send_to_gateway(&pkg_buf, len, rs, pfec_buf);
#endif

		time_t now = time(NULL);
		if (now - last_cleanup > CONN_TIMEOUT) {
			cleanup_expired_gateways(0);
			cleanup_expired_connections(0);
			last_cleanup = now;
		}
	}

	sleep(1); //wait exit
#ifdef USE_IO_URING
	io_uring_queue_exit(&tun_buf.ring);  
#endif
	for(int i = 0; i < TUN_QUEUES; i++){
		if(tun_fds[i] > 0) close(tun_fds[i]);
	}
	for(int i = 0; i < UDP_WORKER; i++){
		if(udp_sock[i] > 0) close(udp_sock[i]);
	}
	cleanup_expired_gateways(1);
	cleanup_expired_connections(1);
	if(rs) reed_solomon_release(rs);
	printf("main thread exit ...\n");

	return 0;
}

