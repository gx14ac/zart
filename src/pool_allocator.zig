const std = @import("std");
const Allocator = std.mem.Allocator;

/// Slab-based memory pool allocator.
/// Allocates pages from the OS and carves them into fixed-size slots.
/// Freed slots go onto a per-class free list for O(1) reuse.
/// This eliminates per-object syscall overhead that page_allocator has.
///
/// For allocations larger than max_pool_size, falls through to page_allocator.
pub const PoolAllocator = struct {
    const Self = @This();

    free_lists: [num_size_classes]?[*]u8,
    slabs: ?[*]u8, // linked list of allocated slab pages (next ptr stored in first 8 bytes)

    const slab_size = 16384; // 16K slab pages for better throughput
    const slab_alignment: std.mem.Alignment = std.mem.Alignment.fromByteUnits(4096);
    const num_size_classes = 10; // 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192
    const min_class_size = 16; // minimum 16 bytes (must fit a pointer)
    const max_pool_size = 8192;

    pub fn init() Self {
        return Self{
            .free_lists = [_]?[*]u8{null} ** num_size_classes,
            .slabs = null,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *Self) void {
        var slab = self.slabs;
        while (slab) |s| {
            const next: *align(1) ?[*]u8 = @ptrCast(s);
            const next_slab = next.*;
            std.heap.page_allocator.vtable.free(
                std.heap.page_allocator.ptr,
                s[0..slab_size],
                slab_alignment,
                @returnAddress(),
            );
            slab = next_slab;
        }
        self.slabs = null;
        self.free_lists = [_]?[*]u8{null} ** num_size_classes;
    }

    fn classToSize(class: usize) usize {
        const shift: u6 = @intCast(class + 4); // +4 because min is 16 = 2^4
        return @as(usize, 1) << shift;
    }

    fn sizeToClass(size: usize) ?usize {
        if (size > max_pool_size) return null;
        if (size <= min_class_size) return 0;
        const rounded = std.math.ceilPowerOfTwo(usize, size) catch return null;
        const log2_val = std.math.log2_int(usize, rounded);
        if (log2_val < 4) return 0;
        const class = log2_val - 4;
        if (class >= num_size_classes) return null;
        return class;
    }

    fn getNext(ptr: [*]u8) ?[*]u8 {
        const next_ptr: *align(1) ?[*]u8 = @ptrCast(ptr);
        return next_ptr.*;
    }

    fn setNext(ptr: [*]u8, next: ?[*]u8) void {
        const next_ptr: *align(1) ?[*]u8 = @ptrCast(ptr);
        next_ptr.* = next;
    }

    fn refillSlab(self: *Self, class: usize) void {
        const slot_size = classToSize(class);
        const slab = std.heap.page_allocator.vtable.alloc(
            std.heap.page_allocator.ptr,
            slab_size,
            slab_alignment,
            @returnAddress(),
        ) orelse return;

        // Track this slab for deinit. Use first 8 bytes as next-slab pointer,
        // then carve remaining space into slots. First slot starts after the header.
        const header: *align(1) ?[*]u8 = @ptrCast(slab);
        header.* = self.slabs;
        self.slabs = slab;

        // First slot_size bytes are reserved for the slab header linkage.
        // Carve remaining space into slots.
        const usable_start: usize = slot_size; // skip first slot (used for header)
        const num_slots = (slab_size - usable_start) / slot_size;
        var i: usize = 0;
        while (i < num_slots) : (i += 1) {
            const slot: [*]u8 = slab + usable_start + i * slot_size;
            setNext(slot, self.free_lists[class]);
            self.free_lists[class] = slot;
        }
    }

    const vtable = Allocator.VTable{
        .alloc = poolAlloc,
        .resize = poolResize,
        .remap = poolRemap,
        .free = poolFree,
    };

    fn poolAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const align_bytes: usize = @intCast(alignment.toByteUnits());
        const actual_size = @max(len, align_bytes);

        // Pool slots are at slot_size-aligned offsets from a page-aligned base.
        // Only serve from pool if the requested alignment <= slot_size for the class.
        if (sizeToClass(actual_size)) |class| {
            const slot_size = classToSize(class);
            if (align_bytes <= slot_size) {
                if (self.free_lists[class] == null) {
                    self.refillSlab(class);
                }
                if (self.free_lists[class]) |ptr| {
                    self.free_lists[class] = getNext(ptr);
                    return ptr;
                }
                return null;
            }
        }

        // Large allocation or high alignment: pass through to page_allocator
        return std.heap.page_allocator.vtable.alloc(std.heap.page_allocator.ptr, len, alignment, ret_addr);
    }

    fn poolResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        const align_bytes: usize = @intCast(alignment.toByteUnits());
        const actual_size = @max(buf.len, align_bytes);

        if (sizeToClass(actual_size)) |old_class| {
            const slot_size = classToSize(old_class);
            if (align_bytes <= slot_size) {
                const new_actual = @max(new_len, align_bytes);
                if (sizeToClass(new_actual)) |new_class| {
                    if (old_class == new_class) return true;
                }
                return false;
            }
        }

        // Large or high-alignment: try page_allocator resize
        return std.heap.page_allocator.vtable.resize(std.heap.page_allocator.ptr, buf, alignment, new_len, ret_addr);
    }

    fn poolRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn poolFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ret_addr;
        const align_bytes: usize = @intCast(alignment.toByteUnits());
        const actual_size = @max(buf.len, align_bytes);

        if (sizeToClass(actual_size)) |class| {
            const slot_size = classToSize(class);
            if (align_bytes <= slot_size) {
                const ptr: [*]u8 = buf.ptr;
                setNext(ptr, self.free_lists[class]);
                self.free_lists[class] = ptr;
                return;
            }
        }

        // Large or high-alignment: free via page_allocator
        std.heap.page_allocator.vtable.free(std.heap.page_allocator.ptr, buf, alignment, @returnAddress());
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "sizeToClass boundary values" {
    // min_class_size = 16 → class 0
    try testing.expectEqual(@as(?usize, 0), PoolAllocator.sizeToClass(1));
    try testing.expectEqual(@as(?usize, 0), PoolAllocator.sizeToClass(8));
    try testing.expectEqual(@as(?usize, 0), PoolAllocator.sizeToClass(16));
    // 17..32 → class 1
    try testing.expectEqual(@as(?usize, 1), PoolAllocator.sizeToClass(17));
    try testing.expectEqual(@as(?usize, 1), PoolAllocator.sizeToClass(32));
    // 33..64 → class 2
    try testing.expectEqual(@as(?usize, 2), PoolAllocator.sizeToClass(33));
    try testing.expectEqual(@as(?usize, 2), PoolAllocator.sizeToClass(64));
    // max_pool_size = 8192 → class 9
    try testing.expectEqual(@as(?usize, 9), PoolAllocator.sizeToClass(8192));
    // > max_pool_size → null (fallthrough)
    try testing.expectEqual(@as(?usize, null), PoolAllocator.sizeToClass(8193));
    try testing.expectEqual(@as(?usize, null), PoolAllocator.sizeToClass(16384));
}

