#!/bin/sh
# Setup OpenBSD QEMU VM for kernel development with zart
# Run from: zart/openbsd/
#
# Prerequisites: qemu-system-x86_64, curl/wget
# Downloads OpenBSD 7.9 install image and creates a VM disk

set -e

OPENBSD_VERSION="7.9"
OPENBSD_VER_SHORT="79"
MIRROR="https://cdn.openbsd.org/pub/OpenBSD/${OPENBSD_VERSION}/amd64"
IMG_DIR="$(cd "$(dirname "$0")" && pwd)"
DISK="${IMG_DIR}/openbsd.qcow2"
DISK_SIZE="20G"
RAM="2048"

echo "==> Setting up OpenBSD ${OPENBSD_VERSION} QEMU environment"

# Download install image if not present
if [ ! -f "${IMG_DIR}/install${OPENBSD_VER_SHORT}.img" ]; then
    echo "==> Downloading OpenBSD install image..."
    curl -L -o "${IMG_DIR}/install${OPENBSD_VER_SHORT}.img" "${MIRROR}/install${OPENBSD_VER_SHORT}.img"
fi

# Create disk image
if [ ! -f "${DISK}" ]; then
    echo "==> Creating ${DISK_SIZE} disk image..."
    qemu-img create -f qcow2 "${DISK}" "${DISK_SIZE}"
fi

echo "==> Starting OpenBSD installer in QEMU..."
echo "    NOTE: Complete the installation manually."
echo "    After install, shut down the VM and use run-vm.sh to boot."
echo ""
echo "    Recommended install options:"
echo "      - Use whole disk, auto layout"
echo "      - Enable sshd"
echo "      - Add user 'dev' with doas access"
echo "      - Install comp79.tgz (compiler set - needed for kernel build)"
echo ""

qemu-system-x86_64 \
    -m ${RAM} \
    -smp 2 \
    -drive file="${DISK}",format=qcow2 \
    -cdrom "${IMG_DIR}/install${OPENBSD_VER_SHORT}.img" \
    -boot d \
    -net nic \
    -net user,hostfwd=tcp::2222-:22 \
    -display none \
    -serial mon:stdio
