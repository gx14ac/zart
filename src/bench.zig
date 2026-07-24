// ZART Benchmarks - Go BART compatible benchmark suite
// Port of Go BART's table_test.go benchmarks
//
// Run with: zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const netip = @import("netip.zig");
const Table = @import("table.zig").Table;
const pool_allocator = @import("pool_allocator.zig");

var int_sink: i32 = 0;
var bool_sink: bool = false;

fn doNotOptimize(val: anytype) void {
    const T = @TypeOf(val);
    const ptr: *volatile T = @ptrCast(@constCast(&val));
    _ = ptr.*;
}

fn generateRandomPrefixes(allocator: std.mem.Allocator, count: usize, seed: u64, is4: bool) ![]netip.Prefix {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const prefixes = try allocator.alloc(netip.Prefix, count);
    for (prefixes) |*pfx| {
        if (is4) {
            const a = random.int(u8);
            const b = random.int(u8);
            const c = random.int(u8);
            const d = random.int(u8);
            const bits = random.intRangeAtMost(u8, 1, 32);
            const addr = netip.Addr.fromIPv4(a, b, c, d);
            pfx.* = addr.prefix(bits).masked();
        } else {
            var addr_bytes: [16]u8 = undefined;
            for (&addr_bytes) |*byte| {
                byte.* = random.int(u8);
            }
            const bits = random.intRangeAtMost(u8, 1, 128);
            const addr = netip.Addr.fromIPv6(addr_bytes);
            pfx.* = addr.prefix(bits).masked();
        }
    }
    return prefixes;
}

fn benchInsert(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var timer = std.time.Timer.start() catch unreachable;

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    return timer.read();
}

fn benchGet(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    var timer = std.time.Timer.start() catch unreachable;

    for (prefixes) |*pfx| {
        const val = table.get(pfx);
        doNotOptimize(val);
    }

    return timer.read();
}

fn benchLPM(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // Generate lookup addresses
    const lookup_addrs = try generateRandomPrefixes(allocator, count, 99999, is4);
    defer allocator.free(lookup_addrs);

    var timer = std.time.Timer.start() catch unreachable;

    for (lookup_addrs) |*pfx| {
        const addr = pfx.addr();
        const result = table.lookup(&addr);
        doNotOptimize(result);
    }

    return timer.read();
}

fn benchLPMHot(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // Single probe (same as Go BART bench)
    const probe_addr = prefixes[count / 2].addr();

    var timer = std.time.Timer.start() catch unreachable;

    for (0..count * 10) |_| {
        const result = table.lookup(&probe_addr);
        doNotOptimize(result);
    }

    return timer.read();
}

fn benchDelete(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    var timer = std.time.Timer.start() catch unreachable;

    for (prefixes) |*pfx| {
        table.delete(pfx);
    }

    return timer.read();
}

fn benchClone(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    var timer = std.time.Timer.start() catch unreachable;

    const cloned = try table.Clone(allocator);
    cloned.deinit();
    allocator.destroy(cloned);

    return timer.read();
}

fn benchUnion(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes_a = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes_a);
    const prefixes_b = try generateRandomPrefixes(allocator, count, 67890, is4);
    defer allocator.free(prefixes_b);

    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    for (prefixes_a, 0..) |*pfx, i| {
        table_a.insert(pfx, @as(i32, @intCast(i)));
    }
    for (prefixes_b, 0..) |*pfx, i| {
        table_b.insert(pfx, @as(i32, @intCast(i)));
    }

    // Clone table_a so we can benchmark just the union
    const target = try table_a.Clone(allocator);
    defer {
        target.deinit();
        allocator.destroy(target);
    }

    var timer = std.time.Timer.start() catch unreachable;

    try target.Union(&table_b);

    return timer.read();
}

fn benchOverlaps(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes_a = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes_a);
    const prefixes_b = try generateRandomPrefixes(allocator, count, 67890, is4);
    defer allocator.free(prefixes_b);

    var table_a = Table(i32).init(allocator);
    defer table_a.deinit();
    var table_b = Table(i32).init(allocator);
    defer table_b.deinit();

    for (prefixes_a, 0..) |*pfx, i| {
        table_a.insert(pfx, @as(i32, @intCast(i)));
    }
    for (prefixes_b, 0..) |*pfx, i| {
        table_b.insert(pfx, @as(i32, @intCast(i)));
    }

    var timer = std.time.Timer.start() catch unreachable;

    doNotOptimize(table_a.overlaps(&table_b));

    return timer.read();
}

fn benchInsertHot(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // Same methodology as Go BART: insert same single probe repeatedly (overwrite path)
    const probe = prefixes[count / 2];

    var timer = std.time.Timer.start() catch unreachable;

    for (0..count * 10) |i| {
        table.insert(&probe, @as(i32, @intCast(i)));
    }

    return timer.read();
}

fn benchDeleteHot(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // Same methodology as Go BART: delete same single probe repeatedly (not-found after first)
    const probe = prefixes[count / 2];

    var timer = std.time.Timer.start() catch unreachable;

    for (0..count * 10) |_| {
        table.delete(&probe);
    }

    return timer.read();
}

