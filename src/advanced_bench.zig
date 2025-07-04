// Multithreaded performance evaluation benchmark
// 
// Measurement items:
// - Performance scaling based on thread count
// - Performance with IP address patterns close to real routing tables
// - Per-thread performance analysis
// - Impact of memory fragmentation
// 
// Usage:
// - Performance verification in multithreaded environments
// - Measurement of performance changes by thread count
// - Performance evaluation under conditions close to real environments
// - Analysis of performance differences between threads
// 
// Features:
// - Variable thread count
// - IP address patterns close to real environments
// - Detailed performance data per thread
// - Memory fragmentation measurement
// - Enhanced error handling

const std = @import("std");
const bart = @import("main.zig");
const time = std.time;
const Timer = time.Timer;
const builtin = @import("builtin");
const os = std.os;
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/task_info.h");
    @cInclude("unistd.h");
});

// Test configuration
const TestConfig = struct {
    prefix_count: u32,
    lookup_count: u32,
    random_seed: u64,
    thread_count: u32,
    test_duration_sec: u32,
    fragmentation_cycles: u32,
};

// Structure to store results per thread
const ThreadResult = struct {
    lookups: u64,
    matches: u64,
    time_ns: u64,
};

// Test results
const BenchmarkResult = struct {
    prefix_count: usize,
    insert_time: u64,
    insert_rate: f64,
    lookup_time: u64,
    lookup_rate: f64,
    match_rate: f64,
    memory_usage: usize,
    cache_hit_rate: f64,
    thread_count: u32,  // Added: thread count
    fragmentation_impact: f64,  // Added: fragmentation impact
};

// Global array to store results per thread
var global_thread_results: ?[]ThreadResult = null;
var global_thread_errors: ?[]?[]const u8 = null;

/// Generate diverse IP address patterns
/// 
/// This function generates IP addresses in the following patterns:
/// 1. Completely random
/// 2. Consecutive IPs
/// 3. IPs within subnet
/// 4. IP ranges of specific AS
/// 5. Multicast ranges
/// 
/// Parameters:
/// - random: random number generator
/// - count: number of IP addresses to generate
fn generateDiverseIPs(random: std.Random, count: u32) ![]u32 {
    var ips = try std.heap.page_allocator.alloc(u32, count);
    errdefer std.heap.page_allocator.free(ips);

    // Generate IP addresses in different patterns
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const pattern = random.uintAtMost(u8, 4); // 5 patterns from 0 to 4
        switch (pattern) {
            0 => { // Random
                ips[i] = random.int(u32);
            },
            1 => { // Consecutive IPs
                if (i > 0) {
                    ips[i] = ips[i - 1] + 1;
                } else {
                    ips[i] = random.int(u32);
                }
            },
            2 => { // IPs within subnet
                const base = random.int(u32) & 0xFFFFFF00; // /24 base
                ips[i] = base | random.uintAtMost(u8, 255);
            },
            3 => { // IP ranges of specific AS
                const as_base = @as(u32, random.uintAtMost(u16, 65535)) << 16;
                ips[i] = as_base | random.uintAtMost(u16, 65535);
            },
            4 => { // Multicast ranges
                const multicast_base = 0xE0000000;
                ips[i] = multicast_base | random.uintAtMost(u32, 0x0FFFFFFF);
            },
            else => { // Generate random IP for unexpected patterns
                ips[i] = random.int(u32);
            },
        }
    }
    return ips;
}

/// Memory fragmentation simulation
/// 
/// This function simulates memory fragmentation:
/// 1. Allocate memory blocks of random sizes
/// 2. Periodically free blocks
/// 3. Measure fragmentation impact
fn simulateFragmentation(allocator: std.mem.Allocator, cycles: u32) !void {
    var blocks = std.ArrayList([]u8).init(allocator);
    defer {
        for (blocks.items) |block| {
            allocator.free(block);
        }
        blocks.deinit();
    }

    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        // Allocate memory blocks of random sizes
        const size = 1024 + (i % 10) * 1024; // 1KB to 10KB
        const block = try allocator.alloc(u8, size);
        try blocks.append(block);

        // Occasionally free blocks to promote fragmentation
        if (i % 3 == 0 and blocks.items.len > 0) {
            const idx = i % blocks.items.len;
            allocator.free(blocks.orderedRemove(idx));
        }
    }
}

