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

    print("=== /32 Prefix Get Debug ===\n\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert 1.2.3.4/32
    const addr = IPAddr{ .v4 = .{ 1, 2, 3, 4 } };
    const prefix = Prefix.init(&addr, 32).masked();
    
    print("Inserting 1.2.3.4/32 -> 1234\n", .{});
    table.insert(&prefix, 1234);
    
    print("\nTable structure after insert:\n", .{});
    print("  Table size: {}\n", .{table.size()});
    print("  root4.children_len: {}\n", .{table.root4.children_len});
    print("  root4.prefixes_len: {}\n", .{table.root4.prefixes_len});
    print("  root4.leaf_len: {}\n", .{table.root4.leaf_len});
    
    // Check if child at octet 1 exists
    if (table.root4.children_bitset.isSet(1)) {
        print("\nChild at octet 1 exists\n", .{});
        const rank = table.root4.children_bitset.rank(1) - 1;
        const child1 = table.root4.children_items[rank];
        
        print("  child1.children_len: {}\n", .{child1.children_len});
        print("  child1.prefixes_len: {}\n", .{child1.prefixes_len});
        print("  child1.leaf_len: {}\n", .{child1.leaf_len});
        
        // Check if child at octet 2 exists
        if (child1.children_bitset.isSet(2)) {
            print("\nChild at octet 2 exists\n", .{});
            const rank2 = child1.children_bitset.rank(2) - 1;
            const child2 = child1.children_items[rank2];
            
            print("  child2.children_len: {}\n", .{child2.children_len});
            print("  child2.prefixes_len: {}\n", .{child2.prefixes_len});
            print("  child2.leaf_len: {}\n", .{child2.leaf_len});
            
            // Check if child at octet 3 exists
            if (child2.children_bitset.isSet(3)) {
                print("\nChild at octet 3 exists\n", .{});
                const rank3 = child2.children_bitset.rank(3) - 1;
                const child3 = child2.children_items[rank3];
                
                print("  child3.children_len: {}\n", .{child3.children_len});
                print("  child3.prefixes_len: {}\n", .{child3.prefixes_len});
                print("  child3.leaf_len: {}\n", .{child3.leaf_len});
                
                // Check if child at octet 4 exists
                if (child3.children_bitset.isSet(4)) {
                    print("\nChild at octet 4 exists\n", .{});
                    const rank4 = child3.children_bitset.rank(4) - 1;
                    const child4 = child3.children_items[rank4];
                    
                    print("  child4.children_len: {}\n", .{child4.children_len});
                    print("  child4.prefixes_len: {}\n", .{child4.prefixes_len});
                    print("  child4.leaf_len: {}\n", .{child4.leaf_len});
                } else {
                    print("\nNo child at octet 4\n", .{});
                }
            } else {
                print("\nNo child at octet 3\n", .{});
            }
        } else {
            print("\nNo child at octet 2\n", .{});
        }
    } else {
        print("\nNo child at octet 1\n", .{});
    }
    
    print("\nTesting get(1.2.3.4/32):\n", .{});
    const result = table.get(&prefix);
    if (result) |val| {
        print("  Result: {} (SUCCESS)\n", .{val});
    } else {
        print("  Result: null (FAILED)\n", .{});
    }
    
    print("\nAnalysis:\n", .{});
    print("For /32: max_depth=4, last_bits=0\n", .{});
    print("But octets.len=4, so the loop only goes to depth 0-3\n", .{});
    print("The get method never reaches depth=4 to check prefixes\n", .{});
} 