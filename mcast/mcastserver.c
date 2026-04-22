#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <arpa/inet.h>
#include <netdb.h>

/**
 * filename: mcastserver.c
 * 组播服务端
 * 支持跨网段组播通信，可指定接收接口
 */

#define BUFLEN 1500

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s <group_address> [port] [interface_ip]\n"
            "  group_address  组播地址 (范围: 224.0.0.0 - 239.255.255.255)\n"
            "  port           监听端口 (默认: 7838)\n"
            "  interface_ip   接收接口IP (默认: 0.0.0.0，所有接口)\n"
            "\nExample:\n"
            "  %s 239.255.255.250 1900 192.168.1.100\n",
            prog, prog);
}

int main(int argc, char *argv[])
{
    struct sockaddr_in servaddr;
    struct in_addr ia;
    int sockfd;
    char recmsg[BUFLEN + 1];
    unsigned int socklen;
    ssize_t n;
    struct hostent *group;
    struct ip_mreq mreq;

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

    /* 设置要加入组播的地址 */
    memset(&mreq, 0, sizeof(mreq));
    group = gethostbyname(argv[1]);
    if (group == NULL) {
        fprintf(stderr, "gethostbyname: %s: %s\n", argv[1], hstrerror(h_errno));
        exit(EXIT_FAILURE);
    }

    memcpy(&ia, group->h_addr, group->h_length);
    memcpy(&mreq.imr_multiaddr.s_addr, &ia, sizeof(struct in_addr));

    /* 设置接收组播的网络接口 */
    if (argc > 3) {
        if (inet_pton(AF_INET, argv[3], &mreq.imr_interface) <= 0) {
            fprintf(stderr, "错误的接口IP: %s\n", argv[3]);
            close(sockfd);
            exit(EXIT_FAILURE);
        }
        printf("[INFO] 绑定接收接口: %s\n", argv[3]);
    } else {
        mreq.imr_interface.s_addr = htonl(INADDR_ANY);
    }

    /* 把本机加入组播地址 */
    if (setsockopt(sockfd, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                   &mreq, sizeof(mreq)) == -1) {
        perror("setsockopt (IP_ADD_MEMBERSHIP)");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    socklen = sizeof(struct sockaddr_in);
    memset(&servaddr, 0, socklen);
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons((argc > 2) ? atoi(argv[2]) : 7838);
    /* 绑定 INADDR_ANY 而不是组播地址，这样才能接收所有接口的组播 */
    servaddr.sin_addr.s_addr = htonl(INADDR_ANY);

    /* 绑定自己的端口和IP信息到socket上 */
    if (bind(sockfd, (struct sockaddr *)&servaddr, sizeof(servaddr)) == -1) {
        perror("bind");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("[INFO] 组播服务端启动，监听 %s:%d\n",
           argv[1], (argc > 2) ? atoi(argv[2]) : 7838);

    /* 循环接收网络上的组播消息 */
    for (;;) {
        memset(recmsg, 0, sizeof(recmsg));
        n = recvfrom(sockfd, recmsg, BUFLEN, 0,
                     (struct sockaddr *)&servaddr, &socklen);
        if (n < 0) {
            perror("recvfrom");
            continue;
        }

        recmsg[n] = '\0';
#if 0
        printf("[RECV] %s:%d -> %s\n",
               inet_ntoa(servaddr.sin_addr),
               ntohs(servaddr.sin_port),
               recmsg);
#endif
		printf("%s", recmsg);
    }

    close(sockfd);
    return 0;
}
