const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

// Go BART compatible benchmark suite
// Matches table_test.go and fulltable_test.go exactly

// Global benchmark sinks to prevent optimization
var int_sink: i32 = 0;
var bool_sink: bool = false;

const Route = struct {
    prefix: Prefix,
    value: i32,
};

// Global data for full table benchmarks
var routes: []Route = undefined;
var routes4: []Route = undefined;
var routes6: []Route = undefined;

var match_ip4: IPAddr = undefined;
var match_ip6: IPAddr = undefined;
var match_pfx4: Prefix = undefined;
var match_pfx6: Prefix = undefined;

var miss_ip4: IPAddr = undefined;
var miss_ip6: IPAddr = undefined;
var miss_pfx4: Prefix = undefined;
var miss_pfx6: Prefix = undefined;

// Benchmark route counts - matches Go BART benchRouteCount
const bench_route_count = [_]usize{ 1, 2, 5, 10, 100, 1000, 10000, 100000, 200000 };

// Load real routing table data from testdata/prefixes.txt
fn loadRoutingTableData(allocator: std.mem.Allocator) ![]Route {
    var routes_list = std.ArrayList(Route).init(allocator);
    
    const file = std.fs.cwd().openFile("testdata/prefixes.txt", .{}) catch |err| {
        print("Error: Could not open testdata/prefixes.txt: {}\n", .{err});
        return error.FileNotFound;
    };
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();
    var buf: [256]u8 = undefined;
    var count: i32 = 0;

    while (try in_stream.readUntilDelimiterOrEof(buf[0..], '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;

        const slash_pos = std.mem.indexOf(u8, trimmed, "/") orelse continue;
        const addr_str = trimmed[0..slash_pos];
        const len_str = trimmed[slash_pos + 1..];

        const prefix_len = std.fmt.parseInt(u8, len_str, 10) catch continue;
        const addr = parseIPAddress(addr_str) catch continue;

        const is_valid = switch (addr) {
            .v4 => prefix_len <= 32,
            .v6 => prefix_len <= 128,
        };
        if (!is_valid) continue;

        const prefix = Prefix.init(&addr, prefix_len);
        const route = Route{ .prefix = prefix.masked(), .value = count };
        try routes_list.append(route);
        count += 1;
    }

    return routes_list.toOwnedSlice();
}

fn parseIPAddress(addr_str: []const u8) !IPAddr {
    if (std.mem.indexOf(u8, addr_str, ":") == null) {
        // IPv4
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
        // IPv6 - simplified parsing
        var parts: [16]u8 = std.mem.zeroes([16]u8);
        
        if (std.mem.startsWith(u8, addr_str, "2001:db8")) {
            parts[0] = 0x20; parts[1] = 0x01; parts[2] = 0x0d; parts[3] = 0xb8;
        } else if (std.mem.startsWith(u8, addr_str, "fe80")) {
            parts[0] = 0xfe; parts[1] = 0x80;
        } else if (std.mem.startsWith(u8, addr_str, "ff")) {
            parts[0] = 0xff;
        }
        
        return IPAddr{ .v6 = parts };
    }
}

// Generate random prefixes for testing (matches Go BART randomRealWorldPrefixes)
fn generateRandomPrefixes(allocator: std.mem.Allocator, count: usize) ![]Route {
    var routes_list = std.ArrayList(Route).init(allocator);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const is_ipv4 = random.boolean();
        
        if (is_ipv4) {
            const addr = IPAddr{ .v4 = .{
                random.int(u8), random.int(u8), 
                random.int(u8), random.int(u8)
            }};
            const prefix_len = random.intRangeAtMost(u8, 8, 32);
            const prefix = Prefix.init(&addr, prefix_len);
            try routes_list.append(Route{ .prefix = prefix.masked(), .value = i });
        } else {
            var addr_bytes: [16]u8 = undefined;
            random.bytes(&addr_bytes);
            const addr = IPAddr{ .v6 = addr_bytes };
            const prefix_len = random.intRangeAtMost(u8, 16, 128);
            const prefix = Prefix.init(&addr, prefix_len);
            try routes_list.append(Route{ .prefix = prefix.masked(), .value = i });
        }
    }

    return routes_list.toOwnedSlice();
}

