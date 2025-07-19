const std = @import("std");
const print = std.debug.print;
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;
const base_index = @import("base_index.zig");
const lookup_tbl = @import("lookup_tbl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var table = Table(i32).init(allocator);
    defer table.deinit();

    print("=== ZART vs Go BART Comparison ===\n", .{});
    
    // Set up the exact same scenario (using IPAddr directly)
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32);
    
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    
    const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    
    print("Inserted 192.168.0.1/32 -> 1\n", .{});
    print("Inserted 192.168.0.2/32 -> 2\n", .{});
    print("Testing lookup for 192.168.0.3\n", .{});
    
    // Test ZART lookup result
    const zart_result = table.lookup(&addr3);
    print("ZART result: value={}, ok={}\n", .{ zart_result.value, zart_result.ok });
    
    // Now analyze the internal state step by step
    print("\n=== Internal State Analysis ===\n", .{});
    
    // Navigate to the depth 3 node
    const root4 = table.root4;
    var n = root4;
    const octets = addr3.asSlice();
    
    print("Navigating to depth 3:\n", .{});
    for (octets, 0..) |octet, depth| {
        print("  Depth {}, octet {}: ", .{ depth, octet });
        
        if (depth == 3) {
            print("FINAL DEPTH\n", .{});
            print("    prefixes_len: {}\n", .{n.prefixes_len});
            print("    stored indices: ", .{});
            
            var stored_indices = std.ArrayList(u8).init(allocator);
            defer stored_indices.deinit();
            
            for (0..256) |i| {
                if (n.prefixes_bitset.isSet(@intCast(i))) {
                    print("{} ", .{i});
                    stored_indices.append(@intCast(i)) catch unreachable;
                }
            }
            print("\n", .{});
            
            // Test backtracking bitset
            const host_idx = base_index.hostIdx(3);
            const bs = lookup_tbl.backTrackingBitset(host_idx);
            
            print("    hostIdx(3) = {}\n", .{host_idx});
            print("    backTrackingBitset contains: ", .{});
            
            var bs_indices = std.ArrayList(u8).init(allocator);
            defer bs_indices.deinit();
            
            for (0..256) |i| {
                if (bs.isSet(@intCast(i))) {
                    print("{} ", .{i});
                    bs_indices.append(@intCast(i)) catch unreachable;
                }
            }
            print("\n", .{});
            
            // Manual intersection
            print("    manual intersection: ", .{});
            var intersection = std.ArrayList(u8).init(allocator);
            defer intersection.deinit();
            
            for (stored_indices.items) |stored| {
                for (bs_indices.items) |bs_idx| {
                    if (stored == bs_idx) {
                        print("{} ", .{stored});
                        intersection.append(stored) catch unreachable;
                    }
                }
            }
            print("\n", .{});
            
            // Test ZART's intersectionTop
            if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
                print("    ZART intersectionTop: {} ✅\n", .{top_idx});
                
                const rank_idx = n.prefixes_bitset.rank(top_idx) - 1;
                const val = n.prefixes_items[rank_idx];
                print("    Would return value: {}\n", .{val});
            } else {
                print("    ZART intersectionTop: null ❌\n", .{});
            }
            
            break;
        }
        
        if (n.children_bitset.isSet(octet)) {
            print("has child\n", .{});
            const rank_idx = n.children_bitset.rank(octet) - 1;
            n = n.children_items[rank_idx];
        } else {
            print("no child\n", .{});
            break;
        }
    }
    
    print("\n=== Analysis ===\n", .{});
    print("Go BART returns: false\n", .{});
    print("ZART returns: {}\n", .{zart_result.ok});
    
    if (zart_result.ok and !false) { // Go BART returns false
        print("❌ MISMATCH: ZART finds match but Go BART doesn't\n", .{});
        print("This suggests our intersection or backtracking logic differs from Go BART\n", .{});
    } else {
        print("✅ MATCH: Both return the same result\n", .{});
    }
} 