const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

/// Helper function - equivalent to Go BART's netip.MustParseAddr
fn mpa(addr_str: []const u8) IPAddr {
    return parseIPAddress(addr_str) catch {
        std.debug.panic("Invalid IP address: {s}\n", .{addr_str});
    };
}

/// Helper function - equivalent to Go BART's netip.MustParsePrefix
fn mpp(prefix_str: []const u8) Prefix {
    const slash_pos = std.mem.indexOf(u8, prefix_str, "/") orelse {
        std.debug.panic("Invalid prefix (no /): {s}\n", .{prefix_str});
    };
    
    const addr_str = prefix_str[0..slash_pos];
    const len_str = prefix_str[slash_pos + 1..];
    
    const prefix_len = std.fmt.parseInt(u8, len_str, 10) catch {
        std.debug.panic("Invalid prefix length: {s}\n", .{len_str});
    };
    
    const addr = parseIPAddress(addr_str) catch {
        std.debug.panic("Invalid IP address in prefix: {s}\n", .{addr_str});
    };
    
    const is_valid = switch (addr) {
        .v4 => prefix_len <= 32,
        .v6 => prefix_len <= 128,
    };
    if (!is_valid) {
        std.debug.panic("Invalid prefix length for IP version: {s}\n", .{prefix_str});
    }
    
    const prefix = Prefix.init(&addr, prefix_len);
    return prefix.masked();
}

/// Parse IP address from string - supports both IPv4 and IPv6
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
        // IPv6 - simplified parsing for test purposes
        const parts: [16]u8 = std.mem.zeroes([16]u8);
        return IPAddr{ .v6 = parts };
    }
}

const TableTest = struct {
    addr: []const u8,
    want: i32, // -1 if we expect a lookup miss
};

fn checkRoutes(table: *Table(i32), tests: []const TableTest) !void {
    for (tests) |test_case| {
        const addr = mpa(test_case.addr);
        const result = table.lookup(&addr);
        
        print("DEBUG: Lookup({s}) -> value={}, ok={}, want={}\n", .{ test_case.addr, result.value, result.ok, test_case.want });
        
        if (!result.ok and test_case.want != -1) {
            print("ERROR: Lookup {s} got (_, false), want ({}, true)\n", .{ test_case.addr, test_case.want });
            return error.TestFailure;
        }
        if (result.ok and result.value != test_case.want) {
            print("ERROR: Lookup {s} got ({}, true), want ({}, true)\n", .{ test_case.addr, result.value, test_case.want });
            return error.TestFailure;
        }
    }
    print("All route checks passed!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== ZART Benchmark Debug Test ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Create a new leaf strideTable, with compressed path
    print("Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    const prefix = mpp("192.168.0.1/32");
    print("Parsed prefix: addr={}, bits={}\n", .{ prefix.addr, prefix.bits });
    
    table.insert(&prefix, 1);
    print("Insert completed, table size: {}\n", .{table.size()});
    
    print("Step 2: Test basic lookups\n", .{});
    try checkRoutes(&table, &[_]TableTest{
        .{ .addr = "192.168.0.1", .want = 1 },
        .{ .addr = "192.168.0.2", .want = -1 },
    });
    
    print("✅ All tests passed!\n", .{});
} 