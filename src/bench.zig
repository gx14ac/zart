//! Basic benchmark tests
//! 
//! This benchmark tests the following items:
//! 1. Basic lookup performance (single-threaded)
//! 2. Performance in simple usage patterns
//! 3. Basic memory usage
//! 
//! Main purposes:
//! - Measure baseline performance
//! - Evaluate performance in single-threaded environments
//! - Verify optimization in simple usage patterns
//! 
//! Notes:
//! - Single-threaded testing only
//! - Uses relatively simple IP address patterns
//! - Does not consider memory fragmentation effects

const std = @import("std");
const bart = @import("main.zig");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("unistd.h");
});

// Function to measure memory usage
fn measureMemoryUsage() usize {
    if (comptime builtin.target.os.tag == .linux) {
        var usage: usize = 0;
        if (std.os.linux.sysinfo(&usage) == 0) {
            return usage;
        }
    } else if (comptime builtin.target.os.tag == .macos) {
        // macOS: get RSS using ps command
        var argv_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&argv_buf, "{d}", .{c.getpid()}) catch return 0;
        var child = std.process.Child.init(&[_][]const u8{
            "ps", "-o", "rss=", "-p", pid_str,
        }, std.heap.page_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        child.spawn() catch return 0;
        var out_buf: [64]u8 = undefined;
        const n = child.stdout.?.readAll(&out_buf) catch return 0;
        _ = child.wait() catch return 0;
        const trimmed = std.mem.trim(u8, out_buf[0..n], &std.ascii.whitespace);
        const rss_kb = std.fmt.parseInt(usize, trimmed, 10) catch return 0;
        return rss_kb * 1024;
    }
    return 0;
}

// Define benchmark result structure as common type
const BenchmarkResult = struct {
    prefix_count: usize,
    insert_time: u64,
    insert_rate: f64,
    lookup_time: u64,
    lookup_rate: f64,
    match_rate: f64,
    memory_usage: usize,
    cache_hit_rate: f64, // Fixed at 0 for bench since no cache testing
};

// Function to write benchmark results to CSV
fn writeBenchmarkResultsToCSV(
    results: []const BenchmarkResult,
    filename: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    const writer = file.writer();
    try writer.writeAll("prefix_count,insert_time_ns,insert_rate,lookup_time_ns,lookup_rate,match_rate,memory_usage_bytes,cache_hit_rate\n");
    for (results) |result| {
        try writer.print("{d},{d},{d:.2},{d},{d:.2},{d:.2},{d},{d:.2}\n", .{
            result.prefix_count,
            result.insert_time,
            result.insert_rate,
            result.lookup_time,
            result.lookup_rate,
            result.match_rate,
            result.memory_usage,
            result.cache_hit_rate,
        });
    }
}

