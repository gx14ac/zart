#!/bin/sh
# Run inside VM as root: builds kernel with zart test + bench modules
set -e

KSRC=/usr/src/sys
KOBJ=/usr/obj/sys/arch/amd64/compile/GENERIC

echo "==> Setting up zart kernel modules..."

# 1. Ensure conf/files has zart entries
if ! grep -q zart_ktest $KSRC/conf/files; then
    awk '/^file net\/art\.c$/{print; print "file net/zart_ktest.c"; print "file net/zart_bench.c"; next}1' \
        $KSRC/conf/files > /tmp/files.tmp
    mv /tmp/files.tmp $KSRC/conf/files
fi

# 2. Copy zart files to net/
cp /root/zart_ktest.c $KSRC/net/
cp /root/zart_bench.c $KSRC/net/
cp /root/zart_kernel_amd64.o $KSRC/net/zart_kernel.o
cp /root/zart.h $KSRC/net/

# 3. Add extern + calls in rtable.c (only if not already done)
if ! grep -q zart_ktest_run $KSRC/net/rtable.c; then
    awk '
/^#include <net\/art\.h>/{print; print "extern void zart_ktest_run(void);"; print "extern void zart_bench_run(void);"; next}
/art_boot\(\);/{print; printf "\tzart_ktest_run();\n\tzart_bench_run();\n"; next}
1' $KSRC/net/rtable.c > /tmp/rtable.tmp
    mv /tmp/rtable.tmp $KSRC/net/rtable.c
fi

# Verify edits
echo "--- conf/files:"
grep -A2 "art\.c" $KSRC/conf/files | head -5
echo "--- rtable.c:"
grep -n zart $KSRC/net/rtable.c

# 4. Run config
echo "==> Running config GENERIC..."
cd $KSRC/arch/amd64/conf
config GENERIC

# 5. Copy zart_kernel.o to build dir and add Makefile rule
cp $KSRC/net/zart_kernel.o $KOBJ/

if ! grep -q "zart_kernel\.o" $KOBJ/Makefile; then
    awk '/^SYSTEM_OBJ=/{print "OBJS+=\tzart_kernel.o"; print; next}1' \
        $KOBJ/Makefile > /tmp/mf.tmp
    mv /tmp/mf.tmp $KOBJ/Makefile
fi

# Add no-op build rule for pre-built object
if ! grep -q "^zart_kernel.o:" $KOBJ/Makefile; then
    echo "zart_kernel.o:" >> $KOBJ/Makefile
fi

echo "--- Makefile check:"
grep zart $KOBJ/Makefile

# 6. Build
echo "==> Building kernel (this takes ~20 min)..."
cd $KOBJ
make -j2 2>&1 | tail -10

echo "==> Kernel build complete!"
ls -lh $KOBJ/bsd
