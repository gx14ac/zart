//! Realistic benchmark tests
//! 
//! This benchmark tests the following items:
//! 1. Performance in more realistic usage patterns
//! 2. Impact of memory fragmentation
//! 3. Detailed memory usage measurement
//! 
//! Main purposes:
//! - Performance evaluation under conditions close to production
//! - Measurement of memory fragmentation impact on performance
//! - Analysis of memory usage during long-term operation
//! 
//! Features:
//! - Uses more realistic IP address patterns
//! - Simulates memory fragmentation
//! - Detailed memory usage measurement
//! - Supports long-running tests

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

// Global buffers
var ip_buf: [16]u8 = undefined;
var duration_buf: [32]u8 = undefined;

// Function to convert IP address to string format
fn ip4ToString(ip: u32) []const u8 {
    const bytes = [_]u8{
        @as(u8, @truncate((ip >> 24) & 0xFF)),
        @as(u8, @truncate((ip >> 16) & 0xFF)),
        @as(u8, @truncate((ip >> 8) & 0xFF)),
        @as(u8, @truncate(ip & 0xFF)),
    };
    return std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch "error";
}

// Function to display time in appropriate units
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

// Structure to define prefix length distribution
const PrefixLengthDistribution = struct {
    length: u8,  // Prefix length
    weight: u32, // Weight (frequency of occurrence)
};

// Benchmark configuration
const Config = struct {
    prefix_count: u32,
    lookup_count: u32,
    random_seed: u64,
    prefix_length_distribution: []const PrefixLengthDistribution,
};

/// Memory usage measurement
/// 
/// This function measures the current process memory usage.
/// Uses different methods depending on OS:
/// - macOS: uses ps command
/// - Linux: reads /proc/self/statm
fn measureMemoryUsage() !usize {
    if (comptime builtin.os.tag == .macos) {
        // macOS: get RSS using ps command
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
        // Linux: get RSS from /proc/self/statm
        const file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
        defer file.close();
        
        var buf: [128]u8 = undefined;
        const bytes_read = try file.read(&buf);
        const content = buf[0..bytes_read];
        
        // statm format: "total_pages resident_pages shared_pages text_pages lib_pages data_pages dirty_pages"
        var it = std.mem.splitScalar(u8, content, ' ');
        _ = it.next(); // Skip total_pages
        if (it.next()) |resident_pages_str| {
            const resident_pages = try std.fmt.parseInt(usize, resident_pages_str, 10);
            return resident_pages * std.os.system.sysconf(.PAGE_SIZE);
        }
        return error.InvalidStatmFormat;
    }
    return error.UnsupportedOS;
}

// Function to randomly select prefix length based on weights
fn selectRandomPrefixLength(random: std.Random, distribution: []const PrefixLengthDistribution) u8 {
    var total_weight: u32 = 0;
    for (distribution) |item| {
        total_weight += item.weight;
    }
    var r = random.uintAtMost(u32, total_weight - 1);
    for (distribution) |item| {
        if (r < item.weight) {
            return item.length;
        }
        r -= item.weight;
    }
    return distribution[distribution.len - 1].length;
}

// Structure for detailed memory usage analysis
const MemoryStats = struct {
    total_bytes: usize,
    prefix_length_stats: [33]struct {
        count: u32,
        bytes: usize,
    },
};

// Function to perform detailed memory usage analysis
fn analyzeMemoryUsage(prefixes: []const PrefixEntry) !MemoryStats {
    var stats = MemoryStats{
        .total_bytes = 0,
        .prefix_length_stats = undefined,
    };
    for (&stats.prefix_length_stats) |*stat| {
        stat.* = .{ .count = 0, .bytes = 0 };
    }

    // Get actual memory usage
    const mem_usage = try measureMemoryUsage();
    stats.total_bytes = mem_usage;

    // Get statistics by prefix length
    // Currently, statistics by prefix length cannot be obtained,
    // so display estimated values by dividing memory usage by prefix count
    const prefix_count = prefixes.len;
    const avg_bytes_per_prefix = if (prefix_count > 0)
        @divTrunc(mem_usage, prefix_count)
    else
        0;

    // Estimate statistics by prefix length
    for (prefixes) |prefix| {
        stats.prefix_length_stats[prefix.length].count += 1;
        stats.prefix_length_stats[prefix.length].bytes += avg_bytes_per_prefix;
    }

    return stats;
}