fn benchGetHot(allocator: std.mem.Allocator, count: usize, is4: bool) !u64 {
    const prefixes = try generateRandomPrefixes(allocator, count, 12345, is4);
    defer allocator.free(prefixes);

    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (prefixes, 0..) |*pfx, i| {
        table.insert(pfx, @as(i32, @intCast(i)));
    }

    // Single probe get (like Go BART)
    const probe_pfx = prefixes[count / 2];

    var timer = std.time.Timer.start() catch unreachable;

    for (0..count * 10) |_| {
        doNotOptimize(table.get(&probe_pfx));
    }

    return timer.read();
}

const BenchResult = struct {
    name: []const u8,
    ns_total: u64,
    count: usize,
    ns_per_op: u64,
};

fn runBench(name: []const u8, count: usize, iterations: usize, bench_fn: *const fn (std.mem.Allocator, usize, bool) anyerror!u64, is4: bool) !BenchResult {
    return runBenchWithOps(name, count, iterations, count * iterations, bench_fn, is4);
}

// Global pool shared across benchmarks — stays warm between iterations,
// analogous to Go's GC TLAB reuse across benchmark runs.
var global_pool: pool_allocator.PoolAllocator = pool_allocator.PoolAllocator.init();

fn runBenchWithOps(name: []const u8, count: usize, iterations: usize, total_ops: usize, bench_fn: *const fn (std.mem.Allocator, usize, bool) anyerror!u64, is4: bool) !BenchResult {
    const allocator = global_pool.allocator();
    var total_ns: u64 = 0;

    for (0..iterations) |_| {
        total_ns += try bench_fn(allocator, count, is4);
    }

    return .{
        .name = name,
        .ns_total = total_ns,
        .count = total_ops,
        .ns_per_op = total_ns / total_ops,
    };
}

fn printResult(result: BenchResult) void {
    std.debug.print("{s:<40} {d:>10} ops  {d:>8} ns/op  ({d:.2} ms total)\n", .{
        result.name,
        result.count,
        result.ns_per_op,
        @as(f64, @floatFromInt(result.ns_total)) / 1_000_000.0,
    });
}

pub fn main() !void {
    std.debug.print("\n=== ZART Benchmark Suite ===\n\n", .{});

    const counts = [_]usize{ 100, 1_000, 10_000, 100_000 };
    const iterations = 3;

    for (counts) |count| {
        std.debug.print("--- N={d} ({d} iterations) ---\n", .{ count, iterations });

        // IPv4
        printResult(try runBench("Insert/IPv4", count, iterations, &benchInsert, true));
        printResult(try runBenchWithOps("InsertHot/IPv4", count, iterations, count * 10 * iterations, &benchInsertHot, true));
        printResult(try runBench("Get/IPv4", count, iterations, &benchGet, true));
        printResult(try runBenchWithOps("GetHot/IPv4", count, iterations, count * 10 * iterations, &benchGetHot, true));
        printResult(try runBench("LPM/IPv4", count, iterations, &benchLPM, true));
        printResult(try runBenchWithOps("LPM-hot/IPv4", count, iterations, count * 10 * iterations, &benchLPMHot, true));
        printResult(try runBench("Delete/IPv4", count, iterations, &benchDelete, true));
        printResult(try runBenchWithOps("DeleteHot/IPv4", count, iterations, count * 10 * iterations, &benchDeleteHot, true));
        printResult(try runBench("Clone/IPv4", count, iterations, &benchClone, true));
        printResult(try runBench("Union/IPv4", count, iterations, &benchUnion, true));
        printResult(try runBench("Overlaps/IPv4", count, iterations, &benchOverlaps, true));

        // IPv6
        printResult(try runBench("Insert/IPv6", count, iterations, &benchInsert, false));
        printResult(try runBenchWithOps("InsertHot/IPv6", count, iterations, count * 10 * iterations, &benchInsertHot, false));
        printResult(try runBench("Get/IPv6", count, iterations, &benchGet, false));
        printResult(try runBenchWithOps("GetHot/IPv6", count, iterations, count * 10 * iterations, &benchGetHot, false));
        printResult(try runBench("LPM/IPv6", count, iterations, &benchLPM, false));
        printResult(try runBenchWithOps("LPM-hot/IPv6", count, iterations, count * 10 * iterations, &benchLPMHot, false));
        printResult(try runBench("Delete/IPv6", count, iterations, &benchDelete, false));
        printResult(try runBenchWithOps("DeleteHot/IPv6", count, iterations, count * 10 * iterations, &benchDeleteHot, false));
        printResult(try runBench("Clone/IPv6", count, iterations, &benchClone, false));
        printResult(try runBench("Union/IPv6", count, iterations, &benchUnion, false));
        printResult(try runBench("Overlaps/IPv6", count, iterations, &benchOverlaps, false));

        std.debug.print("\n", .{});
    }
}