test "classToSize roundtrip" {
    for (0..PoolAllocator.num_size_classes) |class| {
        const size = PoolAllocator.classToSize(class);
        // Allocating exactly classToSize bytes should map back to the same class
        try testing.expectEqual(@as(?usize, class), PoolAllocator.sizeToClass(size));
    }
}

test "pool alloc and free basic" {
    var pool = PoolAllocator.init();
    defer pool.deinit();
    const alloc = pool.allocator();

    // Allocate a small object
    const ptr1 = try alloc.alloc(u8, 32);
    @memset(ptr1, 0xAA);
    alloc.free(ptr1);

    // Reallocate - should reuse freed slot
    const ptr2 = try alloc.alloc(u8, 32);
    // Should get the same pointer back from free list
    try testing.expectEqual(ptr1.ptr, ptr2.ptr);
    alloc.free(ptr2);
}

test "pool alloc various sizes" {
    var pool = PoolAllocator.init();
    defer pool.deinit();
    const alloc = pool.allocator();

    // Allocate multiple sizes to exercise different classes
    const p16 = try alloc.alloc(u8, 16);
    const p64 = try alloc.alloc(u8, 64);
    const p256 = try alloc.alloc(u8, 256);
    const p1024 = try alloc.alloc(u8, 1024);

    // Write patterns to verify no corruption
    @memset(p16, 0x11);
    @memset(p64, 0x22);
    @memset(p256, 0x33);
    @memset(p1024, 0x44);

    // Verify patterns
    for (p16) |b| try testing.expectEqual(@as(u8, 0x11), b);
    for (p64) |b| try testing.expectEqual(@as(u8, 0x22), b);
    for (p256) |b| try testing.expectEqual(@as(u8, 0x33), b);
    for (p1024) |b| try testing.expectEqual(@as(u8, 0x44), b);

    alloc.free(p1024);
    alloc.free(p256);
    alloc.free(p64);
    alloc.free(p16);
}