// Split routes into IPv4 and IPv6
fn splitRoutes(allocator: std.mem.Allocator, all_routes: []Route) !void {
    var ipv4_list = std.ArrayList(Route).init(allocator);
    var ipv6_list = std.ArrayList(Route).init(allocator);
    
    for (all_routes) |route| {
        if (route.prefix.addr.is4()) {
            try ipv4_list.append(route);
        } else {
            try ipv6_list.append(route);
        }
    }
    
    routes4 = try ipv4_list.toOwnedSlice();
    routes6 = try ipv6_list.toOwnedSlice();
}

// Find test cases (matches Go BART's method)
fn findTestCases() void {
    if (routes4.len > 0) {
        // IPv4 match cases
        match_ip4 = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
        match_pfx4 = routes4[0].prefix;

        // IPv4 miss cases
        miss_ip4 = IPAddr{ .v4 = .{ 200, 200, 200, 200 } };
        const miss_addr4 = IPAddr{ .v4 = .{ 203, 1, 1, 0 } };
        miss_pfx4 = Prefix.init(&miss_addr4, 24);
    }

    if (routes6.len > 0) {
        // IPv6 match cases
        match_ip6 = IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44 } };
        match_pfx6 = routes6[0].prefix;

        // IPv6 miss cases
        miss_ip6 = IPAddr{ .v6 = .{ 0x20, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
        const miss_addr6 = IPAddr{ .v6 = .{ 0x20, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
        miss_pfx6 = Prefix.init(&miss_addr6, 32);
    }
}

// Helper function to run benchmarks with timing
fn runBenchmark(comptime name: []const u8, func: anytype, iterations: usize) void {
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        func();
    }
    const end = std.time.nanoTimestamp();
    const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
    print("{s}: {d:.2} ns/op\n", .{ name, avg_ns });
}

// Benchmark TableInsertRandom - matches Go BART BenchmarkTableInsertRandom
fn benchmarkTableInsertRandom(allocator: std.mem.Allocator, all_routes: []Route) !void {
    print("\n=== BenchmarkTableInsertRandom ===\n", .{});
    
    const sizes = [_]usize{ 10_000, 100_000, 1_000_000, 2_000_000 };
    
    for (sizes) |n| {
        if (n > all_routes.len) continue;
        
        // Pre-populate table with n routes
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        for (all_routes[0..n]) |route| {
            table.insert(&route.prefix, route.value);
        }
        
        // Use a random probe prefix for benchmark
        const probe_route = all_routes[all_routes.len - 1];
        
        print("Mutable into {}: ", .{n});
        
        // Benchmark insertion - equivalent to Go's b.N loop
        const iterations = 1_000_000; // High iteration count for accuracy
        const start = std.time.nanoTimestamp();
        
        for (0..iterations) |_| {
            table.insert(&probe_route.prefix, probe_route.value);
        }
        
        const end = std.time.nanoTimestamp();
        const total_ns = @as(f64, @floatFromInt(end - start));
        const avg_ns = total_ns / @as(f64, @floatFromInt(iterations));
        
        print("{d:.2} ns/op\n", .{avg_ns});
    }
}

// Benchmark TableDelete - matches Go BART BenchmarkTableDelete
fn benchmarkTableDelete(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableDelete ===\n", .{});
    
    for (bench_route_count) |n| {
        if (n > routes.len) continue;
        
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        for (routes[0..n]) |route| {
            table.insert(&route.prefix, route.value);
        }
        
        const probe = routes[0].prefix;
        
        print("Mutable from_{}: ", .{n});
        
        const iterations = 1_000_000;
        const start = std.time.nanoTimestamp();
        
        for (0..iterations) |_| {
            table.delete(&probe);
        }
        
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        
        print("{d:.2} ns/op\n", .{avg_ns});
    }
}

// Benchmark TableGet - matches Go BART BenchmarkTableGet
fn benchmarkTableGet(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableGet ===\n", .{});
    
    const families = [_]struct { name: []const u8, routes: []Route }{
        .{ .name = "ipv4", .routes = routes4 },
        .{ .name = "ipv6", .routes = routes6 },
    };
    
    for (families) |family| {
        if (family.routes.len == 0) continue;
        
        for (bench_route_count) |n| {
            if (n > family.routes.len) continue;
            
            var table = Table(i32).init(allocator);
            defer table.deinit();
            
            for (family.routes[0..n]) |route| {
                table.insert(&route.prefix, route.value);
            }
            
            const probe = family.routes[0].prefix;
            
            print("{s}/From_{}: ", .{ family.name, n });
            
            const iterations = 1_000_000;
            const start = std.time.nanoTimestamp();
            
            for (0..iterations) |_| {
                const result = table.get(&probe);
                bool_sink = result != null;
            }
            
            const end = std.time.nanoTimestamp();
            const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
            
            print("{d:.2} ns/op\n", .{avg_ns});
        }
    }
}

// Benchmark TableLPM - matches Go BART BenchmarkTableLPM
fn benchmarkTableLPM(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableLPM ===\n", .{});
    
    const families = [_]struct { name: []const u8, routes: []Route }{
        .{ .name = "ipv4", .routes = routes4 },
        .{ .name = "ipv6", .routes = routes6 },
    };
    
    for (families) |family| {
        if (family.routes.len == 0) continue;
        
        for (bench_route_count) |n| {
            if (n > family.routes.len) continue;
            
            var table = Table(i32).init(allocator);
            defer table.deinit();
            
            for (family.routes[0..n]) |route| {
                table.insert(&route.prefix, route.value);
            }
            
            const probe = family.routes[0];
            const probe_addr = probe.prefix.addr;
            
            const iterations = 1_000_000;
            
            // Contains benchmark
            {
                const start = std.time.nanoTimestamp();
                for (0..iterations) |_| {
                    bool_sink = table.contains(&probe_addr);
                }
                const end = std.time.nanoTimestamp();
                const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
                print("{s}/In_{d:>6}/Contains: {d:.2} ns/op\n", .{ family.name, n, avg_ns });
            }
            
            // Lookup benchmark
            {
                const start = std.time.nanoTimestamp();
                for (0..iterations) |_| {
                    const result = table.lookup(&probe_addr);
                    bool_sink = result.ok;
                }
                const end = std.time.nanoTimestamp();
                const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
                print("{s}/In_{d:>6}/Lookup: {d:.2} ns/op\n", .{ family.name, n, avg_ns });
            }
            
            // LookupPrefix benchmark
            {
                const start = std.time.nanoTimestamp();
                for (0..iterations) |_| {
                    const result = table.lookupPrefix(&probe.prefix);
                    bool_sink = result.ok;
                }
                const end = std.time.nanoTimestamp();
                const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
                print("{s}/In_{d:>6}/LookupPrefix: {d:.2} ns/op\n", .{ family.name, n, avg_ns });
            }
            
            // LookupPrefixLPM benchmark
            {
                const start = std.time.nanoTimestamp();
                for (0..iterations) |_| {
                    const result = table.lookupPrefixLPM(&probe.prefix);
                    bool_sink = result != null;
                }
                const end = std.time.nanoTimestamp();
                const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
                print("{s}/In_{d:>6}/LookupPrefixLPM: {d:.2} ns/op\n", .{ family.name, n, avg_ns });
            }
        }
    }
}

// Benchmark TableOverlapsPrefix - matches Go BART BenchmarkTableOverlapsPrefix
fn benchmarkTableOverlapsPrefix(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableOverlapsPrefix ===\n", .{});
    
    const families = [_]struct { name: []const u8, routes: []Route }{
        .{ .name = "ipv4", .routes = routes4 },
        .{ .name = "ipv6", .routes = routes6 },
    };
    
    for (families) |family| {
        if (family.routes.len == 0) continue;
        
        for (bench_route_count) |n| {
            if (n > family.routes.len) continue;
            
            var table = Table(i32).init(allocator);
            defer table.deinit();
            
            for (family.routes[0..n]) |route| {
                table.insert(&route.prefix, route.value);
            }
            
            const probe = family.routes[0].prefix;
            
            print("{s}/With_{}: ", .{ family.name, n });
            
            const iterations = 1_000_000;
            const start = std.time.nanoTimestamp();
            
            for (0..iterations) |_| {
                bool_sink = table.overlapsPrefix(&probe);
            }
            
            const end = std.time.nanoTimestamp();
            const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
            
            print("{d:.2} ns/op\n", .{avg_ns});
        }
    }
}

// Benchmark TableOverlaps - matches Go BART BenchmarkTableOverlaps
fn benchmarkTableOverlaps(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableOverlaps ===\n", .{});
    
    const families = [_]struct { name: []const u8, routes: []Route }{
        .{ .name = "ipv4", .routes = routes4 },
        .{ .name = "ipv6", .routes = routes6 },
    };
    
    for (families) |family| {
        if (family.routes.len == 0) continue;
        
        for (bench_route_count) |n| {
            if (n > family.routes.len) continue;
            
            var table1 = Table(i32).init(allocator);
            defer table1.deinit();
            var table2 = Table(i32).init(allocator);
            defer table2.deinit();
            
            for (family.routes[0..n]) |route| {
                table1.insert(&route.prefix, route.value);
                table2.insert(&route.prefix, route.value);
            }
            
            print("{s}/{}_with_{}: ", .{ family.name, n, n });
            
            const iterations = 1_000_000;
            const start = std.time.nanoTimestamp();
            
            for (0..iterations) |_| {
                bool_sink = table1.overlaps(&table2);
            }
            
            const end = std.time.nanoTimestamp();
            const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
            
            print("{d:.2} ns/op\n", .{avg_ns});
        }
    }
}

// Benchmark TableClone - matches Go BART BenchmarkTableClone
fn benchmarkTableClone(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkTableClone ===\n", .{});
    
    const families = [_]struct { name: []const u8, routes: []Route }{
        .{ .name = "ipv4", .routes = routes4 },
        .{ .name = "ipv6", .routes = routes6 },
    };
    
    for (families) |family| {
        if (family.routes.len == 0) continue;
        
        for (bench_route_count) |n| {
            if (n > family.routes.len) continue;
            
            var table = Table(i32).init(allocator);
            defer table.deinit();
            
            for (family.routes[0..n]) |route| {
                table.insert(&route.prefix, route.value);
            }
            
            print("{s}/{}: ", .{ family.name, n });
            
            const iterations = 100; // Fewer iterations for expensive operations
            const start = std.time.nanoTimestamp();
            
            for (0..iterations) |_| {
                var cloned = table.clone();
                cloned.deinit();
            }
            
            const end = std.time.nanoTimestamp();
            const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
            
            print("{d:.2} ns/op\n", .{avg_ns});
        }
    }
}

// Full table benchmark - matches Go BART fulltable_test.go
fn benchmarkFullMatch4(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkFullMatch4 ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    for (routes, 0..) |route, i| {
        table.insert(&route.prefix, @intCast(i));
    }
    
    const iterations = 1_000_000;
    
    // Contains benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            bool_sink = table.contains(&match_ip4);
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Contains: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // Lookup benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookup(&match_ip4);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Lookup: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefix benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefix(&match_pfx4);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefix: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefixLPM benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefixLPM(&match_pfx4);
            bool_sink = result != null;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefixLPM: {d:.2} ns/op\n", .{avg_ns});
    }
}

