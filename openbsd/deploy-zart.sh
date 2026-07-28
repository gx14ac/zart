#!/bin/sh
# Build zart kernel object and deploy to OpenBSD VM
# Run from: zart/ root directory

set -e

ZART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_PORT=2222
SSH_HOST="dev@localhost"
SSH="ssh -p ${SSH_PORT} ${SSH_HOST}"
SCP="scp -P ${SSH_PORT}"

echo "==> Building zart kernel object (amd64 freestanding)..."
cd "${ZART_DIR}"
zig build kernel

echo "==> Deploying to OpenBSD VM..."
${SCP} zig-out/kernel/zart_kernel_amd64.o ${SSH_HOST}:zart_kernel.o
${SCP} include/zart.h ${SSH_HOST}:zart.h

echo "==> Done. Files deployed to VM:"
echo "    ~/zart_kernel.o  - relocatable ELF object"
echo "    ~/zart.h         - C header"
echo ""
echo "Next steps (inside VM as root):"
echo "  1. cp ~/zart_kernel.o /usr/src/sys/net/"
echo "  2. cp ~/zart.h /usr/src/sys/net/"
echo "  3. Edit /usr/src/sys/net/art.c to call zart functions"
echo "  4. cd /usr/src/sys/arch/amd64/compile/GENERIC"
echo "  5. make"
echo "  6. cp /usr/src/sys/arch/amd64/compile/GENERIC/obj/bsd /bsd.zart"
echo "  7. reboot (select bsd.zart at boot prompt)"
