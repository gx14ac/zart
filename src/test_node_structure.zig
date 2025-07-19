const std = @import("std");
const print = std.debug.print;
const testing = std.testing;

const table_mod = @import("table.zig");
const Table = table_mod.Table;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;

test "Node Structure Analysis" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var table = Table(u32).init(allocator);
    defer table.deinit();

    // Insert test data
    const ip1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const ip2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const ip_subnet = IPAddr{ .v4 = .{ 192, 168, 0, 0 } };

    const prefix1 = Prefix.init(&ip1, 32);
    const prefix2 = Prefix.init(&ip2, 32);
    const prefix_subnet = Prefix.init(&ip_subnet, 26);

    table.insert(&prefix1, 1);
    table.insert(&prefix2, 2);
    table.insert(&prefix_subnet, 7);

    print("=== ZART Node Structure Analysis ===\n", .{});
    
    // Analyze the root4 node structure
    const root4 = table.root4;
    print("Root4 node - prefixes_len: {}\n", .{root4.prefixes_len});
    
    // Follow the path 192.168.0.x to see where prefixes are stored
    print("\n=== Traversing path 192.168.0.x ===\n", .{});
    
    var current_node = root4;
    const octets = [_]u8{ 192, 168, 0 };
    
    for (octets, 0..) |octet, depth| {
        print("Depth {}: octet={}, prefixes_len={}\n", .{ depth, octet, current_node.prefixes_len });
        
        if (current_node.prefixes_len > 0) {
            print("  Prefixes at this depth:\n", .{});
            // Show prefixes bitset
            var bs_buf: [256]u8 = undefined;
            const bs_slice = current_node.prefixes_bitset.asSlice(&bs_buf);
            print("  prefixes_bitset indices: [", .{});
            for (bs_slice, 0..) |bit_idx, i| {
                if (i > 0) print(", ", .{});
                print("{}", .{bit_idx});
            }
            print("]\n", .{});
            
            // Show actual values
            for (0..current_node.prefixes_len) |i| {
                print("  prefix[{}] = value {}\n", .{ i, current_node.prefixes_items[i] });
            }
        }
        
        // Follow the path
        if (current_node.children_bitset.isSet(octet)) {
            const rank_idx = current_node.fastChildrenRank(octet) - 1;
            current_node = current_node.children_items[rank_idx];
        } else {
            print("  No child for octet {}\n", .{octet});
            break;
        }
    }
    
    // Final node analysis (depth 3)
    print("\nDepth 3 final node analysis:\n", .{});
    print("prefixes_len: {}\n", .{current_node.prefixes_len});
    
    if (current_node.prefixes_len > 0) {
        var bs_buf: [256]u8 = undefined;
        const bs_slice = current_node.prefixes_bitset.asSlice(&bs_buf);
        print("prefixes_bitset indices: [", .{});
        for (bs_slice, 0..) |bit_idx, i| {
            if (i > 0) print(", ", .{});
            print("{}", .{bit_idx});
        }
        print("]\n", .{});
        
        for (0..current_node.prefixes_len) |i| {
            print("prefix[{}] = value {}\n", .{ i, current_node.prefixes_items[i] });
        }
    }
    
    print("\n=== Test Complete ===\n", .{});
} 