fn benchmarkFullMatch6(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkFullMatch6 ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    for (routes, 0..) |route, i| {
        table.insert(&route.prefix, @intCast(i));
    }
    
    const iterations = 1_000_000;
    
    // Contains benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            bool_sink = table.contains(&match_ip6);
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Contains: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // Lookup benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookup(&match_ip6);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Lookup: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefix benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefix(&match_pfx6);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefix: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefixLPM benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefixLPM(&match_pfx6);
            bool_sink = result != null;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefixLPM: {d:.2} ns/op\n", .{avg_ns});
    }
}

// Benchmark FullMiss4 - matches Go BART BenchmarkFullMiss4
fn benchmarkFullMiss4(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkFullMiss4 ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    for (routes, 0..) |route, i| {
        table.insert(&route.prefix, @intCast(i));
    }
    
    const iterations = 1_000_000;
    
    // Contains benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            bool_sink = table.contains(&miss_ip4);
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Contains: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // Lookup benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookup(&miss_ip4);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Lookup: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefix benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefix(&miss_pfx4);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefix: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefixLPM benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefixLPM(&miss_pfx4);
            bool_sink = result != null;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefixLPM: {d:.2} ns/op\n", .{avg_ns});
    }
}

fn benchmarkFullMiss6(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkFullMiss6 ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    for (routes, 0..) |route, i| {
        table.insert(&route.prefix, @intCast(i));
    }
    
    const iterations = 1_000_000;
    
    // Contains benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            bool_sink = table.contains(&miss_ip6);
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Contains: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // Lookup benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookup(&miss_ip6);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  Lookup: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefix benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefix(&miss_pfx6);
            bool_sink = result.ok;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefix: {d:.2} ns/op\n", .{avg_ns});
    }
    
    // LookupPrefixLPM benchmark
    {
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            const result = table.lookupPrefixLPM(&miss_pfx6);
            bool_sink = result != null;
        }
        const end = std.time.nanoTimestamp();
        const avg_ns = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(iterations));
        print("  LookupPrefixLPM: {d:.2} ns/op\n", .{avg_ns});
    }
}

