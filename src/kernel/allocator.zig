// Kernel allocator interface for freestanding environments.
// Binds to OpenBSD pool(9) or any fixed-size slab allocator via C function pointers.

const std = @import("std");

pub const KernelAllocator = struct {
    vtable: VTable,

    pub const VTable = struct {
        alloc_fn: *const fn (size: usize, alignment: usize) callconv(.c) ?[*]u8,
        free_fn: *const fn (ptr: [*]u8, size: usize) callconv(.c) void,
    };

    pub fn allocator(self: *KernelAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *KernelAllocator = @ptrCast(@alignCast(ctx));
        return self.vtable.alloc_fn(len, alignment.toByteUnits());
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *KernelAllocator = @ptrCast(@alignCast(ctx));
        self.vtable.free_fn(@ptrCast(buf.ptr), buf.len);
    }
};
