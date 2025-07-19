const std = @import("std");
const print = std.debug.print;
const DirectNode = @import("direct_node.zig").DirectNode;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");

pub fn main() !void {
    print("=== InsertAtDepth Trace ===\n\n", .{});
    
    // Test case: 10.0.0.0/24
    const addr = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const prefix = Prefix.init(&addr, 24).masked();
    _ = prefix;
    
    print("Inserting 10.0.0.0/24:\n", .{});
    print("  octets: [10, 0, 0, 0]\n", .{});
    print("  bits: 24\n", .{});
    
    const max_depth_info = base_index.maxDepthAndLastBits(24);
    print("  max_depth: {}\n", .{max_depth_info.max_depth});
    print("  last_bits: {}\n", .{max_depth_info.last_bits});
    
    print("\ninsertAtDepth logic:\n", .{});
    print("  Starting at depth=0\n", .{});
    print("  Loop: while (current_depth < octets.len)\n", .{});
    print("    depth=0, octet=10:\n", .{});
    print("      if (0 == 3) -> false\n", .{});
    print("      children_bitset.isSet(10) -> false\n", .{});
    print("      isFringe(0, 24) -> {}\n", .{base_index.isFringe(0, 24)});
    
    if (base_index.isFringe(0, 24)) {
        print("      -> insertFringeDirectOptimized\n", .{});
    } else {
        print("      -> insertLeafDirectOptimized\n", .{});
    }
    
    print("\n=== The Problem ===\n", .{});
    print("For 10.0.0.0/24:\n", .{});
    print("- Should be inserted at depth=3 in prefixes array\n", .{});
    print("- But at depth=0, it's being inserted as a leafNode\n", .{});
    print("- This is because the node doesn't have children at octet 10\n", .{});
} 