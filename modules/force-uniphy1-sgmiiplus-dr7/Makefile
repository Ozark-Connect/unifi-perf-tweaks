obj-m += force_uniphy1_sgmiiplus_dr7.o

# Cross-compile on an ARM64 host:
#   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source
#
# The kernel source must match: 5.4.213-ui-ipq5322-wireless
# Extract config from router:
#   ssh root@<router-ip> "zcat /proc/config.gz" > .config

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
