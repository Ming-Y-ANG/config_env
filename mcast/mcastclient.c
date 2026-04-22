#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>

#define BUFLEN 255
#define DEFAULT_TTL 64

/**
 * filename: mcastclient.c
 * 组播客户端（UDP发送端）
 * 支持跨网段组播通信
 */

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s <group_address> [group_port] [self_ip] [self_port]\n"
            "  group_address  目标组播地址 (范围: 224.0.0.0 - 239.255.255.255)\n"
            "  group_port     目标组播端口 (默认: 7838)\n"
            "  self_ip        本机发送接口IP (默认: 自动选择)\n"
            "  self_port      本机绑定端口 (默认: 23456)\n"
            "\nExample:\n"
            "  %s 239.255.255.250 1900 192.168.1.100 50000\n",
            prog, prog);
}

int main(int argc, char *argv[])
{
    struct sockaddr_in servaddr, cliaddr;
    int sockfd;
    int ttl = DEFAULT_TTL;
    char recmsg[BUFLEN + 1];
    unsigned int socklen;

    if (argc < 2) {
        usage(argv[0]);
        exit(EXIT_FAILURE);
    }

    /* 创建socket用于UDP通讯 */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* 设置组播TTL，支持跨网段 */
    if (setsockopt(sockfd, IPPROTO_IP, IP_MULTICAST_TTL,
                   &ttl, sizeof(ttl)) == -1) {
        perror("setsockopt (IP_MULTICAST_TTL)");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    /* 设置组播发送接口（关键：多网卡机器必须指定） */
    if (argc > 3) {
        struct in_addr if_addr;
        if (inet_pton(AF_INET, argv[3], &if_addr) <= 0) {
            fprintf(stderr, "错误的本机接口IP: %s\n", argv[3]);
            close(sockfd);
            exit(EXIT_FAILURE);
        }
        if (setsockopt(sockfd, IPPROTO_IP, IP_MULTICAST_IF,
                       &if_addr, sizeof(if_addr)) == -1) {
            perror("setsockopt (IP_MULTICAST_IF)");
            close(sockfd);
            exit(EXIT_FAILURE);
        }
        printf("[INFO] 组播发送接口: %s\n", argv[3]);
    }

    socklen = sizeof(struct sockaddr_in);

    /* 设置对方的端口号和IP信息（组播地址） */
    memset(&servaddr, 0, socklen);
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons((argc > 2) ? atoi(argv[2]) : 7838);

    if (inet_pton(AF_INET, argv[1], &servaddr.sin_addr) <= 0) {
        fprintf(stderr, "错误的组播地址: %s\n", argv[1]);
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    /* 设置自己的端口和IP信息 */
    memset(&cliaddr, 0, socklen);
    cliaddr.sin_family = AF_INET;
    cliaddr.sin_port = htons((argc > 4) ? atoi(argv[4]) : 23456);

    if (argc > 3) {
        if (inet_pton(AF_INET, argv[3], &cliaddr.sin_addr) <= 0) {
            fprintf(stderr, "错误的本机IP地址: %s\n", argv[3]);
            close(sockfd);
            exit(EXIT_FAILURE);
        }
    } else {
        cliaddr.sin_addr.s_addr = INADDR_ANY;
    }

    /* 绑定自己的端口和IP地址到socket上 */
    if (bind(sockfd, (struct sockaddr *)&cliaddr, sizeof(cliaddr)) == -1) {
        perror("bind");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("[INFO] 组播客户端启动，目标 %s:%d，本机绑定端口 %d，TTL=%d\n",
           argv[1],
           (argc > 2) ? atoi(argv[2]) : 7838,
           (argc > 4) ? atoi(argv[4]) : 23456,
           ttl);
    printf("请输入要发送的消息（Ctrl+D 退出）:\n");

    /* 循环接受用户输入的信息发送组播消息 */
    for (;;) {
        memset(recmsg, 0, sizeof(recmsg));
        if (fgets(recmsg, BUFLEN, stdin) == NULL) {
            printf("\n[INFO] 退出.\n");
            break;
        }

        if (sendto(sockfd, recmsg, strlen(recmsg), 0,
                   (struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) {
            perror("sendto");
            continue;
        }

        printf("[SEND] 发送成功: %s", recmsg);
    }

    close(sockfd);
    return 0;
}
