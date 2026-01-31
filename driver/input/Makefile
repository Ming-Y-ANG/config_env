obj-m := input-button.o input-polled-button.o polled-ins.o

#KERNELDIR ?= /lib/modules/$(shell uname -r)/build
KERNELDIR :=/home/ym/stm32/kernel/demo-linux-5.4.31
CROSS_COMPILE:=arm-none-linux-gnueabihf-
CC:=$(CROSS_COMPILE)gcc
CXX:=$(CROSS_COMPILE)g++
AR:=$(CROSS_COMPILE)ar
STRIP:=$(CROSS_COMPILE)strip
LD:=$(CROSS_COMPILE)ld
RANLIB:=$(CROSS_COMPILE)ranlib
READELF:=$(CROSS_COMPILE)readelf

all default: modules
install: modules_install

modules modules_install help clean:
	$(MAKE) -C $(KERNELDIR) M=$(shell pwd) $@