test "pool free list reuse order" {
    var pool = PoolAllocator.init();
    defer pool.deinit();
    const alloc = pool.allocator();

    // Allocate 3 blocks of same size
    const a = try alloc.alloc(u8, 48); // class 2 (64B)
    const b = try alloc.alloc(u8, 48);
    const c = try alloc.alloc(u8, 48);

    // Free in order a, b, c
    alloc.free(a);
    alloc.free(b);
    alloc.free(c);

    // Re-alloc: should come back in LIFO order (c, b, a)
    const r1 = try alloc.alloc(u8, 48);
    const r2 = try alloc.alloc(u8, 48);
    const r3 = try alloc.alloc(u8, 48);

    try testing.expectEqual(c.ptr, r1.ptr);
    try testing.expectEqual(b.ptr, r2.ptr);
    try testing.expectEqual(a.ptr, r3.ptr);

    alloc.free(r1);
    alloc.free(r2);
    alloc.free(r3);
}

test "pool large allocation passthrough" {
    var pool = PoolAllocator.init();
    defer pool.deinit();
    const alloc = pool.allocator();

    // > 8192 should pass through to page_allocator
    const large = try alloc.alloc(u8, 16384);
    @memset(large, 0xFF);
    for (large) |b| try testing.expectEqual(@as(u8, 0xFF), b);
    alloc.free(large);
}

test "pool with Table integration" {
    const Table = @import("table.zig").Table;
    const netip = @import("netip.zig");

    var pool = PoolAllocator.init();
    defer pool.deinit();
    const alloc = pool.allocator();

    var table = Table(i32).init(alloc);
    defer table.deinit();

    // Insert 1000 prefixes
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..1000) |i| {
        const a = random.int(u8);
        const b = random.int(u8);
        const c = random.int(u8);
        const d = random.int(u8);
        const bits = random.intRangeAtMost(u8, 1, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        var pfx = addr.prefix(bits).masked();
        table.insert(&pfx, @as(i32, @intCast(i)));
    }

    try testing.expect(table.size4_count > 0);

    // Delete all
    prng = std.Random.DefaultPrng.init(42);
    const random2 = prng.random();

    for (0..1000) |_| {
        const a = random2.int(u8);
        const b = random2.int(u8);
        const c = random2.int(u8);
        const d = random2.int(u8);
        const bits = random2.intRangeAtMost(u8, 1, 32);
        const addr = netip.Addr.fromIPv4(a, b, c, d);
        var pfx = addr.prefix(bits).masked();
        table.delete(&pfx);
    }

    try testing.expectEqual(@as(i32, 0), table.size4_count);
}

test "pool stress: alloc-free cycle" {
    var pool = PoolAllocator.init();
    defer pool.deinit();
    const alloc = pool.allocator();

    // Rapidly alloc/free to stress the free list
    var ptrs: [100]*[64]u8 = undefined;

    for (0..10) |round| {
        // Allocate batch
        for (&ptrs) |*p| {
            const slice = try alloc.alloc(u8, 64);
            @memset(slice, @as(u8, @intCast(round)));
            p.* = slice[0..64];
        }
        // Verify
        for (ptrs) |p| {
            for (p) |b| {
                try testing.expectEqual(@as(u8, @intCast(round)), b);
            }
        }
        // Free batch
        for (ptrs) |p| {
            alloc.free(p);
        }
    }
}
