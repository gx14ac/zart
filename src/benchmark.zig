const std = @import("std");
const bart = @import("main.zig");

// Global buffers
var ip_buf: [16]u8 = undefined;
var duration_buf: [32]u8 = undefined;

// IPアドレスを文字列形式に変換する関数
fn ip4ToString(ip: u32) []const u8 {
    const bytes = [_]u8{
        @as(u8, @truncate((ip >> 24) & 0xFF)),
        @as(u8, @truncate((ip >> 16) & 0xFF)),
        @as(u8, @truncate((ip >> 8) & 0xFF)),
        @as(u8, @truncate(ip & 0xFF)),
    };
    return std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch "error";
}

// 時間を適切な単位で表示する関数
fn formatDuration(ns: u64) []const u8 {
    if (ns < 1000) {
        return std.fmt.bufPrint(&duration_buf, "{d}ns", .{ns}) catch "error";
    } else if (ns < 1_000_000) {
        return std.fmt.bufPrint(&duration_buf, "{d:.2}μs", .{@as(f64, @floatFromInt(ns)) / 1000.0}) catch "error";
    } else if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(&duration_buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch "error";
    } else {
        return std.fmt.bufPrint(&duration_buf, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch "error";
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Routing Table Benchmark\n", .{});
    try stdout.print("===========================\n", .{});

    // Create routing table for benchmark
    const table = bart.bart_create();
    defer {
        bart.bart_destroy(table);
    }

    // Register prefixes
    const prefix_count = 1000;
    try stdout.print("\nPrefix Registration:\n", .{});
    try stdout.print("  Count: {d} prefixes (/16)\n", .{prefix_count});

    // Display first 3 and last 3 prefixes
    try stdout.print("  Examples:\n", .{});
    var i: u32 = 0;
    while (i < prefix_count) : (i += 1) {
        const ip_net = i << 16;
        const res = bart.bart_insert4(table, ip_net, 16, 1);
        std.debug.assert(res == 0);

        // Display first 3 and last 3 prefixes
        if (i < 3 or i >= prefix_count - 3) {
            try stdout.print("    {s}/16\n", .{ip4ToString(ip_net)});
        } else if (i == 3) {
            try stdout.print("    ...\n", .{});
        }
    }

    // Lookup benchmark
    const lookup_count = 1000000;
    try stdout.print("\nLookup Benchmark:\n", .{});
    try stdout.print("  Iterations: {d}\n", .{lookup_count});

    var timer = std.time.Timer.start() catch unreachable;
    var j: u32 = 0;
    var found: i32 = 0;
    while (j < lookup_count) : (j += 1) {
        const prefix_index = j % prefix_count;
        const ip_addr = (prefix_index << 16) | (j & 0xFFFF);
        _ = bart.bart_lookup4(table, ip_addr, &found);
        std.debug.assert(found != 0);

        // Display first 3 and last 3 lookups
        if (j < 3 or j >= lookup_count - 3) {
            try stdout.print("    Lookup: {s} -> Match\n", .{ip4ToString(ip_addr)});
        } else if (j == 3) {
            try stdout.print("    ...\n", .{});
        }
    }

    const total_ns = timer.read();
    const avg_ns = total_ns / lookup_count;

    try stdout.print("\nBenchmark Results:\n", .{});
    try stdout.print("  Total Time: {s}\n", .{formatDuration(total_ns)});
    try stdout.print("  Average Time: {s}/lookup\n", .{formatDuration(avg_ns)});
    try stdout.print("  Throughput: {d:.2} lookups/sec\n", .{@as(f64, @floatFromInt(lookup_count)) / (@as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0)});
}
