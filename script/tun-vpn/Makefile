ARCH ?= x86
USOBJS := ustun.o 
UCOBJS := uctun.o 
OBJS := rs.o

ifeq ($(DEBUG), 1)
CPPFLAGS += -DSEG_TRACE
OBJS += backstrace.o
endif

ifeq ($(ARCH), arm)
USEXE := arm_ustun 
UCEXE := arm_uctun
CROSS_COMPILE := arm-linux-gcc
CPPFLAGS += -DOBLAS_NEON
CPPFLAGS += -mfpu=neon -march=armv7-a -mfloat-abi=softfp
else 
USEXE := x86_ustun 
UCEXE := x86_uctun
CROSS_COMPILE := gcc
#CPPFLAGS += -DOBLAS_AVX -DOCTMAT_ALIGN=64
CPPFLAGS += -DOBLAS_AVX -DOCTMAT_ALIGN=32
CPPFLAGS += -march=native
CFLAGS += -I/root/liburing/build/include -L/root/liburing/build/lib
LIBS += -luring
endif

CPPFLAGS += -funroll-loops -ftree-vectorize -D_GNU_SOURCE 
CFLAGS += -I./ -I./obl
LIBS += -lpthread

ifeq ($(DEBUG), 1)
CFLAGS += -g
LIBS += -ldl
LDFLAGS += -rdynamic
else
CFLAGS += -O2
endif

.PHONY: all
all: $(USEXE) $(UCEXE)
	rm -rf *.o

$(USEXE): $(USOBJS) $(OBJS)
	$(CROSS_COMPILE) $^ $(CPPFLAGS) $(CFLAGS) $(LIBS) $(LDFLAGS) -o $@

$(UCEXE): $(UCOBJS) $(OBJS)
	$(CROSS_COMPILE) $^ $(CPPFLAGS) $(CFLAGS) $(LIBS) $(LDFLAGS) -o $@

$(USOBJS): %.o:%.c
	$(CROSS_COMPILE) $< $(CPPFLAGS) $(CFLAGS) -c -o $@

$(UCOBJS): %.o:%.c
	$(CROSS_COMPILE) $< $(CPPFLAGS) $(CFLAGS) -c -o $@

$(OBJS): %.o:%.c
	$(CROSS_COMPILE) $< $(CPPFLAGS) $(CFLAGS) -c -o $@

.PHONY:clean
clean:
	rm -rf *_ustun *_uctun *.o