/// Per-thread lookup test
/// 
/// This function runs in each thread and measures:
/// 1. Lookup speed per thread
/// 2. Match rate per thread
/// 3. Execution time per thread
/// 
/// Parameters:
/// - table: lookup table
/// - ips: test IP address array
/// - iterations: number of lookups to execute
/// - thread_id: thread ID
fn threadLookupTest(
    table: *bart.BartTable,
    ips: []const u32,
    iterations: u32,
    thread_id: u32,
) void {
    // Buffer to store error information
    var error_buf: [256]u8 = undefined;
    var error_message: ?[]const u8 = null;

    // Initialize Timer
    var timer = Timer.start() catch |err| {
        const msg = std.fmt.bufPrint(&error_buf, "Timer.start() failed: {}", .{err}) catch "Timer.start() failed";
        error_message = msg;
        if (global_thread_errors) |errors| {
            errors[thread_id] = error_message;
        }
        return;
    };

    // Initialize random number generator
    var prng = std.Random.DefaultPrng.init(42 + thread_id);
    const random = prng.random();
    var matches: u64 = 0;

    // Execute lookup test
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        if (ips.len == 0) {
            const msg = std.fmt.bufPrint(&error_buf, "Empty IPs array", .{}) catch "Empty IPs array";
            error_message = msg;
            break;
        }

        const ip = ips[random.uintAtMost(u32, @intCast(ips.len - 1))];
        var found: i32 = 0;
        _ = bart.bart_lookup4(table, ip, &found);
        if (found != 0) matches += 1;
    }

    // Save results
    if (global_thread_results) |results| {
        results[thread_id] = ThreadResult{
            .lookups = iterations,
            .matches = matches,
            .time_ns = timer.read(),
        };
    }

    // Save error information
    if (error_message != null) {
        if (global_thread_errors) |errors| {
            errors[thread_id] = error_message;
        }
    }
}

/// Multithreaded benchmark
/// 
/// This test measures:
/// 1. Overall performance in multithreaded environment
/// 2. Detailed performance per thread
/// 3. Memory fragmentation impact
/// 4. Overall memory usage
/// 
/// Parameters:
/// - config: test configuration (prefix count, lookup count, thread count, etc.)
/// 
/// Returns:
/// - BenchmarkResult: test results (lookup count, match count, execution time, etc.)
fn printBenchmarkResult(result: BenchmarkResult, thread_results: []const ThreadResult) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("\n=== Benchmark Results ===\n", .{}) catch return;
    stdout.print("Thread Count: {d}\n", .{result.thread_count}) catch return;
    stdout.print("Prefix Count: {d}\n", .{result.prefix_count}) catch return;
    stdout.print("\n--- Performance Metrics ---\n", .{}) catch return;
    stdout.print("Lookup Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(result.lookup_time)) / 1_000_000.0}) catch return;
    stdout.print("Lookup Rate: {d:.2} ops/sec\n", .{result.lookup_rate}) catch return;
    stdout.print("Match Rate: {d:.2}%\n", .{result.match_rate}) catch return;
    stdout.print("Memory Usage: {d:.2} MB\n", .{@as(f64, @floatFromInt(result.memory_usage)) / (1024.0 * 1024.0)}) catch return;
    stdout.print("Fragmentation Impact: {d:.2}%\n", .{result.fragmentation_impact}) catch return;

    stdout.print("\n--- Per-Thread Details ---\n", .{}) catch return;
    for (thread_results, 0..) |thread_result, i| {
        const thread_time_ms = @as(f64, @floatFromInt(thread_result.time_ns)) / 1_000_000.0;
        const thread_rate = @as(f64, @floatFromInt(thread_result.lookups)) / (thread_time_ms / 1000.0);
        const thread_match_rate = @as(f64, @floatFromInt(thread_result.matches)) / @as(f64, @floatFromInt(thread_result.lookups)) * 100.0;

        stdout.print("Thread {d}:\n", .{i}) catch return;
        stdout.print("  Lookups: {d}\n", .{thread_result.lookups}) catch return;
        stdout.print("  Matches: {d}\n", .{thread_result.matches}) catch return;
        stdout.print("  Execution Time: {d:.2} ms\n", .{thread_time_ms}) catch return;
        stdout.print("  Throughput: {d:.2} ops/sec\n", .{thread_rate}) catch return;
        stdout.print("  Match Rate: {d:.2}%\n", .{thread_match_rate}) catch return;
    }

    // Calculate performance variance between threads
    var min_rate: f64 = std.math.floatMax(f64);
    var max_rate: f64 = 0;
    var total_rate: f64 = 0;
    for (thread_results) |thread_result| {
        const thread_time_ms = @as(f64, @floatFromInt(thread_result.time_ns)) / 1_000_000.0;
        const thread_rate = @as(f64, @floatFromInt(thread_result.lookups)) / (thread_time_ms / 1000.0);
        min_rate = @min(min_rate, thread_rate);
        max_rate = @max(max_rate, thread_rate);
        total_rate += thread_rate;
    }
    const avg_rate = total_rate / @as(f64, @floatFromInt(thread_results.len));
    const rate_variance = (max_rate - min_rate) / avg_rate * 100.0;

    stdout.print("\n--- Thread Performance Analysis ---\n", .{}) catch return;
    stdout.print("Min Throughput: {d:.2} ops/sec\n", .{min_rate}) catch return;
    stdout.print("Max Throughput: {d:.2} ops/sec\n", .{max_rate}) catch return;
    stdout.print("Average Throughput: {d:.2} ops/sec\n", .{avg_rate}) catch return;
    stdout.print("Throughput Variance: {d:.2}%\n", .{rate_variance}) catch return;
    stdout.print("===========================\n\n", .{}) catch return;
}

