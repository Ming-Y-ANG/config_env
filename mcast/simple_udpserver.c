#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>

/**
 * filename: simple_udpserver.c
 * 基本UDP编程服务器端
 */

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [bind_ip] [bind_port]\n"
            "  bind_ip        绑定IP地址 (默认: 0.0.0.0)\n"
            "  bind_port      绑定端口 (默认: 7838)\n"
            "\nExample:\n"
            "  %s 0.0.0.0 7838\n",
            prog, prog);
}

int main(int argc, char *argv[])
{
    struct sockaddr_in servaddr, cliaddr;
    int sockfd;
    socklen_t clilen;
    ssize_t len;
    char buff[128];

    if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        usage(argv[0]);
        exit(EXIT_SUCCESS);
    }

    /* 创建socket */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons((argc > 2) ? atoi(argv[2]) : 7838);

    if (argc > 1) {
        if (inet_pton(AF_INET, argv[1], &servaddr.sin_addr) <= 0) {
            fprintf(stderr, "错误的绑定IP地址: %s\n", argv[1]);
            close(sockfd);
            exit(EXIT_FAILURE);
        }
    } else {
        servaddr.sin_addr.s_addr = INADDR_ANY;
    }

    /* 绑定地址和端口信息 */
    if (bind(sockfd, (struct sockaddr *)&servaddr, sizeof(servaddr)) == -1) {
        perror("bind");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("[INFO] UDP服务器启动，监听 %s:%d\n",
           (argc > 1) ? argv[1] : "0.0.0.0",
           (argc > 2) ? atoi(argv[2]) : 7838);

    /* 循环接收数据 */
    clilen = sizeof(cliaddr);
    for (;;) {
        len = recvfrom(sockfd, buff, sizeof(buff), 0,
                       (struct sockaddr *)&cliaddr, &clilen);
        if (len < 0) {
            perror("recvfrom");
            continue;
        }

        buff[len] = '\0';
        printf("[RECV] %s:%d -> %s\n",
               inet_ntoa(cliaddr.sin_addr),
               ntohs(cliaddr.sin_port), buff);
    }

    close(sockfd);
    return 0;
}
