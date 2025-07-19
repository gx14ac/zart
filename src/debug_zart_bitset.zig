const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");
const lookup_tbl = @import("lookup_tbl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== ZART Bitset Analysis ===\n", .{});
    
    // Create the same table as Go BART
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert the same prefixes as Go BART test
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const prefix1 = Prefix.init(&addr1, 32).masked();
    table.insert(&prefix1, 1);
    
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const prefix2 = Prefix.init(&addr2, 32).masked();
    table.insert(&prefix2, 2);
    
    const addr_subnet = IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    const prefix_subnet = Prefix.init(&addr_subnet, 26).masked();
    table.insert(&prefix_subnet, 7);
    
    print("\n=== Prefix to Index Mapping ===\n", .{});
    const idx1 = base_index.pfxToIdx256(1, 8);
    const idx2 = base_index.pfxToIdx256(2, 8);
    const idx_subnet = base_index.pfxToIdx256(0, 2);
    print("192.168.0.1/32 -> PfxToIdx256(1, 8) = {}\n", .{idx1});
    print("192.168.0.2/32 -> PfxToIdx256(2, 8) = {}\n", .{idx2});
    print("192.168.0.0/26 -> PfxToIdx256(0, 2) = {}\n", .{idx_subnet});
    
    print("\n=== BackTrackingBitset for octet=3 ===\n", .{});
    const host_idx3 = base_index.hostIdx(3);
    print("HostIdx(3) = {}\n", .{host_idx3});
    
    const bs259 = lookup_tbl.backTrackingBitset(host_idx3);
    print("BackTrackingBitset({}): ", .{host_idx3});
    for (0..256) |i| {
        if (bs259.isSet(@intCast(i))) {
            print("{} ", .{i});
        }
    }
    print("\n", .{});
    
    const pfx_idx3 = base_index.pfxToIdx256(3, 8);
    print("PfxToIdx256(3, 8) = {}\n", .{pfx_idx3});
    const bs129 = lookup_tbl.backTrackingBitset(pfx_idx3);
    print("BackTrackingBitset({}): ", .{pfx_idx3});
    for (0..256) |i| {
        if (bs129.isSet(@intCast(i))) {
            print("{} ", .{i});
        }
    }
    print("\n", .{});
    
    print("\n=== Expected Node Prefixes (simulated) ===\n", .{});
    print("Expected stored indices: [{}, {}, {}]\n", .{idx_subnet, idx1, idx2});
    
    print("\n=== Manual Intersection Check ===\n", .{});
    print("Checking if BackTrackingBitset({}) contains:\n", .{host_idx3});
    print("  Index {} (192.168.0.0/26): {}\n", .{idx_subnet, bs259.isSet(idx_subnet)});
    print("  Index {} (192.168.0.1/32): {}\n", .{idx1, bs259.isSet(idx1)});
    print("  Index {} (192.168.0.2/32): {}\n", .{idx2, bs259.isSet(idx2)});
    
    // Find the highest index that should be returned by IntersectionTop
    var highest_idx: ?u8 = null;
    const stored_indices = [_]u8{idx_subnet, idx1, idx2};
    for (stored_indices) |stored_idx| {
        if (bs259.isSet(stored_idx)) {
            if (highest_idx == null or stored_idx > highest_idx.?) {
                highest_idx = stored_idx;
            }
        }
    }
    
    if (highest_idx) |idx| {
        print("Expected IntersectionTop result: {}\n", .{idx});
    } else {
        print("Expected IntersectionTop result: none\n", .{});
    }
    
    print("\n=== Actual ZART Lookup Test ===\n", .{});
    const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const result = table.lookup(&addr3);
    print("ZART Lookup(192.168.0.3): value={}, ok={}\n", .{ if (result.ok) result.value else 0, result.ok });
    
    if (result.ok) {
        print("❌ ZART incorrectly returned a value for 192.168.0.3\n", .{});
    } else {
        print("✅ ZART correctly returned false for 192.168.0.3\n", .{});
    }
} 