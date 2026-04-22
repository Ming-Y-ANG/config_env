#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>

/**
 * filename: broadc-udpserver.c
 * UDP广播接收端
 */

static volatile sig_atomic_t keep_running = 1;

static void sigint_handler(int sig)
{
    (void)sig;
    keep_running = 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [listen_ip] [listen_port]\n"
            "  listen_ip   监听地址 (默认: 0.0.0.0 - 所有接口)\n"
            "              提示: 接收广播建议用 0.0.0.0，绑定具体IP可能收不到广播\n"
            "  listen_port 监听端口 (默认: 7838)\n"
            "\nExample:\n"
            "  %s                  # 监听所有接口的 7838 端口\n"
            "  %s 0.0.0.0 7838     # 同上，显式指定\n",
            prog, prog, prog);
}

static int setup_signal_handler(void)
{
    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigint_handler;
    if (sigaction(SIGINT, &sa, NULL) < 0) {
        perror("sigaction (SIGINT)");
        return -1;
    }
    if (sigaction(SIGTERM, &sa, NULL) < 0) {
        perror("sigaction (SIGTERM)");
        return -1;
    }
    return 0;
}

int main(int argc, char *argv[])
{
    struct sockaddr_in servaddr, cliaddr;
    int sockfd;
    socklen_t addr_len;
    ssize_t len;
    char buff[128];
    char client_ip[INET_ADDRSTRLEN];
    int port;
    int reuse = 1;
    const char *ip_str;
    struct timeval tv;

    if (argc > 3) {
        usage(argv[0]);
        exit(EXIT_FAILURE);
    }

    /* 解析参数 */
    if (argc == 3) {
        ip_str = argv[1];
        port = atoi(argv[2]);
    } else if (argc == 2) {
        ip_str = "0.0.0.0";
        port = atoi(argv[1]);
    } else {
        ip_str = "0.0.0.0";
        port = 7838;
    }

    if (port <= 0 || port > 65535) {
        fprintf(stderr, "错误: 端口范围必须是 1-65535\n");
        exit(EXIT_FAILURE);
    }

    /* 设置信号处理 */
    if (setup_signal_handler() < 0) {
        exit(EXIT_FAILURE);
    }

    /* 创建socket */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* 设置地址重用 */
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR,
                   &reuse, sizeof(reuse)) == -1) {
        perror("setsockopt (SO_REUSEADDR)");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    /* 设置接收超时 1 秒 */
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
        perror("setsockopt (SO_RCVTIMEO)");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    /* 设置服务器地址 - 必须用 INADDR_ANY 才能收到广播 */
    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons(port);
    
    /* 绑定到 INADDR_ANY 才能接收广播 */
    if (strcmp(ip_str, "0.0.0.0") != 0) {
        printf("[WARN] 绑定到 %s 可能无法接收广播包，建议使用 0.0.0.0\n", ip_str);
    }
    
    if (strcmp(ip_str, "0.0.0.0") == 0) {
        servaddr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else {
        if (inet_pton(AF_INET, ip_str, &servaddr.sin_addr) <= 0) {
            fprintf(stderr, "错误: 无效的 IP 地址: %s\n", ip_str);
            close(sockfd);
            exit(EXIT_FAILURE);
        }
    }

    /* 绑定 */
    if (bind(sockfd, (struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) {
        perror("bind");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("[INFO] UDP广播接收端已启动，监听端口: %d\n", port);
    printf("[INFO] 按 Ctrl+C 退出\n\n");

    /* 循环接收 - 每次 recvfrom 前都要重置 addr_len */
    while (keep_running) {
        /* 关键: addr_len 是值-结果参数，每次都要初始化 */
        addr_len = sizeof(cliaddr);
        
        len = recvfrom(sockfd, buff, sizeof(buff) - 1, 0,
                       (struct sockaddr *)&cliaddr, &addr_len);
        if (len < 0) {
            if (errno == EINTR) {
                break;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            perror("recvfrom");
            continue;
        }

        buff[len] = '\0';
        inet_ntop(AF_INET, &cliaddr.sin_addr, client_ip, sizeof(client_ip));
        printf("[RECV] 来自 %s:%d: %s\n",
               client_ip, ntohs(cliaddr.sin_port), buff);
    }

    printf("\n[INFO] 接收端已关闭\n");
    close(sockfd);
    return 0;
}
