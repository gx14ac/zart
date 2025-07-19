const std = @import("std");
const print = std.debug.print;
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;

// Utility functions from benchmark
fn mpa(addr_str: []const u8) IPAddr {
    return parseIPAddress(addr_str) catch {
        std.debug.panic("Invalid IP address: {s}\n", .{addr_str});
    };
}

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

fn parseIPAddress(addr_str: []const u8) !IPAddr {
    if (std.mem.indexOf(u8, addr_str, ":") == null) {
        // IPv4
        var parts: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, addr_str, '.');
        var i: usize = 0;
        while (it.next()) |part| {
            if (i >= 4) return error.InvalidIPv4;
            parts[i] = try std.fmt.parseInt(u8, part, 10);
            i += 1;
        }
        if (i != 4) return error.InvalidIPv4;
        return IPAddr{ .v4 = parts };
    } else {
        // IPv6 (simplified implementation)
        const parts: [16]u8 = std.mem.zeroes([16]u8);
        // For now, simplified IPv6 parsing
        return IPAddr{ .v6 = parts };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var table = Table(i32).init(allocator);
    defer table.deinit();

    print("=== Exact Benchmark Test Replication ===\n", .{});
    
    // EXACT replication of failing test case
    print("Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    table.insert(&mpp("192.168.0.1/32"), 1);
    
    print("Table size after first insert: {}\n", .{table.size()});
    
    // Test the exact failing case
    print("\nTesting lookup for 192.168.0.1 (should succeed):\n", .{});
    const addr1 = mpa("192.168.0.1");
    const result1 = table.lookup(&addr1);
    print("Lookup 192.168.0.1: value={}, ok={}\n", .{ result1.value, result1.ok });
    
    if (!result1.ok) {
        print("❌ CRITICAL BUG: First insertion failed lookup!\n", .{});
        print("This suggests the issue is in forward traversal, not backtracking.\n", .{});
        
        // Debug the tree structure
        print("\nDebugging tree structure:\n", .{});
        const root4 = table.root4;
        print("Root4 state:\n", .{});
        print("  children_len: {}\n", .{root4.children_len});
        print("  prefixes_len: {}\n", .{root4.prefixes_len});
        print("  leaf_len: {}\n", .{root4.leaf_len});
        print("  fringe_len: {}\n", .{root4.fringe_len});
        
        if (root4.leaf_len > 0) {
            print("  This is a leaf node case!\n", .{});
            print("  The issue is in leaf node handling, not backtracking.\n", .{});
        }
    } else {
        print("✅ First lookup succeeded\n", .{});
        
        // Test the other cases
        print("\nTesting other addresses that should fail:\n", .{});
        
        const test_cases = [_]struct { addr: []const u8, want: i32 }{
            .{ .addr = "192.168.0.2", .want = -1 },
            .{ .addr = "192.168.0.3", .want = -1 },
            .{ .addr = "192.168.0.255", .want = -1 },
        };
        
        for (test_cases) |tc| {
            const addr = mpa(tc.addr);
            const result = table.lookup(&addr);
            print("Lookup {s}: value={}, ok={}", .{ tc.addr, result.value, result.ok });
            
            if (tc.want == -1) {
                if (result.ok) {
                    print(" ❌ Should have failed but succeeded!\n", .{});
                } else {
                    print(" ✅ Correctly failed\n", .{});
                }
            } else {
                if (!result.ok or result.value != tc.want) {
                    print(" ❌ Expected {} but got {}\n", .{ tc.want, result.value });
                } else {
                    print(" ✅ Correct\n", .{});
                }
            }
        }
    }
    
    print("\n=== Step 2: Add second insertion to replicate exact failing scenario ===\n", .{});
    
    // Add the second insertion like in the benchmark
    print("Step 2: Insert 192.168.0.2/32 -> 2\n", .{});
    table.insert(&mpp("192.168.0.2/32"), 2);
    
    print("Table size after second insert: {}\n", .{table.size()});
    
    // Test ALL the exact same cases as benchmark
    print("\nTesting ALL addresses after second insertion:\n", .{});
    
    const full_test_cases = [_]struct { addr: []const u8, want: i32 }{
        .{ .addr = "192.168.0.1", .want = 1 },
        .{ .addr = "192.168.0.2", .want = 2 },
        .{ .addr = "192.168.0.3", .want = -1 },
        .{ .addr = "192.168.0.255", .want = -1 },
        .{ .addr = "192.168.1.1", .want = -1 },
        .{ .addr = "192.170.1.1", .want = -1 },
        .{ .addr = "192.180.0.1", .want = -1 },
        .{ .addr = "192.180.3.5", .want = -1 },
        .{ .addr = "10.0.0.5", .want = -1 },
        .{ .addr = "10.0.0.15", .want = -1 },
    };
    
    var has_error = false;
    for (full_test_cases) |tc| {
        const addr = mpa(tc.addr);
        const result = table.lookup(&addr);
        
        if (tc.want == -1) {
            if (result.ok) {
                print("❌ Lookup {s}: got ({}, true), want (_, false)\n", .{ tc.addr, result.value });
                has_error = true;
            } else {
                print("✅ Lookup {s}: correctly failed\n", .{ tc.addr });
            }
        } else {
            if (!result.ok) {
                print("❌ Lookup {s}: got (_, false), want ({}, true)\n", .{ tc.addr, tc.want });
                has_error = true;
            } else if (result.value != tc.want) {
                print("❌ Lookup {s}: got ({}, true), want ({}, true)\n", .{ tc.addr, result.value, tc.want });
                has_error = true;
            } else {
                print("✅ Lookup {s}: got ({}, true) as expected\n", .{ tc.addr, result.value });
            }
        }
    }
    
    if (has_error) {
        print("\n❌ Found errors! This replicates the benchmark failure.\n", .{});
    } else {
        print("\n✅ All tests passed! The issue might be elsewhere.\n", .{});
    }
} 