fn runMultiThreadedBenchmark(config: TestConfig) !BenchmarkResult {
    const stdout = std.io.getStdOut().writer();
    var prng = std.Random.DefaultPrng.init(config.random_seed);
    const random = prng.random();

    // Create table
    const table = bart.bart_create();
    defer bart.bart_destroy(table);

    // Generate diverse IP addresses
    const test_ips = try generateDiverseIPs(random, config.lookup_count);
    defer std.heap.page_allocator.free(test_ips);

    // Insert prefixes
    try stdout.print("\nInserting prefixes...\n", .{});
    var i: u32 = 0;
    while (i < config.prefix_count) : (i += 1) {
        const ip = random.int(u32);
        const length = 8 + random.uintAtMost(u8, 24); // /8 to /32
        _ = bart.bart_insert4(@constCast(table), ip, length, 1);
    }

    // Measure fragmentation impact
    try stdout.print("\nMeasuring fragmentation impact...\n", .{});
    const initial_mem = try measureMemoryUsage();
    try simulateFragmentation(std.heap.page_allocator, config.fragmentation_cycles);
    const final_mem = try measureMemoryUsage();
    const fragmentation_impact = @as(f64, @floatFromInt(final_mem - initial_mem)) / @as(f64, @floatFromInt(initial_mem)) * 100.0;

    // Set global array for thread results
    const thread_results = try std.heap.page_allocator.alloc(ThreadResult, config.thread_count);
    global_thread_results = thread_results;

    // Set global array for thread error information
    const thread_errors = try std.heap.page_allocator.alloc(?[]const u8, config.thread_count);
    global_thread_errors = thread_errors;

    // Create and run threads
    try stdout.print("\nRunning multi-threaded test with {d} threads...\n", .{config.thread_count});
    const threads = try std.heap.page_allocator.alloc(std.Thread, config.thread_count);
    defer std.heap.page_allocator.free(threads);

    var timer = try Timer.start();
    for (threads, 0..) |*thread, tid| {
        const tid_u32: u32 = @truncate(tid);
        thread.* = try std.Thread.spawn(.{}, threadLookupTest, .{
            @constCast(table),
            test_ips,
            config.lookup_count / config.thread_count,
            tid_u32,
        });
    }

    // Wait for threads to finish
    for (threads) |thread| {
        thread.join();
    }
    const total_time = timer.read();

    // Error check
    if (global_thread_errors) |errors| {
        for (errors, 0..) |err, tid| {
            if (err) |msg| {
                try stdout.print("Thread {d} error: {s}\n", .{tid, msg});
            }
        }
    }

    // Aggregate results
    var total_lookups: u64 = 0;
    var total_matches: u64 = 0;
    for (thread_results) |result| {
        total_lookups += result.lookups;
        total_matches += result.matches;
    }

    // Display results
    const result = BenchmarkResult{
        .prefix_count = config.prefix_count,
        .insert_time = 0,
        .insert_rate = 0,
        .lookup_time = total_time,
        .lookup_rate = @as(f64, @floatFromInt(total_lookups)) / (@as(f64, @floatFromInt(total_time)) / 1_000_000_000.0),
        .match_rate = @as(f64, @floatFromInt(total_matches)) / @as(f64, @floatFromInt(total_lookups)) * 100.0,
        .memory_usage = final_mem,
        .cache_hit_rate = 0.0,
        .thread_count = config.thread_count,
        .fragmentation_impact = fragmentation_impact,
    };

    // Display detailed results
    printBenchmarkResult(result, thread_results);

    // Global variable cleanup
    global_thread_errors = null;
    global_thread_results = null;
    std.heap.page_allocator.free(thread_errors);

    return result;
}

