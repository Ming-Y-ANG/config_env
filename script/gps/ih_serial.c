#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <termios.h>
#include <string.h>
#include "ih_serial.h"

struct termios gl_oldtio;

long serial_get_baudrate(long baudRate)
{
    long BaudR = 0;

    switch(baudRate) {
		case 460800:
			BaudR=B460800;
			break;
		case 230400:
			BaudR=B230400;
			break;
		case 115200:
			BaudR=B115200;
			break;
		case 57600:
			BaudR=B57600;
			break;
		case 38400:
			BaudR=B38400;
			break;
		case 19200:
			BaudR=B19200;
			break;
		case 9600:
			BaudR=B9600;
			break;
		case 4800:
			BaudR=B4800;
			break;
		case 2400:
			BaudR=B2400;
			break;
		case 1200:
			BaudR=B1200;
			break;
		case 600:
			BaudR=B600;
			break;
		case 300:
			BaudR=B300;
			break;
		case 110:
			BaudR=B110;
			break;

		default:
			BaudR=B19200;
    }

    return BaudR;
}

int serial_set_speed(int fd, int speed)
{
	int   status;
	struct termios   Opt;

	tcgetattr(fd, &Opt);

	cfsetispeed(&Opt, serial_get_baudrate(speed));
	cfsetospeed(&Opt, serial_get_baudrate(speed));
	status = tcsetattr(fd, TCSANOW, &Opt);

	if(status != 0){
		//printf("set serial baudrate failed! error=(%d,%s)\n", errno, strerror(errno));
		return -1;
	}

	tcflush(fd,TCIOFLUSH);

    return 0;
}

int serial_set_parity(int fd,int databits,int stopbits,int parity, int crtscts, int xonoff)
{
	struct termios options;

	if(tcgetattr( fd,&options) != 0) {
		fprintf(stderr, "%s get attr failed(%d,%s)\n", __func__, errno, strerror(errno));
		return -1;
	}

    options.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP
                         |INLCR|IGNCR|ICRNL|IXON);
	if(xonoff) options.c_iflag |= IXON;
    options.c_oflag = OPOST;
    options.c_lflag &= ~(ECHO|ECHONL|ICANON|ISIG|IEXTEN);
    options.c_cflag &= ~(CSIZE|PARENB);

	options.c_cflag &= ~CSIZE;

	switch (databits){
		case 5:
			options.c_cflag |= CS5;
			break;
		case 6:
			options.c_cflag |= CS6;
			break;
		case 7:
			options.c_cflag |= CS7;
			break;
		case 8:
			options.c_cflag |= CS8;
			break;
		default:
			//printf("Bad data bit : %d\n", databits);
			options.c_cflag |= CS8;
			return -9;
	}

	switch (parity) {
		case 'n':
		case 'N':
			options.c_cflag &= ~PARENB;   /* Clear parity enable */
			options.c_iflag &= ~INPCK;     /* disable parity checking */
			break;
		case 'o':
		case 'O':
			options.c_cflag |= (PARODD | PARENB);  /* odd*/
			options.c_iflag |= INPCK;             /* Enable parity checking */
			break;
		case 'e':
		case 'E':
			options.c_cflag |= PARENB;     /* Enable parity */
			options.c_cflag &= ~PARODD;   /* even */
			options.c_iflag |= INPCK;       /* Enable parity checking */
			break;
		case 'S':
		case 's':  /*as no parity*/
			options.c_cflag &= ~PARENB;
			options.c_cflag &= ~CSTOPB;   
			options.c_iflag &= ~INPCK;     /* disable parity checking */
		break;
		default:
			//fprintf(stderr, "Bad parity : %c\n", parity);
			options.c_cflag &= ~PARENB;   /* Clear parity enable */
			options.c_iflag &= ~INPCK;     /* disable parity checking */
			return -9;
	}

	switch (stopbits) {
		case 1:
			options.c_cflag &= ~CSTOPB;
			break;
		case 2:
			options.c_cflag |= CSTOPB;
			break;
		default:
			//printf("Bad stop bit : %c\n", stopbits);
			options.c_cflag &= ~CSTOPB;
			return -9;
	}

	options.c_cc[VTIME] = -1; //100ms 
	options.c_cc[VMIN] = 1;

	if(crtscts) options.c_cflag |= CRTSCTS; //enable hw flow control
	else options.c_cflag &= ~CRTSCTS; //disable hw flow control

	options.c_cflag |= CLOCAL;

	tcflush(fd,TCIFLUSH); /* Update the options and do it NOW */

	if (tcsetattr(fd,TCSANOW,&options) != 0){
		//printf("set serial parity failed! Cannot set attribute! error=(%d,%s)\n", errno, strerror(errno));
		return -1;
	}

	return 0;
}

int ih_serial_init(char *dev, int baudrate, int databit, int stopbit, char parity, int rtscts, int xonoff)
{
	int fd, ret;

	fd = open(dev, O_RDWR);
	if(fd < 0){
		return -1;
	}


	tcgetattr(fd, &gl_oldtio);

	ret = serial_set_speed(fd, baudrate);
	if(ret){
		return ret;
	}

	ret = serial_set_parity(fd, databit, stopbit, parity, rtscts, xonoff);
	if(ret){
		return ret;
	}

	return fd;
}

void ih_serial_deinit(int *sfd)
{
	int fd = *sfd;

	if(fd > 0){
		tcsetattr(fd, TCSANOW, &gl_oldtio);
		close(fd);

		*sfd = -1;
	}
}
