#!/bin/sh
# Boot the OpenBSD VM for kernel development
# SSH: ssh -p 2222 dev@localhost
# SCP: scp -P 2222 file dev@localhost:

set -e

IMG_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="${IMG_DIR}/openbsd.qcow2"
RAM="2048"

if [ ! -f "${DISK}" ]; then
    echo "Error: ${DISK} not found. Run setup-qemu.sh first."
    exit 1
fi

echo "==> Booting OpenBSD VM"
echo "    SSH: ssh -p 2222 dev@localhost"
echo "    To transfer files: scp -P 2222 <file> dev@localhost:"
echo ""

qemu-system-x86_64 \
    -m ${RAM} \
    -smp 2 \
    -drive file="${DISK}",format=qcow2 \
    -boot c \
    -net nic \
    -net user,hostfwd=tcp::2222-:22 \
    -display none \
    -serial mon:stdio
