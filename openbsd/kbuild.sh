#!/bin/sh
# Run inside VM as root: builds kernel with zart test module
set -e

KSRC=/usr/src/sys
KOBJ=/usr/obj/sys/arch/amd64/compile/GENERIC

echo "==> Setting up zart kernel test..."

# 1. Ensure conf/files has zart_ktest
if ! grep -q zart_ktest $KSRC/conf/files; then
    awk '/^file net\/art\.c$/{print; print "file net/zart_ktest.c"; next}1' \
        $KSRC/conf/files > /tmp/files.tmp
    mv /tmp/files.tmp $KSRC/conf/files
fi

# 2. Copy zart files to net/
cp /root/zart_ktest.c $KSRC/net/
cp /root/zart_kernel_amd64.o $KSRC/net/zart_kernel.o
cp /root/zart.h $KSRC/net/

# 3. Add extern + call in rtable.c (only if not already done)
if ! grep -q zart_ktest_run $KSRC/net/rtable.c; then
    awk '
/^#include <net\/art\.h>/{print; print "extern void zart_ktest_run(void);"; next}
/art_boot\(\);/{print; printf "\tzart_ktest_run();\n"; next}
1' $KSRC/net/rtable.c > /tmp/rtable.tmp
    mv /tmp/rtable.tmp $KSRC/net/rtable.c
fi

# Verify edits
echo "--- conf/files:"
grep -A1 "art\.c" $KSRC/conf/files | head -3
echo "--- rtable.c:"
grep -n zart $KSRC/net/rtable.c

# 4. Run config
echo "==> Running config GENERIC..."
cd $KSRC/arch/amd64/conf
config GENERIC

# 5. Copy zart_kernel.o to build dir
cp $KSRC/net/zart_kernel.o $KOBJ/

# 6. Add zart_kernel.o to OBJS in Makefile (if not present)
if ! grep -q "zart_kernel\.o" $KOBJ/Makefile; then
    awk '/^SYSTEM_OBJ=/{print "OBJS+=\tzart_kernel.o"; print; next}1' \
        $KOBJ/Makefile > /tmp/mf.tmp
    mv /tmp/mf.tmp $KOBJ/Makefile
fi

echo "--- Makefile check:"
grep zart $KOBJ/Makefile

# 7. Build
echo "==> Building kernel (this takes ~20 min)..."
cd $KOBJ
make -j2 2>&1 | tail -30

echo "==> Kernel build complete!"
ls -lh $KOBJ/bsd
