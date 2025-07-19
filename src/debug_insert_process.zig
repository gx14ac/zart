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

    print("=== InsertAtDepth Process Debug ===\n\n", .{});
    
    // Create a DirectNode
    const node = DirectNode(i32).init(allocator);
    defer node.deinit();
    
    // Test case: 10.0.0.0/24
    const addr = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const prefix = Prefix.init(&addr, 24).masked();
    
    print("Inserting 10.0.0.0/24 (value=100):\n", .{});
    print("  octets: [10, 0, 0, 0]\n", .{});
    print("  bits: 24\n", .{});
    print("  max_depth: 3, last_bits: 0\n\n", .{});
    
    print("Expected behavior (Go BART):\n", .{});
    print("  depth=0: octet=10, no child exists -> create new node\n", .{});
    print("  depth=1: octet=0, no child exists -> create new node\n", .{});
    print("  depth=2: octet=0, no child exists -> create new node\n", .{});
    print("  depth=3: octet=0, depth==max_depth -> insert in prefixes[idx]\n\n", .{});
    
    print("Current behavior (ZART):\n", .{});
    print("  depth=0: octet=10, no child exists -> insert as leafNode\n", .{});
    print("  This is wrong! We need to create intermediate nodes.\n\n", .{});
    
    // Actually insert it
    const result = try node.insertAtDepth(prefix, 100, 0);
    print("Insert result: {} (false=new)\n", .{result});
    
    print("\nNode structure after insert:\n", .{});
    print("  children_len: {}\n", .{node.children_len});
    print("  prefixes_len: {}\n", .{node.prefixes_len});
    print("  leaf_len: {}\n", .{node.leaf_len});
    print("  fringe_len: {}\n", .{node.fringe_len});
    
    // Now test get
    print("\nTrying get(10.0.0.0/24):\n", .{});
    const get_result = node.get(&prefix);
    if (get_result) |val| {
        print("  Result: {} (SUCCESS)\n", .{val});
    } else {
        print("  Result: null (FAILED)\n", .{});
    }
    
    // Test with /32
    print("\n--- Test with /32 ---\n", .{});
    const addr32 = IPAddr{ .v4 = .{ 1, 2, 3, 4 } };
    const prefix32 = Prefix.init(&addr32, 32).masked();
    
    print("Inserting 1.2.3.4/32 (value=1234):\n", .{});
    const result32 = try node.insertAtDepth(prefix32, 1234, 0);
    print("Insert result: {} (false=new)\n", .{result32});
    
    print("\nNode structure after insert:\n", .{});
    print("  children_len: {}\n", .{node.children_len});
    print("  prefixes_len: {}\n", .{node.prefixes_len});
    print("  leaf_len: {}\n", .{node.leaf_len});
    print("  fringe_len: {}\n", .{node.fringe_len});
} 