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

    var table = Table(u32).init(allocator);
    defer table.deinit();

    // Test data setup
    print("=== Detailed Lookup Debug ===\n", .{});
    
    // Insert test data
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26);
    
    print("Inserting: 192.168.0.1/32 -> 1\n", .{});
    table.insert(&pfx1, 1);
    print("Inserting: 192.168.0.2/32 -> 2\n", .{});
    table.insert(&pfx2, 2);
    print("Inserting: 192.168.0.0/26 -> 7\n", .{});
    table.insert(&pfx3, 7);
    
    // Test case: 192.168.0.3
    const test_addr = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    print("\n=== Testing 192.168.0.3 ===\n", .{});
    
    // Check backtracking bitset for hostIdx(3)
    const host_idx_3 = base_index.hostIdx(3);
    print("hostIdx(3) = {}\n", .{host_idx_3});
    
    const bs = lookup_tbl.backTrackingBitset(host_idx_3);
    print("backTrackingBitset({}): ", .{host_idx_3});
    for (0..256) |i| {
        if (bs.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    // Check what's in the root node's prefixes_bitset
    const root4 = table.root4;
    print("root4 prefixes_bitset: ", .{});
    for (0..256) |i| {
        if (root4.prefixes_bitset.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    // Check intersection
    const intersection_bs = root4.prefixes_bitset.intersection(&bs);
    print("intersection result: ", .{});
    for (0..256) |i| {
        if (intersection_bs.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    // Check each prefix index individually
    print("\n=== Checking individual prefixes ===\n", .{});
    for (0..256) |i| {
        if (root4.prefixes_bitset.isSet(@intCast(i))) {
            const idx = @as(u8, @intCast(i));
            const pfx_info = base_index.idxToPfx256(idx) catch continue;
            const result_bits = @as(u8, @intCast(0 * 8 + pfx_info.pfx_len));
            var result_addr = test_addr;
            result_addr = result_addr.masked(result_bits);
            const result_prefix = Prefix.init(&result_addr, result_bits);
            
            print("Index {}: octet={}, pfx_len={}, result_bits={}, result_addr={}, contains={}\n", .{
                idx, pfx_info.octet, pfx_info.pfx_len, result_bits, result_addr, result_prefix.containsAddr(test_addr)
            });
        }
    }
} 