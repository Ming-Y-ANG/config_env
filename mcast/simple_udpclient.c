#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>

/**
 * filename: simple_udpclient.c
 * 基本UDP编程客户端
 */

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s <server_ip> [server_port]\n"
            "  server_ip      服务器IP地址\n"
            "  server_port    服务器端口 (默认: 7838)\n"
            "\nExample:\n"
            "  %s 127.0.0.1 7838\n",
            prog, prog);
}

int main(int argc, char *argv[])
{
    struct sockaddr_in servaddr;
    int sockfd;
    socklen_t addr_len;
    ssize_t len;
    char buff[128];

    if (argc < 2) {
        usage(argv[0]);
        exit(EXIT_FAILURE);
    }

    /* 创建socket */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        exit(EXIT_FAILURE);
    }

    /* 设置对方的地址和端口信息 */
    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons((argc > 2) ? atoi(argv[2]) : 7838);

    if (inet_pton(AF_INET, argv[1], &servaddr.sin_addr) <= 0) {
        fprintf(stderr, "错误的服务器IP地址: %s\n", argv[1]);
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    /* 发送UDP消息 */
    addr_len = sizeof(servaddr);
    strcpy(buff, "hello, i'm here");
    len = sendto(sockfd, buff, strlen(buff), 0,
                 (struct sockaddr *)&servaddr, addr_len);
    if (len < 0) {
        perror("sendto");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    printf("[INFO] 发送成功: %s\n", buff);

    close(sockfd);
    return 0;
}
