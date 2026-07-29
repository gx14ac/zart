# zart on OpenWrt

## Overview

zart replaces Linux's IPv6 FIB lookup with a fixed 8-bit stride trie.
IPv6 LPM resolves in exactly 16 memory accesses (3.75x faster than stock fib6).

## Architecture

```
┌─────────────────────────────────────────────┐
│ Linux Kernel (OpenWrt)                      │
│                                             │
│  ip6_route_input()                          │
│       │                                     │
│       ▼                                     │
│  fib6_rule_lookup()                         │
│       │                                     │
│       ├─── zart_fib6_lookup() ◄── fast path │
│       │         │                           │
│       │         ▼                           │
│       │    zart_table_lookup6()             │
│       │    (16 memory accesses)             │
│       │                                     │
│       └─── fib6_table_lookup() ◄── fallback │
│                                             │
│  FIB notifier ──► zart_fib6_event()         │
│  (route add/del syncs to zart table)        │
└─────────────────────────────────────────────┘
```

## Quick Start

### 1. Build zart kernel object

```sh
cd /path/to/zart
zig build kernel -Doptimize=ReleaseFast
# Output: zig-out/kernel/zart_kernel_amd64.o (or arm64)
```

### 2. As OpenWrt feed

Add to `feeds.conf.default`:
```
src-git zart https://github.com/gx14ac/zart.git;main
```

Then:
```sh
./scripts/feeds update zart
./scripts/feeds install kmod-zart-fib6
make menuconfig  # Enable: Kernel modules -> Network Support -> kmod-zart-fib6
make package/kmod-zart-fib6/compile V=s
```

### 3. Manual cross-build (with build.sh)

```sh
# Download OpenWrt SDK
wget https://downloads.openwrt.org/releases/24.10.1/targets/x86/64/openwrt-sdk-24.10.1-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst
tar xf openwrt-sdk-*.tar.zst

# Build both modules (zart_test.ko + zart_fib6.ko)
SDK=/path/to/openwrt-sdk-24.10.1-x86-64_gcc-13.3.0_musl.Linux-x86_64 ./build.sh

# Deploy to router
scp -O /tmp/zart_fib6.ko root@router:/tmp/
ssh root@router insmod /tmp/zart_fib6.ko
```

Key flags (required for Linux kernel modules):
- `-mno-sse -mno-sse2 -mno-mmx -mno-80387`: kernel cannot use FPU/SSE
- `-mcmodel=kernel -mno-red-zone`: standard kernel code model
- `-fno-PIE -fno-stack-protector`: no userspace features

### 4. Verify

```sh
dmesg | grep zart
# zart: IPv6 FIB accelerator loaded (16-access LPM)

# Check it's receiving route updates
ip -6 route add 2001:db8::/32 dev eth0
dmesg | tail -1
```

## How it works

1. **Module load**: `zart_fib6_init()` creates a zart table, registers a FIB notifier
2. **Route sync**: Every `ip -6 route add/del` triggers `zart_fib6_event()` which shadows the route into zart
3. **Lookup**: `zart_fib6_lookup()` is called from the patched FIB path — returns `fib6_info*` directly
4. **Fallback**: If zart returns NULL (miss), the stock fib6 tree walk runs as usual

## Integration approaches

### A. Loadable module with sysctl hook (least invasive)

The module registers a sysctl (`net.ipv6.zart_enable`). When enabled,
`ip6_route_input_slow()` calls `zart_fib6_lookup()` first. No kernel source patch needed
if using ftrace/kprobe to hook the lookup path.

### B. Direct kernel patch (best performance)

Patch `net/ipv6/route.c`:
```c
static struct fib6_info *
ip6_route_info_lookup(struct net *net, const struct in6_addr *daddr, ...)
{
    struct fib6_info *f6i;

    /* Fast path: zart */
    f6i = zart_fib6_lookup(net, daddr);
    if (f6i)
        return f6i;

    /* Fallback: stock fib6 */
    return fib6_table_lookup(net, ...);
}
```

### C. eBPF/XDP (userspace-friendly)

Expose zart as a BPF map type for XDP programs. Useful for edge routers
doing policy routing in XDP before the packet hits the kernel FIB.

## Target platforms

| Platform | Arch    | Zig target               | Kernel .o             |
|----------|---------|--------------------------|------------------------|
| x86_64   | amd64   | x86_64-freestanding      | zart_kernel_amd64.o   |
| ARM64    | aarch64 | aarch64-freestanding     | zart_kernel_arm64.o   |
| MIPS     | mips    | mips-freestanding (TODO) | zart_kernel_mips.o    |

Most OpenWrt routers are MIPS or ARM64. ARM64 is already supported.
MIPS requires adding a build target in `build.zig`.