// Structure for cache-aware testing
const CacheTestConfig = struct {
    warmup_iterations: u32,
    test_iterations: u32,
    cache_size: usize,
};

// Function to run cache-aware tests
fn runCacheTest(
    table: *bart.BartTable,
    config: CacheTestConfig,
    random: std.Random,
) !struct {
    warmup_time: u64,
    test_time: u64,
    hit_rate: f64,
} {
    var warmup_timer = try Timer.start();
    var i: u32 = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        const ip_addr = random.int(u32);
        var found: i32 = 0;
        _ = bart.bart_lookup4(table, ip_addr, &found);
    }
    const warmup_time = warmup_timer.read();

    var test_timer = try Timer.start();
    var hits: u32 = 0;
    i = 0;
    while (i < config.test_iterations) : (i += 1) {
        const ip_addr = random.int(u32);
        var found: i32 = 0;
        _ = bart.bart_lookup4(table, ip_addr, &found);
        if (found != 0) hits += 1;
    }
    const test_time = test_timer.read();
    const hit_rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(config.test_iterations)) * 100.0;

    return .{
        .warmup_time = warmup_time,
        .test_time = test_time,
        .hit_rate = hit_rate,
    };
}

// Prefix entry structure
const PrefixEntry = struct {
    ip: u32,
    length: u8,
};

// Prefix data structure
const PrefixData = struct {
    prefixes: []PrefixEntry,
    allocator: ?std.mem.Allocator,
};

// Function to load actual BGP routing table data
fn loadBGPData(allocator: std.mem.Allocator, path: []const u8) !PrefixData {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader = file.reader();
    var prefixes = std.ArrayList(PrefixEntry).init(allocator);

    var buf: [1024]u8 = undefined;
    var line_number: usize = 0;
    var success_count: usize = 0;
    var error_count: usize = 0;
    var ipv6_count: usize = 0;

    std.debug.print("Starting to read file: {s}\n", .{path});

    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        line_number += 1;
        if (line_number <= 5) {
            std.debug.print("Processing line {d}: {s}\n", .{line_number, line});
        }

        if (line.len == 0 or line[0] == '#') {
            if (line_number <= 5) {
                std.debug.print("  Skipping empty or comment line\n", .{});
            }
            continue;
        }

        var it = std.mem.splitScalar(u8, line, '/');
        const ip_str = it.next() orelse {
            std.debug.print("Error: Invalid format at line {d}: {s}\n", .{line_number, line});
            error_count += 1;
            continue;
        };
        const length_str = it.next() orelse {
            std.debug.print("Error: Missing prefix length at line {d}: {s}\n", .{line_number, line});
            error_count += 1;
            continue;
        };

        // Skip IPv6 addresses (if ':' is present)
        if (std.mem.indexOfScalar(u8, ip_str, ':')) |_| {
            if (line_number <= 5) {
                std.debug.print("  Skipping IPv6 address: {s}\n", .{ip_str});
            }
            ipv6_count += 1;
            continue;
        }

        if (line_number <= 5) {
            std.debug.print("  IP: {s}, Length: {s}\n", .{ip_str, length_str});
        }

        const ip = parseIPv4(ip_str) catch |err| {
            std.debug.print("Error parsing IP at line {d}: {s} (error: {})\n", .{line_number, ip_str, err});
            error_count += 1;
            continue;
        };
        const length = std.fmt.parseInt(u8, length_str, 10) catch |err| {
            std.debug.print("Error parsing prefix length at line {d}: {s} (error: {})\n", .{line_number, length_str, err});
            error_count += 1;
            continue;
        };
        if (length > 32) {
            std.debug.print("Error: Invalid prefix length at line {d}: {d}\n", .{line_number, length});
            error_count += 1;
            continue;
        }

        try prefixes.append(.{
            .ip = ip,
            .length = length,
        });
        success_count += 1;

        if (line_number <= 5) {
            std.debug.print("  Successfully parsed: {s}/{d}\n", .{ip4ToString(ip), length});
        }
    }

    std.debug.print("File processing complete:\n", .{});
    std.debug.print("  Total lines: {d}\n", .{line_number});
    std.debug.print("  Successfully parsed: {d}\n", .{success_count});
    std.debug.print("  IPv6 addresses skipped: {d}\n", .{ipv6_count});
    std.debug.print("  Errors: {d}\n", .{error_count});

    return PrefixData{
        .prefixes = try prefixes.toOwnedSlice(),
        .allocator = allocator,
    };
}