// Change runBenchmark return value to BenchmarkResult
fn runBenchmark(numPrefixes: usize, prefixLen: u8) !BenchmarkResult {
    // Create routing table
    const table = bart.bart_create();
    defer bart.bart_destroy(table);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\nBenchmark Configuration:\n", .{});
    try stdout.print("------------------------\n\n", .{});
    try stdout.print("Inserting {d} prefixes (/{d}):\n", .{ numPrefixes, prefixLen });
    // Start memory usage measurement
    const memBefore = measureMemoryUsage();
    const startTime = std.time.milliTimestamp();
    // Insert prefixes
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var i: usize = 0;
    while (i < numPrefixes) : (i += 1) {
        const addr = random.int(u32);
        _ = bart.bart_insert4(table, addr, prefixLen, 1);
        if (i < 3 or i > numPrefixes - 3) {
            try stdout.print("  {d}.{d}.{d}.{d}/{d}\n", .{
                (addr >> 24) & 0xFF,
                (addr >> 16) & 0xFF,
                (addr >> 8) & 0xFF,
                addr & 0xFF,
                prefixLen
            });
        } else if (i == 3) {
            try stdout.print("  ...\n", .{});
        }
    }
    const endTime = std.time.milliTimestamp();
    const memAfter = measureMemoryUsage();
    const insertTime = @as(f64, @floatFromInt(endTime - startTime)) / 1000.0;
    const insertRate = @as(f64, @floatFromInt(numPrefixes)) / insertTime;
    try stdout.print("\nMemory Usage:\n", .{});
    try stdout.print("  Before: {d} bytes\n", .{memBefore});
    try stdout.print("  After:  {d} bytes\n", .{memAfter});
    try stdout.print("  Delta:  {d} bytes\n", .{memAfter - memBefore});
    try stdout.print("  Per Entry: {d:.2} bytes\n", .{@as(f64, @floatFromInt(memAfter - memBefore)) / @as(f64, @floatFromInt(numPrefixes))});
    try stdout.print("\nInsert Performance: {d:.2} prefixes/sec\n\n", .{insertRate});
    // Lookup test
    const numLookups: usize = 1000000;
    try stdout.print("Running {d} lookups:\n", .{numLookups});
    var matches: usize = 0;
    const lookupStartTime = std.time.milliTimestamp();
    i = 0;
    while (i < numLookups) : (i += 1) {
        const addr = random.int(u32);
        var found: i32 = 0;
        _ = bart.bart_lookup4(table, addr, &found);
        if (found != 0) matches += 1;
        if (i < 3 or i > numLookups - 3) {
            try stdout.print("  Lookup: {d}.{d}.{d}.{d} -> {s}\n", .{
                (addr >> 24) & 0xFF,
                (addr >> 16) & 0xFF,
                (addr >> 8) & 0xFF,
                addr & 0xFF,
                if (found != 0) "Match" else "No Match"
            });
        } else if (i == 3) {
            try stdout.print("  ...\n", .{});
        }
    }
    const lookupEndTime = std.time.milliTimestamp();
    const lookupTime = @as(f64, @floatFromInt(lookupEndTime - lookupStartTime)) / 1000.0;
    const lookupRate = @as(f64, @floatFromInt(numLookups)) / lookupTime;
    const matchRate = (@as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(numLookups))) * 100.0;
    try stdout.print("\nBenchmark Results:\n", .{});
    try stdout.print("  Insert Time: {d:.2}ms\n", .{insertTime * 1000.0});
    try stdout.print("  Insert Rate: {d:.2} prefixes/sec\n", .{insertRate});
    try stdout.print("  Lookup Time: {d:.2}ms\n", .{lookupTime * 1000.0});
    try stdout.print("  Lookup Rate: {d:.2} lookups/sec\n", .{lookupRate});
    try stdout.print("  Match Rate: {d:.2}%\n", .{matchRate});
    // Return BenchmarkResult
    return BenchmarkResult{
        .prefix_count = numPrefixes,
        .insert_time = @as(u64, @intCast(@abs(endTime - startTime) * 1000000)), // Safe conversion
        .insert_rate = insertRate,
        .lookup_time = @as(u64, @intCast(@abs(lookupEndTime - lookupStartTime) * 1000000)), // Safe conversion
        .lookup_rate = lookupRate,
        .match_rate = matchRate,
        .memory_usage = memAfter,
        .cache_hit_rate = 0.0,
    };
}

// Main function aggregates multiple benchmark results and outputs CSV
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Routing Table Benchmark\n", .{});
    try stdout.print("===========================\n\n", .{});
    var benchmark_results = std.ArrayList(BenchmarkResult).init(std.heap.page_allocator);
    defer benchmark_results.deinit();
    // Existing test cases
    try benchmark_results.append(try runBenchmark(1000, 16));
    try benchmark_results.append(try runBenchmark(10000, 24));
    try benchmark_results.append(try runBenchmark(100000, 32));
    // New large-scale test cases
    try stdout.print("\nLarge Scale Benchmark:\n", .{});
    try stdout.print("=====================\n", .{});
    try benchmark_results.append(try runBenchmark(1000000, 24));
    // Create assets directory (if it doesn't exist)
    std.fs.cwd().makeDir("assets") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // CSV output
    try writeBenchmarkResultsToCSV(benchmark_results.items, "assets/basic_bench_results.csv");
    try stdout.print("\nBenchmark results have been written to assets/basic_bench_results.csv\n", .{});
} 