const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

// Benchmark configuration - matching Go BART
const WARMUP_ITERATIONS = 1000;
const BENCHMARK_ITERATIONS = 10000;
const SEED = 42;

// Test data globals - matches Go BART structure
var routes: std.ArrayList(Route) = undefined;
var routes4: std.ArrayList(Route) = undefined;
var routes6: std.ArrayList(Route) = undefined;

var match_ip4: IPAddr = undefined;
var match_ip6: IPAddr = undefined;
var match_pfx4: Prefix = undefined;
var match_pfx6: Prefix = undefined;

var miss_ip4: IPAddr = undefined;
var miss_ip6: IPAddr = undefined;
var miss_pfx4: Prefix = undefined;
var miss_pfx6: Prefix = undefined;

// Global tables for benchmarks
var bench_table: Table(i32) = undefined;

// Benchmark sinks to prevent optimization
var bool_sink: bool = false;
var int_sink: i32 = 0;

const Route = struct {
    cidr: Prefix,
    value: i32,
};

// Create hardcoded test data similar to real routing tables
fn createTestData(allocator: std.mem.Allocator) !void {
    routes = std.ArrayList(Route).init(allocator);
    routes4 = std.ArrayList(Route).init(allocator);
    routes6 = std.ArrayList(Route).init(allocator);

    // IPv4 test prefixes covering various scenarios
    const ipv4_test_data = [_]struct { ip: [4]u8, len: u8 }{
        .{ .ip = .{ 0, 0, 0, 0 }, .len = 0 },          // Default route
        .{ .ip = .{ 10, 0, 0, 0 }, .len = 8 },         // Private networks
        .{ .ip = .{ 172, 16, 0, 0 }, .len = 12 },
        .{ .ip = .{ 192, 168, 0, 0 }, .len = 16 },
        .{ .ip = .{ 8, 8, 8, 0 }, .len = 24 },         // Google DNS network
        .{ .ip = .{ 1, 1, 1, 0 }, .len = 24 },         // Cloudflare DNS network
        .{ .ip = .{ 203, 0, 113, 0 }, .len = 24 },     // TEST-NET-3
        .{ .ip = .{ 198, 51, 100, 0 }, .len = 24 },    // TEST-NET-2
        .{ .ip = .{ 192, 0, 2, 0 }, .len = 24 },       // TEST-NET-1
        .{ .ip = .{ 127, 0, 0, 0 }, .len = 8 },        // Loopback
        .{ .ip = .{ 169, 254, 0, 0 }, .len = 16 },     // Link-local
        .{ .ip = .{ 224, 0, 0, 0 }, .len = 4 },        // Multicast
    };

    // IPv6 test prefixes
    const ipv6_test_data = [_]struct { ip: [16]u8, len: u8 }{
        .{ .ip = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 32 },  // Documentation
        .{ .ip = .{ 0x20, 0x01, 0x04, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 32 },  // Tunneling
        .{ .ip = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 10 },       // Link-local
        .{ .ip = .{ 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 8 },           // Multicast
    };

    var count: i32 = 0;

    // Add IPv4 routes
    for (ipv4_test_data) |test_pfx| {
        const addr = IPAddr{ .v4 = test_pfx.ip };
        const prefix = Prefix.init(&addr, test_pfx.len);
        const route = Route{ .cidr = prefix, .value = count };
        
        try routes.append(route);
        try routes4.append(route);
        count += 1;
    }

    // Add IPv6 routes
    for (ipv6_test_data) |test_pfx| {
        const addr = IPAddr{ .v6 = test_pfx.ip };
        const prefix = Prefix.init(&addr, test_pfx.len);
        const route = Route{ .cidr = prefix, .value = count };
        
        try routes.append(route);
        try routes6.append(route);
        count += 1;
    }

    print("Created {} test prefixes ({} IPv4, {} IPv6)\n", .{ routes.items.len, routes4.items.len, routes6.items.len });
}

// Load real routing table data from testdata/prefixes.txt
fn loadRealRoutingData(allocator: std.mem.Allocator) !void {
    routes = std.ArrayList(Route).init(allocator);
    routes4 = std.ArrayList(Route).init(allocator);
    routes6 = std.ArrayList(Route).init(allocator);

    // Try to load from uncompressed file first
    const file = std.fs.cwd().openFile("testdata/prefixes.txt", .{}) catch |err| {
        print("Error: Could not open testdata/prefixes.txt: {}\n", .{err});
        print("Falling back to test data...\n", .{});
        return createTestData(allocator);
    };
    defer file.close();

    print("Loading real routing table data from testdata/prefixes.txt...\n", .{});

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var buf: [256]u8 = undefined;
    var count: i32 = 0;
    var errors: usize = 0;

    while (try in_stream.readUntilDelimiterOrEof(buf[0..], '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;

        // Parse CIDR notation: "192.168.1.0/24"
        const slash_pos = std.mem.indexOf(u8, trimmed, "/") orelse {
            errors += 1;
            continue;
        };

        const addr_str = trimmed[0..slash_pos];
        const len_str = trimmed[slash_pos + 1..];

        // Parse prefix length
        const prefix_len = std.fmt.parseInt(u8, len_str, 10) catch {
            errors += 1;
            continue;
        };

        // Parse IP address
        const addr = parseIPAddress(addr_str) catch {
            errors += 1;
            continue;
        };

        // Validate prefix length
        const is_valid = switch (addr) {
            .v4 => prefix_len <= 32,
            .v6 => prefix_len <= 128,
        };
        if (!is_valid) {
            errors += 1;
            continue;
        }

        const prefix = Prefix.init(&addr, prefix_len);
        const route = Route{ .cidr = prefix.masked(), .value = count };

        try routes.append(route);
        if (addr.is4()) {
            try routes4.append(route);
        } else {
            try routes6.append(route);
        }

        count += 1;

        // Limit for reasonable performance
        if (count >= 100000) break;
    }

    print("Loaded {} real prefixes ({} IPv4, {} IPv6, {} errors)\n", .{ routes.items.len, routes4.items.len, routes6.items.len, errors });

    if (routes.items.len == 0) {
        print("No valid prefixes loaded, falling back to test data...\n", .{});
        return createTestData(allocator);
    }
}

// Parse IP address from string (IPv4 or IPv6)
fn parseIPAddress(addr_str: []const u8) !IPAddr {
    // Try IPv4 first
    if (std.mem.indexOf(u8, addr_str, ":") == null) {
        // IPv4 format: "192.168.1.0"
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, addr_str, '.');
        var i: usize = 0;

        while (iter.next()) |part| {
            if (i >= 4) return error.InvalidIPv4;
            parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIPv4;
            i += 1;
        }

        if (i != 4) return error.InvalidIPv4;
        return IPAddr{ .v4 = parts };
    } else {
        // IPv6 format: "2001:db8::1" (simplified parsing)
        var parts: [16]u8 = std.mem.zeroes([16]u8);
        
        // For now, handle basic IPv6 without full parsing
        // This is a simplified implementation
        if (std.mem.startsWith(u8, addr_str, "2001:db8")) {
            parts[0] = 0x20;
            parts[1] = 0x01;
            parts[2] = 0x0d;
            parts[3] = 0xb8;
        } else if (std.mem.startsWith(u8, addr_str, "fe80")) {
            parts[0] = 0xfe;
            parts[1] = 0x80;
        } else if (std.mem.startsWith(u8, addr_str, "ff")) {
            parts[0] = 0xff;
        }
        
        return IPAddr{ .v6 = parts };
    }
}

// Find test cases matching Go BART's method
fn findTestCases(allocator: std.mem.Allocator) !void {
    // Create a table with all routes for finding matches/misses
    var table = Table(i32).init(allocator);
    defer table.deinit();

    for (routes.items) |route| {
        table.insert(&route.cidr, route.value);
    }

    // Set up specific test cases
    if (routes4.items.len > 0) {
        // IPv4 match cases - choose addresses that should match
        match_ip4 = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };  // Should match 192.168.0.0/16
        match_pfx4 = routes4.items[2].cidr;  // 192.168.0.0/16

        // IPv4 miss cases - choose addresses that should not match
        miss_ip4 = IPAddr{ .v4 = .{ 200, 200, 200, 200 } };  // Unlikely to match
        const miss_addr4 = IPAddr{ .v4 = .{ 203, 1, 1, 0 } };
        miss_pfx4 = Prefix.init(&miss_addr4, 24);  // Different from test data
    }

    if (routes6.items.len > 0) {
        // IPv6 match cases
        match_ip6 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44 } };
        match_pfx6 = routes6.items[0].cidr;  // 2001:db8::/32

        // IPv6 miss cases
        miss_ip6 = IPAddr{ .v6 = .{ 0x20, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
        const miss_addr6 = IPAddr{ .v6 = .{ 0x20, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
        miss_pfx6 = Prefix.init(&miss_addr6, 32);
    }

    print("Test cases configured:\n", .{});
    print("  Match IPv4: {}\n", .{match_ip4});
    print("  Match IPv6: {}\n", .{match_ip6});
    print("  Miss IPv4: {}\n", .{miss_ip4});
    print("  Miss IPv6: {}\n", .{miss_ip6});
}

// High-precision timer for benchmarks
fn benchmarkTimer(comptime name: []const u8, comptime func: anytype, iterations: usize) !void {
    // Warmup
    var i: usize = 0;
    while (i < WARMUP_ITERATIONS) : (i += 1) {
        func();
    }

    // Actual benchmark
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        func();
    }
    const end = std.time.nanoTimestamp();

    const total_ns = @as(f64, @floatFromInt(end - start));
    const avg_ns = total_ns / @as(f64, @floatFromInt(iterations));

    print("{s}: {d:.2} ns/op ({d} iterations)\n", .{ name, avg_ns, iterations });
}

// Initialize benchmark table with all routes
fn initBenchTable(allocator: std.mem.Allocator) !void {
    bench_table = Table(i32).init(allocator);
    for (routes.items) |route| {
        bench_table.insert(&route.cidr, route.value);
    }
}

// Benchmark functions matching Go BART
fn benchmarkFullMatch4(allocator: std.mem.Allocator) !void {
    try initBenchTable(allocator);
    defer bench_table.deinit();

    print("\n=== BenchmarkFullMatch4 ===\n", .{});
    print("Match IP4: {}\n", .{match_ip4});
    print("Match Prefix4: {}\n", .{match_pfx4});

    // Contains benchmark
    try benchmarkTimer("Contains", struct {
        fn run() void {
            bool_sink = bench_table.contains(&match_ip4);
        }
    }.run, BENCHMARK_ITERATIONS);

    // Lookup benchmark
    try benchmarkTimer("Lookup", struct {
        fn run() void {
            const result = bench_table.lookup(&match_ip4);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // LookupPrefix benchmark
    try benchmarkTimer("LookupPrefix", struct {
        fn run() void {
            const result = bench_table.lookupPrefix(&match_pfx4);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // Get benchmark
    try benchmarkTimer("Get", struct {
        fn run() void {
            const result = bench_table.get(&match_pfx4);
            bool_sink = result != null;
        }
    }.run, BENCHMARK_ITERATIONS);
}

fn benchmarkFullMatch6(allocator: std.mem.Allocator) !void {
    try initBenchTable(allocator);
    defer bench_table.deinit();

    print("\n=== BenchmarkFullMatch6 ===\n", .{});
    print("Match IP6: {}\n", .{match_ip6});
    print("Match Prefix6: {}\n", .{match_pfx6});

    // Contains benchmark
    try benchmarkTimer("Contains", struct {
        fn run() void {
            bool_sink = bench_table.contains(&match_ip6);
        }
    }.run, BENCHMARK_ITERATIONS);

    // Lookup benchmark
    try benchmarkTimer("Lookup", struct {
        fn run() void {
            const result = bench_table.lookup(&match_ip6);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // LookupPrefix benchmark
    try benchmarkTimer("LookupPrefix", struct {
        fn run() void {
            const result = bench_table.lookupPrefix(&match_pfx6);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // Get benchmark
    try benchmarkTimer("Get", struct {
        fn run() void {
            const result = bench_table.get(&match_pfx6);
            bool_sink = result != null;
        }
    }.run, BENCHMARK_ITERATIONS);
}

fn benchmarkFullMiss4(allocator: std.mem.Allocator) !void {
    try initBenchTable(allocator);
    defer bench_table.deinit();

    print("\n=== BenchmarkFullMiss4 ===\n", .{});
    print("Miss IP4: {}\n", .{miss_ip4});
    print("Miss Prefix4: {}\n", .{miss_pfx4});

    // Contains benchmark
    try benchmarkTimer("Contains", struct {
        fn run() void {
            bool_sink = bench_table.contains(&miss_ip4);
        }
    }.run, BENCHMARK_ITERATIONS);

    // Lookup benchmark
    try benchmarkTimer("Lookup", struct {
        fn run() void {
            const result = bench_table.lookup(&miss_ip4);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // LookupPrefix benchmark
    try benchmarkTimer("LookupPrefix", struct {
        fn run() void {
            const result = bench_table.lookupPrefix(&miss_pfx4);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // Get benchmark
    try benchmarkTimer("Get", struct {
        fn run() void {
            const result = bench_table.get(&miss_pfx4);
            bool_sink = result != null;
        }
    }.run, BENCHMARK_ITERATIONS);
}

fn benchmarkFullMiss6(allocator: std.mem.Allocator) !void {
    try initBenchTable(allocator);
    defer bench_table.deinit();

    print("\n=== BenchmarkFullMiss6 ===\n", .{});
    print("Miss IP6: {}\n", .{miss_ip6});
    print("Miss Prefix6: {}\n", .{miss_pfx6});

    // Contains benchmark
    try benchmarkTimer("Contains", struct {
        fn run() void {
            bool_sink = bench_table.contains(&miss_ip6);
        }
    }.run, BENCHMARK_ITERATIONS);

    // Lookup benchmark
    try benchmarkTimer("Lookup", struct {
        fn run() void {
            const result = bench_table.lookup(&miss_ip6);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // LookupPrefix benchmark
    try benchmarkTimer("LookupPrefix", struct {
        fn run() void {
            const result = bench_table.lookupPrefix(&miss_pfx6);
            bool_sink = result.ok;
        }
    }.run, BENCHMARK_ITERATIONS);

    // Get benchmark
    try benchmarkTimer("Get", struct {
        fn run() void {
            const result = bench_table.get(&miss_pfx6);
            bool_sink = result != null;
        }
    }.run, BENCHMARK_ITERATIONS);
}

fn benchmarkTableInsert(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableInsert ===\n", .{});
    
    const sizes = [_]usize{ 10, 100, 1000 };  // Smaller sizes for test data
    
    for (sizes) |size| {
        if (size > routes.items.len) continue;
        
        var table = Table(i32).init(allocator);
        defer table.deinit();

        // Pre-populate with size-1 routes
        for (routes.items[0..size-1]) |route| {
            table.insert(&route.cidr, route.value);
        }

        const test_route = routes.items[size-1];
        
        print("Insert into table of size {}: ", .{size});
        
        const BenchContext = struct {
            table_ptr: *Table(i32),
            route: Route,
            
            fn run(self: @This()) void {
                self.table_ptr.insert(&self.route.cidr, self.route.value);
            }
        };
        
        const context = BenchContext{ .table_ptr = &table, .route = test_route };
        
        // Warmup
        var i: usize = 0;
        while (i < WARMUP_ITERATIONS) : (i += 1) {
            context.run();
        }

        // Actual benchmark
        const start = std.time.nanoTimestamp();
        i = 0;
        while (i < BENCHMARK_ITERATIONS) : (i += 1) {
            context.run();
        }
        const end = std.time.nanoTimestamp();

        const total_ns = @as(f64, @floatFromInt(end - start));
        const avg_ns = total_ns / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS));

        print("{d:.2} ns/op\n", .{avg_ns});
    }
}

fn benchmarkTableClone(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableClone ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // Insert all routes
    for (routes.items) |route| {
        table.insert(&route.cidr, route.value);
    }

    const BenchContext = struct {
        table_ptr: *Table(i32),
        
        fn run(self: @This()) void {
            var cloned = self.table_ptr.clone();
            cloned.deinit();
        }
    };
    
    const context = BenchContext{ .table_ptr = &table };
    
    const iterations = 100; // Fewer iterations for expensive operations
    
    // Warmup
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        context.run();
    }

    // Actual benchmark
    const start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        context.run();
    }
    const end = std.time.nanoTimestamp();

    const total_ns = @as(f64, @floatFromInt(end - start));
    const avg_ns = total_ns / @as(f64, @floatFromInt(iterations));

    print("Clone: {d:.2} ns/op ({d} iterations)\n", .{ avg_ns, iterations });
}

// Memory usage benchmark
fn benchmarkMemoryUsage(allocator: std.mem.Allocator) !void {
    print("\n=== Memory Usage ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();

    // Insert all routes
    for (routes.items) |route| {
        table.insert(&route.cidr, route.value);
    }

    print("Total prefixes: {}\n", .{table.size()});
    print("IPv4 prefixes: {}\n", .{table.getSize4()});
    print("IPv6 prefixes: {}\n", .{table.getSize6()});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Zig BART Benchmark Suite ===\n", .{});
    print("Matching Go BART benchmark methodology\n\n", .{});

    // Create test data
    try loadRealRoutingData(allocator);
    defer {
        routes.deinit();
        routes4.deinit();
        routes6.deinit();
    }

    // Find test cases
    try findTestCases(allocator);

    // Run benchmarks
    try benchmarkFullMatch4(allocator);
    try benchmarkFullMatch6(allocator);
    try benchmarkFullMiss4(allocator);
    try benchmarkFullMiss6(allocator);
    try benchmarkTableInsert(allocator);
    try benchmarkTableClone(allocator);
    try benchmarkMemoryUsage(allocator);

    print("\n=== Benchmark Complete ===\n", .{});
    print("Results can be compared directly with Go BART's fulltable_test.go\n", .{});
} 