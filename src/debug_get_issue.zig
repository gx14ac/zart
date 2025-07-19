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

    print("=== Get Method Issue Investigation ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert 1.2.3.4/32 -> 1234
    const addr = IPAddr{ .v4 = .{ 1, 2, 3, 4 } };
    const prefix = Prefix.init(&addr, 32).masked();
    print("\nInserting 1.2.3.4/32 -> 1234\n", .{});
    table.insert(&prefix, 1234);
    
    // Check maxDepth for /32
    const max_depth_info = base_index.maxDepthAndLastBits(32);
    print("For /32: max_depth={}, last_bits={}\n", .{ max_depth_info.max_depth, max_depth_info.last_bits });
    
    // Test get
    print("\nTesting get(1.2.3.4/32):\n", .{});
    const result = table.get(&prefix);
    if (result) |val| {
        print("  Result: {} (SUCCESS)\n", .{val});
    } else {
        print("  Result: null (FAILED)\n", .{});
    }
    
    // Test lookup
    print("\nTesting lookup(1.2.3.4):\n", .{});
    const lookup_result = table.lookup(&addr);
    if (lookup_result.ok) {
        print("  Result: value={} (SUCCESS)\n", .{lookup_result.value});
    } else {
        print("  Result: not found (FAILED)\n", .{});
    }
    
    // Analyze the difference
    print("\n=== Analysis ===\n", .{});
    print("If lookup succeeds but get fails, it means:\n", .{});
    print("- The prefix is stored as a leafNode (due to maxDepth=4)\n", .{});
    print("- lookup can find it through leafNode.prefix.Contains()\n", .{});
    print("- But get expects it in node.prefixes array\n", .{});
    
    // Test with a non-/32 prefix
    print("\n=== Testing with /24 prefix ===\n", .{});
    const addr2 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const prefix2 = Prefix.init(&addr2, 24).masked();
    table.insert(&prefix2, 999);
    
    const result2 = table.get(&prefix2);
    if (result2) |val| {
        print("get(10.0.0.0/24): {} (SUCCESS)\n", .{val});
    } else {
        print("get(10.0.0.0/24): null (FAILED)\n", .{});
    }
} 