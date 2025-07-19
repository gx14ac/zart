const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Comprehensive Insert Test ===\n\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Test 1: Insert /32 prefixes
    print("Test 1: Insert /32 prefixes\n", .{});
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const prefix1 = Prefix.init(&addr1, 32).masked();
    table.insert(&prefix1, 1);
    
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const prefix2 = Prefix.init(&addr2, 32).masked();
    table.insert(&prefix2, 2);
    
    print("  Inserted 192.168.0.1/32 -> 1\n", .{});
    print("  Inserted 192.168.0.2/32 -> 2\n", .{});
    
    // Verify with get
    const get1 = table.get(&prefix1);
    const get2 = table.get(&prefix2);
    print("  get(192.168.0.1/32): {?}\n", .{get1});
    print("  get(192.168.0.2/32): {?}\n", .{get2});
    
    // Test 2: Insert /24 prefix
    print("\nTest 2: Insert /24 prefix\n", .{});
    const addr3 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const prefix3 = Prefix.init(&addr3, 24).masked();
    table.insert(&prefix3, 100);
    print("  Inserted 10.0.0.0/24 -> 100\n", .{});
    
    const get3 = table.get(&prefix3);
    print("  get(10.0.0.0/24): {?}\n", .{get3});
    
    // Test 3: Insert overlapping prefixes
    print("\nTest 3: Insert overlapping prefixes\n", .{});
    const addr4 = IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    const prefix4 = Prefix.init(&addr4, 26).masked();
    table.insert(&prefix4, 7);
    print("  Inserted 192.168.0.0/26 -> 7\n", .{});
    
    // Test 4: Lookup tests
    print("\nTest 4: Lookup tests\n", .{});
    const test_addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const test_addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const test_addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const test_addr4 = IPAddr{ .v4 = .{ 10, 0, 0, 5 } };
    
    const lookup1 = table.lookup(&test_addr1);
    const lookup2 = table.lookup(&test_addr2);
    const lookup3 = table.lookup(&test_addr3);
    const lookup4 = table.lookup(&test_addr4);
    
    print("  lookup(192.168.0.1): {?}\n", .{lookup1});
    print("  lookup(192.168.0.2): {?}\n", .{lookup2});
    print("  lookup(192.168.0.3): {?}\n", .{lookup3});
    print("  lookup(10.0.0.5): {?}\n", .{lookup4});
    
    // Test 5: Insert and update
    print("\nTest 5: Insert and update\n", .{});
    table.insert(&prefix1, 999);  // Update existing
    const get1_updated = table.get(&prefix1);
    print("  Updated 192.168.0.1/32 -> 999\n", .{});
    print("  get(192.168.0.1/32): {?}\n", .{get1_updated});
    
    // Test 6: Table size
    print("\nTest 6: Table statistics\n", .{});
    print("  Total size: {}\n", .{table.size()});
    print("  IPv4 size: {}\n", .{table.size4});
    print("  IPv6 size: {}\n", .{table.size6});
    
    // Check internal structure
    print("\nInternal structure:\n", .{});
    print("  root4.children_len: {}\n", .{table.root4.children_len});
    print("  root4.prefixes_len: {}\n", .{table.root4.prefixes_len});
    print("  root4.leaf_len: {}\n", .{table.root4.leaf_len});
    print("  root4.fringe_len: {}\n", .{table.root4.fringe_len});
} 