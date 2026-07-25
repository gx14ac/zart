const std = @import("std");
const zart = @import("zart_table");
const KernelAllocator = @import("allocator.zig").KernelAllocator;
const panic_mod = @import("panic.zig");

const netip = zart.netip;
const Table = zart.Table(usize);

pub const std_options: std.Options = .{
    .logFn = noopLog,
};

fn noopLog(
    comptime _: std.log.Level,
    comptime _: @Type(.enum_literal),
    comptime _: []const u8,
    _: anytype,
) void {}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    panic_mod.panicImpl(msg);
}

var kernel_alloc_instance: KernelAllocator = undefined;
var kernel_alloc_initialized: bool = false;

export fn zart_init(
    alloc_fn: *const fn (usize, usize) callconv(.c) ?[*]u8,
    free_fn: *const fn ([*]u8, usize) callconv(.c) void,
) callconv(.c) void {
    kernel_alloc_instance = .{
        .vtable = .{
            .alloc_fn = alloc_fn,
            .free_fn = free_fn,
        },
    };
    kernel_alloc_initialized = true;
}

export fn zart_table_create() callconv(.c) ?*Table {
    if (!kernel_alloc_initialized) return null;
    const allocator = kernel_alloc_instance.allocator();
    const t = allocator.create(Table) catch return null;
    t.* = Table.init(allocator);
    return t;
}

export fn zart_table_destroy(t: ?*Table) callconv(.c) void {
    const tbl = t orelse return;
    const allocator = tbl.allocator;
    tbl.deinit();
    allocator.destroy(tbl);
}

export fn zart_table_insert4(
    t: ?*Table,
    addr: [*]const u8,
    prefix_len: u8,
    value: usize,
) callconv(.c) void {
    const tbl = t orelse return;
    const pfx = netip.Prefix.fromIPv4(addr[0], addr[1], addr[2], addr[3], prefix_len);
    tbl.insert(&pfx, value);
}

export fn zart_table_insert6(
    t: ?*Table,
    addr: [*]const u8,
    prefix_len: u8,
    value: usize,
) callconv(.c) void {
    const tbl = t orelse return;
    const pfx = netip.Prefix.fromIPv6(addr[0..16].*, prefix_len);
    tbl.insert(&pfx, value);
}

export fn zart_table_lookup4(
    t: ?*const Table,
    addr: [*]const u8,
    result: *usize,
) callconv(.c) bool {
    const tbl = t orelse return false;
    const ip4 = netip.Addr.fromIPv4(addr[0], addr[1], addr[2], addr[3]);
    const val = tbl.lookup(&ip4);
    if (val.ok) {
        result.* = val.value;
        return true;
    }
    return false;
}

export fn zart_table_lookup6(
    t: ?*const Table,
    addr: [*]const u8,
    result: *usize,
) callconv(.c) bool {
    const tbl = t orelse return false;
    const ip6 = netip.Addr.fromIPv6(addr[0..16].*);
    const val = tbl.lookup(&ip6);
    if (val.ok) {
        result.* = val.value;
        return true;
    }
    return false;
}

export fn zart_table_delete4(
    t: ?*Table,
    addr: [*]const u8,
    prefix_len: u8,
) callconv(.c) void {
    const tbl = t orelse return;
    const pfx = netip.Prefix.fromIPv4(addr[0], addr[1], addr[2], addr[3], prefix_len);
    tbl.delete(&pfx);
}

export fn zart_table_delete6(
    t: ?*Table,
    addr: [*]const u8,
    prefix_len: u8,
) callconv(.c) void {
    const tbl = t orelse return;
    const pfx = netip.Prefix.fromIPv6(addr[0..16].*, prefix_len);
    tbl.delete(&pfx);
}

export fn zart_table_size(t: ?*const Table) callconv(.c) i32 {
    const tbl = t orelse return 0;
    return tbl.size();
}
