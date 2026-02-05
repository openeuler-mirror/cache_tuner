ifneq ($(KERNELRELEASE),)
# kbuild part of makefile
obj-m := cache_stash.o

else
# normal makefile
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(CURDIR)

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	sudo insmod cache_stash.ko

uninstall:
	sudo rmmod cache_stash

.PHONY: default clean install uninstall

endif