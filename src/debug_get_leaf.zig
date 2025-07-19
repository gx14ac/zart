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

    print("=== Get LeafNode Debug ===\n\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert 1.2.3.4/32
    const addr = IPAddr{ .v4 = .{ 1, 2, 3, 4 } };
    const prefix = Prefix.init(&addr, 32).masked();
    
    print("Inserting 1.2.3.4/32 -> 1234\n", .{});
    table.insert(&prefix, 1234);
    
    print("\nChecking root node:\n", .{});
    print("  root4.leaf_bitset.isSet(1): {}\n", .{table.root4.leaf_bitset.isSet(1)});
    
    if (table.root4.leaf_bitset.isSet(1)) {
        print("  LeafNode exists at octet 1\n", .{});
        const leaf_rank = table.root4.leaf_bitset.rank(1) - 1;
        const leaf = table.root4.leaf_items[leaf_rank];
        print("  Leaf prefix: {}\n", .{leaf.prefix});
        print("  Leaf value: {}\n", .{leaf.value});
        
        // Check if it matches our prefix
        print("\nChecking prefix match:\n", .{});
        print("  leaf.prefix.eql(prefix): {}\n", .{leaf.prefix.eql(prefix)});
    }
    
    print("\nGet method trace:\n", .{});
    print("  octets = [1, 2, 3, 4]\n", .{});
    print("  Loop iteration:\n", .{});
    print("    depth=0, octet=1:\n", .{});
    print("      depth (0) == max_depth (4)? false\n", .{});
    print("      children_bitset.isSet(1)? false\n", .{});
    print("      Should check leaf_bitset.isSet(1)\n", .{});
    print("      Then check if leaf.prefix.eql(masked_pfx)\n", .{});
} 