// Function to parse IPv4 address
fn parseIPv4(str: []const u8) !u32 {
    var result: u32 = 0;
    var it = std.mem.splitScalar(u8, str, '.');
    var i: u8 = 0;
    while (it.next()) |octet_str| : (i += 1) {
        if (i >= 4) {
            std.debug.print("Error: Too many octets in IP address: {s}\n", .{str});
            return error.InvalidIPv4Address;
        }
        const octet = std.fmt.parseInt(u8, octet_str, 10) catch |err| {
            std.debug.print("Error parsing octet {d} in IP address {s}: {s} (error: {})\n", .{i + 1, str, octet_str, err});
            return error.InvalidIPv4Address;
        };
        if (octet > 255) {
            std.debug.print("Error: Octet {d} out of range in IP address {s}: {d}\n", .{i + 1, str, octet});
            return error.InvalidIPv4Address;
        }
        result = (result << 8) | octet;
    }
    if (i != 4) {
        std.debug.print("Error: Not enough octets in IP address: {s} (found {d})\n", .{str, i});
        return error.InvalidIPv4Address;
    }
    return result;
}

// Benchmark result structure as common type
const BenchmarkResult = struct {
    prefix_count: u32,
    insert_time: u64,
    insert_rate: f64,
    lookup_time: u64,
    lookup_rate: f64,
    match_rate: f64,
    memory_usage: usize,
    cache_hit_rate: f64,
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

// Function to run more realistic benchmark
fn runRealisticBenchmark(config: Config) !BenchmarkResult {
    const stdout = std.io.getStdOut().writer();
    var prng = std.rand.DefaultPrng.init(config.random_seed);
    const random = prng.random();

    // Measure initial memory usage
    const initial_mem = try measureMemoryUsage();

    // Create and initialize table
    const table = bart.bart_create();
    defer bart.bart_destroy(table);

    // Measure memory usage after table creation
    const table_mem = try measureMemoryUsage();
    const table_overhead = table_mem - initial_mem;

    // Load actual BGP data (or generate random data)
    const prefixes = blk: {
        if (std.fs.cwd().openFile("testdata/prefixes.txt", .{})) |file| {
            defer file.close();
            const bgp_data = try loadBGPData(std.heap.page_allocator, "testdata/prefixes.txt");
            // Limit dataset
            if (bgp_data.prefixes.len > config.prefix_count) {
                const limited_prefixes = try std.heap.page_allocator.alloc(PrefixEntry, config.prefix_count);
                for (limited_prefixes, 0..) |*prefix, i| {
                    prefix.* = bgp_data.prefixes[i];
                }
                if (bgp_data.allocator) |allocator| {
                    allocator.free(bgp_data.prefixes);
                }
                break :blk PrefixData{
                    .prefixes = limited_prefixes,
                    .allocator = std.heap.page_allocator,
                };
            }
            break :blk bgp_data;
        } else |_| {
            // Generate random data
            const random_prefixes = try std.heap.page_allocator.alloc(PrefixEntry, config.prefix_count);
            defer std.heap.page_allocator.free(random_prefixes);

            var i: u32 = 0;
            while (i < config.prefix_count) : (i += 1) {
                random_prefixes[i] = .{
                    .ip = random.int(u32),
                    .length = selectRandomPrefixLength(random, config.prefix_length_distribution),
                };
            }
            break :blk PrefixData{
                .prefixes = random_prefixes,
                .allocator = std.heap.page_allocator,
            };
        }
    };
    defer if (prefixes.allocator) |allocator| {
        allocator.free(prefixes.prefixes);
    };

    // Insert prefixes
    try stdout.print("\nInserting {d} prefixes:\n", .{prefixes.prefixes.len});
    var insert_timer = try Timer.start();
    var prefix_length_counts = [_]u32{0} ** 33;

    for (prefixes.prefixes) |prefix| {
        prefix_length_counts[prefix.length] += 1;
        const res = bart.bart_insert4(@constCast(table), prefix.ip, prefix.length, 1);
        std.debug.assert(res == 0);
    }
    const insert_time = insert_timer.read();
    const insert_per_sec = @as(f64, @floatFromInt(prefixes.prefixes.len)) / (@as(f64, @floatFromInt(insert_time)) / 1_000_000_000.0);
    try stdout.print("Insert Performance: {d:.2} prefixes/sec\n", .{insert_per_sec});

    // Display prefix length distribution
    try stdout.print("\nPrefix Length Distribution:\n", .{});
    for (prefix_length_counts, 0..) |count, len| {
        if (count > 0) {
            const percentage = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(prefixes.prefixes.len)) * 100.0;
            try stdout.print("  /{d}: {d} ({d:.2}%)\n", .{ len, count, percentage });
        }
    }

    // Detailed memory usage analysis
    const mem_stats = try analyzeMemoryUsage(prefixes.prefixes);
    try stdout.print("\nDetailed Memory Usage:\n", .{});
    try stdout.print("  Total: {d:.2} MB\n", .{@as(f64, @floatFromInt(mem_stats.total_bytes)) / (1024.0 * 1024.0)});
    try stdout.print("  Table Overhead: {d:.2} MB\n", .{@as(f64, @floatFromInt(table_overhead)) / (1024.0 * 1024.0)});
    try stdout.print("  Per Prefix: {d:.2} bytes\n", .{@as(f64, @floatFromInt(mem_stats.total_bytes - table_overhead)) / @as(f64, @floatFromInt(prefixes.prefixes.len))});
    for (mem_stats.prefix_length_stats, 0..) |stat, len| {
        if (stat.count > 0) {
            try stdout.print("  /{d}: {d} entries, {d:.2} KB\n", .{
                len,
                stat.count,
                @as(f64, @floatFromInt(stat.bytes)) / 1024.0,
            });
        }
    }

    // Cache-aware tests
    const cache_test_config = CacheTestConfig{
        .warmup_iterations = 1_000_000,
        .test_iterations = 10_000_000,
        .cache_size = 1024 * 1024, // 1MB
    };
    const cache_test_results = try runCacheTest(@constCast(table), cache_test_config, random);
    try stdout.print("\nCache Test Results:\n", .{});
    try stdout.print("  Warmup Time: {s}\n", .{formatDuration(cache_test_results.warmup_time)});
    try stdout.print("  Test Time: {s}\n", .{formatDuration(cache_test_results.test_time)});
    try stdout.print("  Hit Rate: {d:.2}%\n", .{cache_test_results.hit_rate});

    // Lookup test including non-matching IPs
    try stdout.print("\nRunning {d} lookups (including non-matching IPs):\n", .{config.lookup_count});
    var lookup_timer = try Timer.start();
    var match_count: u32 = 0;
    var i: u32 = 0;
    while (i < config.lookup_count) : (i += 1) {
        const ip_addr = random.int(u32);
        var found: i32 = 0;
        _ = bart.bart_lookup4(@constCast(table), ip_addr, &found);
        if (found != 0) match_count += 1;

        if (i < 3 or i >= config.lookup_count - 3) {
            try stdout.print("  Lookup: {s} -> {s}\n", .{
                ip4ToString(ip_addr),
                if (found != 0) "Match" else "No Match",
            });
        } else if (i == 3) {
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

    // Return result at the end of the function
    return .{
        .prefix_count = config.prefix_count,
        .insert_time = insert_time,
        .insert_rate = insert_per_sec,
        .lookup_time = lookup_time,
        .lookup_rate = lookup_per_sec,
        .match_rate = match_rate,
        .memory_usage = mem_stats.total_bytes,
        .cache_hit_rate = cache_test_results.hit_rate,
    };
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZART Routing Table Benchmark (Realistic)\n", .{});
    try stdout.print("=====================================\n", .{});

    // Define distribution close to BGP routing table
    const bgp_like_distribution = [_]PrefixLengthDistribution{
        .{ .length = 8, .weight = 1 },    // /8
        .{ .length = 9, .weight = 2 },    // /9
        .{ .length = 10, .weight = 4 },   // /10
        .{ .length = 11, .weight = 8 },   // /11
        .{ .length = 12, .weight = 16 },  // /12
        .{ .length = 13, .weight = 32 },  // /13
        .{ .length = 14, .weight = 64 },  // /14
        .{ .length = 15, .weight = 128 }, // /15
        .{ .length = 16, .weight = 256 }, // /16
        .{ .length = 17, .weight = 512 }, // /17
        .{ .length = 18, .weight = 1024 }, // /18
        .{ .length = 19, .weight = 2048 }, // /19
        .{ .length = 20, .weight = 4096 }, // /20
        .{ .length = 21, .weight = 8192 }, // /21
        .{ .length = 22, .weight = 16384 }, // /22
        .{ .length = 23, .weight = 32768 }, // /23
        .{ .length = 24, .weight = 65536 }, // /24
        .{ .length = 25, .weight = 32768 }, // /25
        .{ .length = 26, .weight = 16384 }, // /26
        .{ .length = 27, .weight = 8192 },  // /27
        .{ .length = 28, .weight = 4096 },  // /28
        .{ .length = 29, .weight = 2048 },  // /29
        .{ .length = 30, .weight = 1024 },  // /30
        .{ .length = 31, .weight = 512 },   // /31
        .{ .length = 32, .weight = 256 },   // /32
    };

    // More realistic benchmark configuration (adjust dataset size)
    const configs = [_]Config{
        .{
            .prefix_count = 100,    // Start from 100 entries
            .lookup_count = 100_000,
            .random_seed = 42,
            .prefix_length_distribution = &bgp_like_distribution,
        },
        .{
            .prefix_count = 1000,   // 1,000 entries
            .lookup_count = 100_000,
            .random_seed = 42,
            .prefix_length_distribution = &bgp_like_distribution,
        },
        .{
            .prefix_count = 10000,  // 10,000 entries
            .lookup_count = 100_000,
            .random_seed = 42,
            .prefix_length_distribution = &bgp_like_distribution,
        },
    };

    // Array to store benchmark results
    var benchmark_results = std.ArrayList(BenchmarkResult).init(std.heap.page_allocator);
    defer benchmark_results.deinit();

    for (configs, 0..) |config, i| {
        try stdout.print("\nBenchmark Configuration {d}:\n", .{i + 1});
        try stdout.print("------------------------\n", .{});
        try stdout.print("Random Seed: {d}\n", .{config.random_seed});

        // Run benchmark and save result
        const result = try runRealisticBenchmark(config);
        try benchmark_results.append(result);
    }

    // Create assets directory (if it doesn't exist)
    std.fs.cwd().makeDir("assets") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Output results to CSV file
    try writeBenchmarkResultsToCSV(benchmark_results.items, "assets/realistic_bench_results.csv");
    try stdout.print("\nBenchmark results have been written to assets/realistic_bench_results.csv\n", .{});
}
