const std = @import("std");
const bart = @import("main.zig");
const time = std.time;
const Timer = time.Timer;

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

// Benchmark configuration
const Config = struct {
    prefix_count: u32,
    lookup_count: u32,
    prefix_length: u8,
    random_seed: u64,
};

// Run a single benchmark with given configuration
fn runBenchmark(config: Config) !void {
    const stdout = std.io.getStdOut().writer();
    var prng = std.rand.DefaultPrng.init(config.random_seed);
    const random = prng.random();

    // Create and initialize table
    const table = bart.bart_create();
    defer bart.bart_destroy(table);

    // Insert prefixes
    try stdout.print("\nInserting {d} prefixes (/{d}):\n", .{ config.prefix_count, config.prefix_length });
    var insert_timer = try Timer.start();
    var i: u32 = 0;
    while (i < config.prefix_count) : (i += 1) {
        const ip_net = random.int(u32);
        const res = bart.bart_insert4(table, ip_net, config.prefix_length, 1);
        std.debug.assert(res == 0);

        if (i < 3 or i >= config.prefix_count - 3) {
            try stdout.print("  {s}/{d}\n", .{ ip4ToString(ip_net), config.prefix_length });
        } else if (i == 3) {
            try stdout.print("  ...\n", .{});
        }
    }
    const insert_time = insert_timer.read();
    const insert_per_sec = @as(f64, @floatFromInt(config.prefix_count)) / (@as(f64, @floatFromInt(insert_time)) / 1_000_000_000.0);
    try stdout.print("Insert Performance: {d:.2} prefixes/sec\n", .{insert_per_sec});

    // Lookup benchmark
    try stdout.print("\nRunning {d} lookups:\n", .{config.lookup_count});
    var lookup_timer = try Timer.start();
    var j: u32 = 0;
    var found: i32 = 0;
    var match_count: u32 = 0;
    while (j < config.lookup_count) : (j += 1) {
        const ip_addr = random.int(u32);
        _ = bart.bart_lookup4(table, ip_addr, &found);
        if (found != 0) match_count += 1;

        if (j < 3 or j >= config.lookup_count - 3) {
            try stdout.print("  Lookup: {s} -> {s}\n", .{ 
                ip4ToString(ip_addr), 
                if (found != 0) "Match" else "No Match" 
            });
        } else if (j == 3) {
            try stdout.print("  ...\n", .{});
        }
    }
    const lookup_time = lookup_timer.read();
    const lookup_per_sec = @as(f64, @floatFromInt(config.lookup_count)) / (@as(f64, @floatFromInt(lookup_time)) / 1_000_000_000.0);
    const match_rate = @as(f64, @floatFromInt(match_count)) / @as(f64, @floatFromInt(config.lookup_count)) * 100.0;

    try stdout.print("\nBenchmark Results:\n", .{});
    try stdout.print("  Insert Time: {s}\n", .{formatDuration(insert_time)});
    try stdout.print("  Insert Rate: {d:.2} prefixes/sec\n", .{insert_per_sec});
    try stdout.print("  Lookup Time: {s}\n", .{formatDuration(lookup_time)});
    try stdout.print("  Lookup Rate: {d:.2} lookups/sec\n", .{lookup_per_sec});
    try stdout.print("  Match Rate: {d:.2}%\n", .{match_rate});
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Routing Table Benchmark\n", .{});
    try stdout.print("===========================\n", .{});

    // Run benchmarks with different configurations
    const configs = [_]Config{
        .{
            .prefix_count = 1000,
            .lookup_count = 1_000_000,
            .prefix_length = 16,
            .random_seed = 42,
        },
        .{
            .prefix_count = 10000,
            .lookup_count = 1_000_000,
            .prefix_length = 24,
            .random_seed = 42,
        },
        .{
            .prefix_count = 100000,
            .lookup_count = 1_000_000,
            .prefix_length = 32,
            .random_seed = 42,
        },
    };

    for (configs, 0..) |config, i| {
        try stdout.print("\nBenchmark Configuration {d}:\n", .{i + 1});
        try stdout.print("------------------------\n", .{});
        try runBenchmark(config);
    }
}
