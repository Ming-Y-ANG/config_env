# Makefile for UDP/Multicast/Broadcast examples

CC      = gcc
CFLAGS  = -Wall -Wextra -O2
LDFLAGS =

TARGETS = mcastserver mcastclient simple_udpserver simple_udpclient broadc-udpclient broadc-udpserver

SRCS = mcastserver.c mcastclient.c simple_udpserver.c simple_udpclient.c broadc-udpclient.c broadc-udpserver.c

.PHONY: all clean help

all: $(TARGETS)

mcastserver: mcastserver.c
	$(CC) $(CFLAGS) -o $@ $<

mcastclient: mcastclient.c
	$(CC) $(CFLAGS) -o $@ $<

simple_udpserver: simple_udpserver.c
	$(CC) $(CFLAGS) -o $@ $<

simple_udpclient: simple_udpclient.c
	$(CC) $(CFLAGS) -o $@ $<

broadc-udpclient: broadc-udpclient.c
	$(CC) $(CFLAGS) -o $@ $<

broadc-udpserver: broadc-udpserver.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGETS)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all       编译所有程序 (默认)"
	@echo "  clean     清理所有编译生成的可执行文件"
	@echo "  help      显示此帮助信息"
	@echo ""
	@echo "Programs:"
	@echo "  mcastserver       组播服务端"
	@echo "  mcastclient       组播客户端"
	@echo "  simple_udpserver  简单UDP服务端"
	@echo "  simple_udpclient  简单UDP客户端"
	@echo "  broadc-udpclient  广播客户端"
	@echo "  broadc-udpserver  广播接收端"
