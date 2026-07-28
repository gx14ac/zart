# Kbuild Makefile for zart IPv6 FIB module
#
# Build:
#   make -C /path/to/linux M=$(pwd) modules
#
# Or via OpenWrt build system (see package/Makefile)

obj-m := zart_fib6.o
zart_fib6-objs := zart_fib6_mod.o zart_kernel.o

# zart_kernel.o is pre-built from Zig (freestanding, kernel code model)
# Copy from: zig-out/kernel/zart_kernel_amd64.o (x86_64)
#         or: zig-out/kernel/zart_kernel_arm64.o (aarch64)

EXTRA_CFLAGS += -I$(src)/../include

# The Zig object is pre-built; tell kbuild not to try to compile it
$(obj)/zart_kernel.o: $(src)/zart_kernel.o
	cp $< $@
