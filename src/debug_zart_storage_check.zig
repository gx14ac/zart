const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== ZART Storage Check ===\n", .{});
    
    // Create table
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Check what happens with /32 prefixes
    print("\nChecking /32 prefix storage:\n", .{});
    
    // Calculate maxDepth and lastBits for /32
    const max_depth_result = base_index.maxDepthLastBitsLookupTable[32];
    print("For /32 prefix: max_depth={}, last_bits={}\n", .{ max_depth_result.max_depth, max_depth_result.last_bits });
    
    // Insert 192.168.0.1/32
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const prefix1 = Prefix.init(&addr1, 32).masked();
    print("\nInserting 192.168.0.1/32\n", .{});
    print("  Octets: [192, 168, 0, 1]\n", .{});
    print("  At depth=3, octet=1\n", .{});
    print("  depth(3) vs max_depth({}): ", .{max_depth_result.max_depth});
    if (3 == max_depth_result.max_depth) {
        print("EQUAL - stored in node.prefixes\n", .{});
    } else {
        print("NOT EQUAL - stored as leafNode\n", .{});
    }
    
    table.insert(&prefix1, 1);
    
    // Insert 192.168.0.2/32
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const prefix2 = Prefix.init(&addr2, 32).masked();
    print("\nInserting 192.168.0.2/32\n", .{});
    print("  At depth=3, octet=2\n", .{});
    
    table.insert(&prefix2, 2);
    
    // Test lookups
    print("\n=== Lookup Tests ===\n", .{});
    
    for (1..4) |i| {
        const test_addr = IPAddr{ .v4 = .{ 192, 168, 0, @intCast(i) } };
        const result = table.lookup(&test_addr);
        print("Lookup 192.168.0.{}: value={}, ok={}\n", .{ i, if (result.ok) result.value else 0, result.ok });
    }
    
    // The key question
    print("\n=== Key Question ===\n", .{});
    print("ZART's maxDepthAndLastBits calculation:\n", .{});
    print("  For /32: max_depth={}, last_bits={}\n", .{ max_depth_result.max_depth, max_depth_result.last_bits });
    print("  IPv4 has 4 octets (indices 0-3)\n", .{});
    print("  Last octet is at depth=3\n", .{});
    print("  So depth=3 vs max_depth={}\n", .{max_depth_result.max_depth});
    
    if (max_depth_result.max_depth == 3) {
        print("\n✓ /32 prefixes are stored in node.prefixes array\n", .{});
        print("  This matches our expectation\n", .{});
    } else {
        print("\n✗ /32 prefixes are stored as leafNodes\n", .{});
        print("  This is different from what we expected!\n", .{});
    }
} 