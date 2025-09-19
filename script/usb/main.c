#include "libusb.h"
#include <stdio.h>
#include <string.h>
#include <stddef.h>

int find_device_by_product(const char *target_product, int nmemb, char (*obuf)[32]) 
{
    libusb_device **devs;
    libusb_context *ctx = NULL;
    int ret;
	int find = 0;

	if(!target_product || !obuf || nmemb <= 0){
		return -1;
	}

    // 初始化 libusb
    ret = libusb_init(&ctx);
    if (ret < 0) {
        printf( "inint failed: %s\n", libusb_error_name(ret));
        return -1;
    }

    // 获取设备列表
    ssize_t cnt = libusb_get_device_list(ctx, &devs);
    if (cnt < 0) {
        printf("get list failed\n");
        libusb_exit(ctx);
        return -1;
    }

    for (ssize_t i = 0; i < cnt; i++) {
        libusb_device *dev = devs[i];
        struct libusb_device_descriptor desc;
        libusb_device_handle *handle = NULL;
        char product[256] = {0};

        ret = libusb_get_device_descriptor(dev, &desc);
        if (ret < 0) {
            continue;
        }

        ret = libusb_open(dev, &handle);
        if (ret == LIBUSB_SUCCESS) {
            if (desc.iProduct > 0) {
                ret = libusb_get_string_descriptor_ascii(handle, desc.iProduct, (unsigned char *)product, sizeof(product));
            }
            libusb_close(handle);
			if (ret < 0) {
				continue;
			}
        }

        if (!strcmp(product, target_product)) {
			uint8_t bus = libusb_get_bus_number(dev);
            uint8_t port_path[8] = {0};
            char port_str[16] = {0};
            int offset = 0;

            int path_len = libusb_get_port_numbers(dev, port_path, sizeof(port_path));
            for (int j = 0; j < path_len; j++) {
                offset += snprintf(port_str + offset, sizeof(port_str) - offset,
                                 "%d%s", port_path[j], (j < path_len - 1) ? "." : "");
            }

            printf("\n找到目标设备:\n");
            printf("  Product: %s\n", product);
            printf("  VID:PID: %04x:%04x\n", desc.idVendor, desc.idProduct);

			snprintf(obuf[find], sizeof(obuf[find]), "%d-%s", bus, port_str);
			find++;
			if(find >= nmemb){
				break;
			}
        }
    }

    // 释放资源
    libusb_free_device_list(devs, 1);
    libusb_exit(ctx);

	return find;
}

int main(int argc, char **argv) 
{
	char dev[2][32] = {0};

	if(argc != 2){
		printf("usage: %s product\n", argv[0]);
		return -1;
	}

    int ret = find_device_by_product(argv[1], 2, dev);
	for(int i = 0; i < ret; i++){
		printf("find in %s\n", dev[i]);
	}

    return 0;
}

