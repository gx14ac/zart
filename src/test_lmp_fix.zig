const std = @import("std");
const table_mod = @import("table.zig");
const node_mod = @import("node.zig");
const print = std.debug.print;

const Table = table_mod.Table;
const Prefix = node_mod.Prefix;
const IPAddr = node_mod.IPAddr;

/// Helper function - equivalent to Go BART's netip.MustParseAddr
fn mpa(addr_str: []const u8) IPAddr {
    return parseIPAddress(addr_str) catch |err| {
        std.debug.panic("Invalid IP address: {s}, error: {}\n", .{addr_str, err});
    };
}

/// Helper function - equivalent to Go BART's netip.MustParsePrefix
fn mpp(prefix_str: []const u8) Prefix {
    const slash_pos = std.mem.indexOf(u8, prefix_str, "/") orelse {
        std.debug.panic("Invalid prefix format: {s}\n", .{prefix_str});
    };
    
    const addr_str = prefix_str[0..slash_pos];
    const bits_str = prefix_str[slash_pos + 1..];
    
    const addr = parseIPAddress(addr_str) catch {
        std.debug.panic("Invalid IP address in prefix: {s}\n", .{addr_str});
    };
    
    const bits = std.fmt.parseInt(u8, bits_str, 10) catch {
        std.debug.panic("Invalid bits in prefix: {s}\n", .{bits_str});
    };
    
    return Prefix.init(&addr, bits);
}

/// Parse IPv4 address from string
fn parseIPAddress(addr_str: []const u8) !IPAddr {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var start: usize = 0;
    
    for (addr_str, 0..) |c, i| {
        if (c == '.' or i == addr_str.len - 1) {
            const end = if (c == '.') i else i + 1;
            const part_str = addr_str[start..end];
            const part = std.fmt.parseInt(u8, part_str, 10) catch return error.InvalidIPAddress;
            
            if (part_idx >= 4) return error.InvalidIPAddress;
            parts[part_idx] = part;
            part_idx += 1;
            start = i + 1;
        }
    }
    
    if (part_idx != 4) return error.InvalidIPAddress;
    return IPAddr{ .v4 = parts };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("=== LMP Fix Verification ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    print("1. Insert 192.168.0.1/32 → 1\n", .{});
    table.insert(&mpp("192.168.0.1/32"), 1);
    
    print("2. Insert 192.168.0.2/32 → 2\n", .{});
    table.insert(&mpp("192.168.0.2/32"), 2);
    
    print("3. Insert 192.168.0.0/26 → 7\n", .{});
    table.insert(&mpp("192.168.0.0/26"), 7);
    
    // Test the critical LMP case
    const addr = mpa("192.168.0.3");
    const result = table.lookup(&addr);
    
    print("\nLMP Test Result:\n", .{});
    print("192.168.0.3 lookup: ok={}, value={}\n", .{result.ok, if (result.ok) result.value else -1});
    
    if (result.ok and result.value == 7) {
        print("✅ LMP Problem FIXED! 192.168.0.3 correctly matches 192.168.0.0/26 → 7\n", .{});
    } else {
        print("❌ LMP Problem still exists. Expected: value=7, got: {}\n", .{if (result.ok) result.value else -1});
        return;
    }
    
    // Additional verification tests
    print("\nAdditional verification tests:\n", .{});
    
    // Test 192.168.0.1 (should match /32)
    const addr1 = mpa("192.168.0.1");
    const result1 = table.lookup(&addr1);
    print("192.168.0.1 lookup: ok={}, value={} (expected: 1)\n", .{result1.ok, if (result1.ok) result1.value else -1});
    
    // Test 192.168.0.2 (should match /32)
    const addr2 = mpa("192.168.0.2");
    const result2 = table.lookup(&addr2);
    print("192.168.0.2 lookup: ok={}, value={} (expected: 2)\n", .{result2.ok, if (result2.ok) result2.value else -1});
    
    // Test 192.168.0.63 (should match /26)
    const addr63 = mpa("192.168.0.63");
    const result63 = table.lookup(&addr63);
    print("192.168.0.63 lookup: ok={}, value={} (expected: 7)\n", .{result63.ok, if (result63.ok) result63.value else -1});
    
    // Test 192.168.0.64 (should not match)
    const addr64 = mpa("192.168.0.64");
    const result64 = table.lookup(&addr64);
    print("192.168.0.64 lookup: ok={}, value={} (expected: not found)\n", .{result64.ok, if (result64.ok) result64.value else -1});
    
    print("\n=== Test Summary ===\n", .{});
    if (result.ok and result.value == 7 and
        result1.ok and result1.value == 1 and
        result2.ok and result2.value == 2 and
        result63.ok and result63.value == 7 and
        !result64.ok) {
        print("🎉 ALL TESTS PASSED! LMP implementation is working correctly.\n", .{});
    } else {
        print("⚠️  Some tests failed. Please check the implementation.\n", .{});
    }
} 