#!/bin/sh
#
# Build zart kernel modules for OpenWrt x86_64.
# Requires: zig, OpenWrt SDK extracted at $SDK path.
#
# Usage:
#   SDK=/path/to/openwrt-sdk ./build.sh
#
set -e

: "${SDK:?Set SDK to OpenWrt SDK root, e.g. /tmp/openwrt-sdk-24.10.1-x86-64_gcc-13.3.0_musl.Linux-x86_64}"

KSRC="$SDK/build_dir/target-x86_64_musl/linux-x86_64/linux-6.6.86"
ZART_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_OBJ="$ZART_ROOT/zig-out/kernel/zart_kernel_amd64.o"
OUT="${OUT:-/tmp}"

if [ ! -f "$KSRC/include/linux/module.h" ]; then
    echo "error: kernel headers not found at $KSRC" >&2
    exit 1
fi

if [ ! -f "$ZIG_OBJ" ]; then
    echo "Building Zig kernel object..."
    (cd "$ZART_ROOT" && zig build kernel)
fi

CFLAGS="-target x86_64-linux-none \
  -nostdinc \
  -include $KSRC/include/linux/kconfig.h \
  -include $KSRC/include/generated/autoconf.h \
  -isystem $KSRC/include \
  -isystem $KSRC/include/uapi \
  -isystem $KSRC/arch/x86/include \
  -isystem $KSRC/arch/x86/include/uapi \
  -isystem $KSRC/arch/x86/include/generated \
  -isystem $KSRC/arch/x86/include/generated/uapi \
  -isystem $KSRC/include/generated \
  -D__KERNEL__ -DMODULE -DCONFIG_X86_64 \
  -mcmodel=kernel -mno-red-zone -fno-PIE -fno-stack-protector \
  -mno-sse -mno-sse2 -mno-mmx -mno-80387 \
  -O2"

build_module() {
    local name="$1"
    local src="$ZART_ROOT/openwrt/${name}.c"
    echo "=== Building ${name}.ko ==="

    # Compile module source
    zig cc $CFLAGS \
        -DKBUILD_MODNAME="\"$name\"" -DKBUILD_BASENAME="\"$name\"" \
        -c "$src" -o "$OUT/${name}.o"

    # Generate and compile .mod.c
    cat > "$OUT/${name}.mod.c" <<EOF
#include <linux/module.h>
#define INCLUDE_VERMAGIC
#include <linux/build-salt.h>
#include <linux/elfnote-lto.h>
#include <linux/vermagic.h>

MODULE_INFO(vermagic, VERMAGIC_STRING);

struct module __this_module
__section(".gnu.linkonce.this_module") = {
    .name = "$name",
    .init = init_module,
    .exit = cleanup_module,
};

BUILD_LTO_INFO;
EOF
    zig cc $CFLAGS \
        -DKBUILD_MODNAME="\"$name\"" -DKBUILD_BASENAME="\"${name}_mod\"" \
        -c "$OUT/${name}.mod.c" -o "$OUT/${name}.mod.o"

    # Link final .ko
    zig cc -target x86_64-linux-none -nostdlib -r \
        "$OUT/${name}.o" "$ZIG_OBJ" "$OUT/${name}.mod.o" \
        -o "$OUT/${name}.ko"

    echo "  -> $OUT/${name}.ko ($(wc -c < "$OUT/${name}.ko") bytes)"
}

build_module zart_test
build_module zart_fib6

echo ""
echo "Done. Modules:"
ls -la "$OUT"/zart_test.ko "$OUT"/zart_fib6.ko
