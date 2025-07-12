const std = @import("std");
const print = std.debug.print;
const Timer = std.time.Timer;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🚀 **Insert Performance Test**\n", .{});
    print("==============================\n\n", .{});

    // 🎯 Insert Performance Test
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // Warmup
    for (0..1000) |i| {
        const addr = IPAddr{ .v4 = .{ 10, 0, @as(u8, @intCast(i % 256)), @as(u8, @intCast((i * 3) % 256)) } };
        const prefix = Prefix.init(&addr, 24);
        table.insert(&prefix, @as(u32, @intCast(i)));
    }
    
    // Benchmark insert operations
    const insert_iterations: u32 = 100_000;
    var timer = Timer.start() catch unreachable;
    
    for (0..insert_iterations) |i| {
        const addr = IPAddr{ .v4 = .{ 192, 168, @as(u8, @intCast(i % 256)), @as(u8, @intCast((i * 7) % 256)) } };
        const prefix = Prefix.init(&addr, 24);
        table.insert(&prefix, @as(u32, @intCast(i)));
    }
    
    const elapsed = timer.read();
    const ns_per_insert = elapsed / insert_iterations;
    
    print("📊 **Insert Performance Results**\n", .{});
    print("----------------------------------\n", .{});
    print("Insert: {d:.1} ns/op (iterations: {d})\n", .{ @as(f64, @floatFromInt(ns_per_insert)), insert_iterations });
    print("\n", .{});
    
    print("🎯 **Go BART Comparison**\n", .{});
    print("-------------------------\n", .{});
    print("Go BART Insert: ~15.0 ns/op\n", .{});
    print("\n", .{});
    
    const ratio = @as(f64, @floatFromInt(ns_per_insert)) / 15.0;
    print("📈 **Performance Ratio**\n", .{});
    print("------------------------\n", .{});
    print("Insert: {d:.1}x Go BART", .{ratio});
    
    if (ratio <= 1.2) {
        print(" 🥇 Excellent\n", .{});
    } else if (ratio <= 2.0) {
        print(" 🥈 Very Good\n", .{});
    } else if (ratio <= 5.0) {
        print(" 🥉 Good\n", .{});
    } else {
        print(" 🔄 Needs Improvement\n", .{});
    }
    
    print("\n✅ **Insert test completed successfully!**\n", .{});
} 