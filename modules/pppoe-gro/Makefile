obj-m += pppoe_gro.o
# -g keeps DWARF for layout checks (pahole); the prefix maps make the build
# independent of the checkout and kernel-tree paths, so it is reproducible.
ccflags-y += -g -fdebug-prefix-map=$(srctree)=/kernel -fdebug-prefix-map=$(src)=/module

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
