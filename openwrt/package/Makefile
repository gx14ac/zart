#
# OpenWrt package/feed Makefile for kmod-zart-fib6
#
# Usage:
#   1. Add this repo as a feed in feeds.conf:
#      src-git zart https://github.com/gx14ac/zart.git;main
#   2. ./scripts/feeds update zart && ./scripts/feeds install kmod-zart-fib6
#   3. make menuconfig -> Kernel modules -> Network Support -> kmod-zart-fib6
#   4. make package/kmod-zart-fib6/compile
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=kmod-zart-fib6
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define KernelPackage/zart-fib6
  SUBMENU:=Network Support
  TITLE:=zart IPv6 FIB accelerator
  DEPENDS:=+kmod-ipv6
  FILES:=$(PKG_BUILD_DIR)/zart_fib6.ko
  AUTOLOAD:=$(call AutoLoad,30,zart_fib6)
endef

define KernelPackage/zart-fib6/description
  Replaces Linux IPv6 FIB lookup with zart fixed 8-bit stride trie.
  Provides 3.75x faster longest-prefix-match for IPv6 routing.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/../../openwrt/zart_fib6.c $(PKG_BUILD_DIR)/zart_fib6_mod.c
	$(CP) $(CURDIR)/../../openwrt/Makefile.kbuild $(PKG_BUILD_DIR)/Makefile
	$(CP) $(CURDIR)/../../include/zart.h $(PKG_BUILD_DIR)/
	# Pre-build zart kernel object for target arch
	cd $(CURDIR)/../.. && \
		zig build kernel -Doptimize=ReleaseFast 2>/dev/null || true
	if [ "$(ARCH)" = "x86_64" ] || [ "$(ARCH)" = "x86" ]; then \
		$(CP) $(CURDIR)/../../zig-out/kernel/zart_kernel_amd64.o \
			$(PKG_BUILD_DIR)/zart_kernel.o; \
	elif [ "$(ARCH)" = "aarch64" ] || [ "$(ARCH)" = "arm64" ]; then \
		$(CP) $(CURDIR)/../../zig-out/kernel/zart_kernel_arm64.o \
			$(PKG_BUILD_DIR)/zart_kernel.o; \
	fi
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)" \
		EXTRA_CFLAGS="-I$(PKG_BUILD_DIR)" \
		modules
endef

$(eval $(call KernelPackage,zart-fib6))
