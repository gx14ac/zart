const std = @import("std");
const print = std.debug.print;
const DirectNode = @import("direct_node.zig").DirectNode;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Simple DirectNode Get Test ===\n\n", .{});
    
    // Create a DirectNode directly
    const node = DirectNode(i32).init(allocator);
    defer node.deinit();
    
    // Insert a simple /24 prefix
    const addr = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const prefix = Prefix.init(&addr, 24).masked();
    
    print("Inserting 10.0.0.0/24 -> 100\n", .{});
    const insert_result = try node.insertAtDepth(prefix, 100, 0);
    print("Insert result (false=new, true=exists): {}\n", .{insert_result});
    
    // Try to get it back
    print("\nTrying to get 10.0.0.0/24:\n", .{});
    const result = node.get(&prefix);
    if (result) |val| {
        print("  Result: {} (SUCCESS)\n", .{val});
    } else {
        print("  Result: null (FAILED)\n", .{});
    }
    
    // Debug: Check if it's in prefixes
    print("\nDebug info:\n", .{});
    print("  prefixes_len: {}\n", .{node.prefixes_len});
    print("  children_len: {}\n", .{node.children_len});
    print("  leaf_len: {}\n", .{node.leaf_len});
    print("  fringe_len: {}\n", .{node.fringe_len});
    
    // Check the index
    const max_depth_info = base_index.maxDepthAndLastBits(24);
    print("\nFor /24: max_depth={}, last_bits={}\n", .{ max_depth_info.max_depth, max_depth_info.last_bits });
    
    // At depth 0, we should be checking max_depth
    print("At depth=0: 0 == {} ? {}\n", .{ max_depth_info.max_depth, 0 == max_depth_info.max_depth });
} 