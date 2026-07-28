#!/bin/sh
# Run inside the OpenBSD VM after installation (as root)
# Sets up kernel source tree for zart integration

set -e

echo "==> Installing packages..."
pkg_add git

echo "==> Fetching kernel source..."
mkdir -p /usr/src
cd /usr/src
if [ ! -d sys ]; then
    # Use OpenBSD CVS for sys source (matches installed version)
    ftp https://cdn.openbsd.org/pub/OpenBSD/$(uname -r)/sys.tar.gz
    tar xzf sys.tar.gz
    rm sys.tar.gz
fi

echo "==> Setting up kernel config..."
cd /usr/src/sys/arch/amd64/conf
config GENERIC
cd /usr/src/sys/arch/amd64/compile/GENERIC
make obj

echo "==> Ready for zart integration."
echo "    Transfer zart files:"
echo "      scp -P 2222 zig-out/kernel/zart_kernel_amd64.o dev@localhost:"
echo "      scp -P 2222 include/zart.h dev@localhost:"
echo "      scp -P 2222 openbsd/zart_glue.c dev@localhost:"
echo ""
echo "    Then as root:"
echo "      cp ~dev/zart_kernel.o /usr/src/sys/net/"
echo "      cp ~dev/zart.h /usr/src/sys/net/"
echo "      cp ~dev/zart_glue.c /usr/src/sys/net/"
echo "      # See HOWTO.md for kernel build steps"