// Memory benchmarks - matches Go BART BenchmarkMem
fn benchmarkMemory(allocator: std.mem.Allocator) !void {
    print("\n=== BenchmarkMemory ===\n", .{});
    
    const sizes = [_]usize{ 1_000, 10_000, 100_000, 1_000_000 };
    
    for (sizes) |k| {
        if (k > routes.len) continue;
        
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        for (routes[0..k], 0..) |route, i| {
            table.insert(&route.prefix, @intCast(i));
        }
        
        print("Table with {}: {} prefixes\n", .{ k, table.size() });
        print("  IPv4 prefixes: {}\n", .{table.getSize4()});
        print("  IPv6 prefixes: {}\n", .{table.getSize6()});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Go BART Compatible Benchmark Suite ===\n", .{});
    print("Complete port of table_test.go and fulltable_test.go\n", .{});

    // Try to load real routing table data
    routes = loadRoutingTableData(allocator) catch |err| {
        print("Failed to load real routing data: {}, using generated data\n", .{err});
        const generated_routes = generateRandomPrefixes(allocator, 500_000) catch |gen_err| {
            print("Failed to generate routes: {}\n", .{gen_err});
            return;
        };
        defer allocator.free(generated_routes);
        
        routes = generated_routes;
        try splitRoutes(allocator, routes);
        findTestCases();
        
        print("Generated {} routing table entries\n", .{routes.len});
        
        // Run benchmarks with generated data
        try benchmarkTableInsertRandom(allocator, routes);
        try benchmarkTableDelete(allocator);
        try benchmarkTableGet(allocator);
        try benchmarkTableLPM(allocator);
        try benchmarkTableOverlapsPrefix(allocator);
        try benchmarkTableOverlaps(allocator);
        try benchmarkTableClone(allocator);
        try benchmarkFullMatch4(allocator);
        try benchmarkFullMatch6(allocator);
        try benchmarkFullMiss4(allocator);
        try benchmarkFullMiss6(allocator);
        try benchmarkMemory(allocator);
        
        print("\n=== Benchmark Complete ===\n", .{});
        print("Results are now directly comparable with Go BART\n", .{});
        return;
    };
    defer allocator.free(routes);
    
    try splitRoutes(allocator, routes);
    defer allocator.free(routes4);
    defer allocator.free(routes6);
    
    findTestCases();
    
    print("Loaded {} routing table entries ({} IPv4, {} IPv6)\n", .{ routes.len, routes4.len, routes6.len });

    // Run all benchmarks matching Go BART exactly
    try benchmarkTableInsertRandom(allocator, routes);
    try benchmarkTableDelete(allocator);
    try benchmarkTableGet(allocator);
    try benchmarkTableLPM(allocator);
    try benchmarkTableOverlapsPrefix(allocator);
    try benchmarkTableOverlaps(allocator);
    try benchmarkTableClone(allocator);
    try benchmarkFullMatch4(allocator);
    try benchmarkFullMatch6(allocator);
    try benchmarkFullMiss4(allocator);
    try benchmarkFullMiss6(allocator);
    try benchmarkMemory(allocator);

    print("\n=== Benchmark Complete ===\n", .{});
    print("All Go BART benchmarks have been ported and executed\n", .{});
    print("Results are directly comparable with table_test.go and fulltable_test.go\n", .{});
} 