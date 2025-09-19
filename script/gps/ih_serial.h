#ifndef __IH_SERIAL_H__
#define __IH_SERIAL_H__

long serial_get_baudrate(long baudRate);
int serial_set_speed(int fd, int speed);
int serial_set_parity(int fd,int databits,int stopbits,int parity, int crtscts, int xonoff);
int ih_serial_init(char *dev, int baudrate, int databit, int stopbit, char parity, int rtscts, int xonoff);
void ih_serial_deinit(int *fd);

#endif /* __IH_SERIAL_H__*/