/// Memory usage measurement
/// 
/// This function measures current process memory usage.
/// Uses different methods based on OS:
/// - macOS: uses ps command
/// - Linux: reads /proc/self/statm
fn measureMemoryUsage() !usize {
    if (comptime builtin.os.tag == .macos) {
        var argv_buf: [32]u8 = undefined;
        const pid_str = try std.fmt.bufPrint(&argv_buf, "{d}", .{c.getpid()});
        var child = std.process.Child.init(&[_][]const u8{
            "ps", "-o", "rss=", "-p", pid_str,
        }, std.heap.page_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        var out_buf: [64]u8 = undefined;
        const n = try child.stdout.?.readAll(&out_buf);
        _ = try child.wait();
        const trimmed = std.mem.trim(u8, out_buf[0..n], &std.ascii.whitespace);
        const rss_kb = try std.fmt.parseInt(usize, trimmed, 10);
        return rss_kb * 1024;
    } else if (comptime builtin.os.tag == .linux) {
        const file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
        defer file.close();
        var buf: [128]u8 = undefined;
        const bytes_read = try file.read(&buf);
        const content = buf[0..bytes_read];
        var it = std.mem.splitScalar(u8, content, ' ');
        _ = it.next();
        if (it.next()) |resident_pages_str| {
            const resident_pages = try std.fmt.parseInt(usize, resident_pages_str, 10);
            return resident_pages * std.os.system.sysconf(.PAGE_SIZE);
        }
        return error.InvalidStatmFormat;
    }
    return error.UnsupportedOS;
}

// Function to output benchmark results to CSV
fn writeBenchmarkResultsToCSV(
    results: []const BenchmarkResult,
    filename: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    const writer = file.writer();
    try writer.writeAll("prefix_count,insert_time_ns,insert_rate,lookup_time_ns,lookup_rate,match_rate,memory_usage_bytes,cache_hit_rate,thread_count,fragmentation_impact\n");
    for (results) |result| {
        try writer.print("{d},{d},{d:.2},{d},{d:.2},{d:.2},{d},{d:.2},{d},{d:.2}\n", .{
            result.prefix_count,
            result.insert_time,
            result.insert_rate,
            result.lookup_time,
            result.lookup_rate,
            result.match_rate,
            result.memory_usage,
            result.cache_hit_rate,
            result.thread_count,
            result.fragmentation_impact,
        });
    }
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Advanced Benchmark Tests\n", .{});
    try stdout.print("===========================\n", .{});
    try stdout.print("System Information:\n", .{});
    try stdout.print("- CPU Architecture: {s}\n", .{@tagName(builtin.cpu.arch)});
    try stdout.print("- OS: {s}\n", .{@tagName(builtin.os.tag)});
    try stdout.print("- Build Mode: {s}\n", .{@tagName(builtin.mode)});
    try stdout.print("===========================\n\n", .{});

    // Test configuration
    const configs = [_]TestConfig{
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 1,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 2,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 4,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
        .{
            .prefix_count = 1_000_000,
            .lookup_count = 10_000_000,
            .random_seed = 42,
            .thread_count = 8,
            .test_duration_sec = 60,
            .fragmentation_cycles = 1000,
        },
    };

    // Array to store benchmark results
    var benchmark_results = std.ArrayList(BenchmarkResult).init(std.heap.page_allocator);
    defer benchmark_results.deinit();

    // Run benchmark for each configuration
    for (configs) |config| {
        try stdout.print("\n=== Benchmark Configuration ===\n", .{});
        try stdout.print("Thread Count: {d}\n", .{config.thread_count});
        try stdout.print("Prefix Count: {d}\n", .{config.prefix_count});
        try stdout.print("Lookup Count: {d}\n", .{config.lookup_count});
        try stdout.print("Test Duration: {d} seconds\n", .{config.test_duration_sec});
        try stdout.print("Fragmentation Cycles: {d}\n", .{config.fragmentation_cycles});
        try stdout.print("===========================\n", .{});

        const result = try runMultiThreadedBenchmark(config);
        try benchmark_results.append(result);
    }

    // Create assets directory if it doesn't exist
    std.fs.cwd().makeDir("assets") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Output results to CSV file
    try writeBenchmarkResultsToCSV(benchmark_results.items, "assets/advanced_bench_results.csv");
    try stdout.print("\nBenchmark results have been written to assets/advanced_bench_results.csv\n", .{});
} 