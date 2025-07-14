const std = @import("std");
const print = std.debug.print;
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;
const base_index = @import("base_index.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var table = Table(u32).init(allocator);
    defer table.deinit();

    print("=== Insert Process Debug ===\n", .{});
    
    // Debug 192.168.0.1/32 insertion
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32);
    print("\n=== Inserting 192.168.0.1/32 ===\n", .{});
    print("Prefix: {}\n", .{pfx1});
    print("Canonical: {}\n", .{pfx1.masked()});
    
    const max_depth_info1 = base_index.maxDepthAndLastBits(32);
    print("max_depth: {}, last_bits: {}\n", .{max_depth_info1.max_depth, max_depth_info1.last_bits});
    
    const idx1 = base_index.pfxToIdx256(1, max_depth_info1.last_bits);
    print("pfxToIdx256(1, {}): {}\n", .{max_depth_info1.last_bits, idx1});
    
    print("Before insert - root4 prefixes_bitset: ", .{});
    for (0..256) |i| {
        if (table.root4.prefixes_bitset.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    table.insert(&pfx1, 1);
    
    print("After insert - root4 prefixes_bitset: ", .{});
    for (0..256) |i| {
        if (table.root4.prefixes_bitset.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    // Debug 192.168.0.2/32 insertion
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32);
    print("\n=== Inserting 192.168.0.2/32 ===\n", .{});
    print("Prefix: {}\n", .{pfx2});
    print("Canonical: {}\n", .{pfx2.masked()});
    
    const idx2 = base_index.pfxToIdx256(2, max_depth_info1.last_bits);
    print("pfxToIdx256(2, {}): {}\n", .{max_depth_info1.last_bits, idx2});
    
    table.insert(&pfx2, 2);
    
    print("After insert - root4 prefixes_bitset: ", .{});
    for (0..256) |i| {
        if (table.root4.prefixes_bitset.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    // Debug 192.168.0.0/26 insertion
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26);
    print("\n=== Inserting 192.168.0.0/26 ===\n", .{});
    print("Prefix: {}\n", .{pfx3});
    print("Canonical: {}\n", .{pfx3.masked()});
    
    const max_depth_info3 = base_index.maxDepthAndLastBits(26);
    print("max_depth: {}, last_bits: {}\n", .{max_depth_info3.max_depth, max_depth_info3.last_bits});
    
    const idx3 = base_index.pfxToIdx256(0, max_depth_info3.last_bits);
    print("pfxToIdx256(0, {}): {}\n", .{max_depth_info3.last_bits, idx3});
    
    table.insert(&pfx3, 7);
    
    print("After insert - root4 prefixes_bitset: ", .{});
    for (0..256) |i| {
        if (table.root4.prefixes_bitset.isSet(@intCast(i))) {
            print("{}, ", .{i});
        }
    }
    print("\n", .{});
    
    print("\n=== Final State ===\n", .{});
    print("Table size: {}\n", .{table.size()});
    print("Root4 prefixes_len: {}\n", .{table.root4.prefixes_len});
    print("Root4 children_len: {}\n", .{table.root4.children_len});
    print("Root4 leaf_len: {}\n", .{table.root4.leaf_len});
    print("Root4 fringe_len: {}\n", .{table.root4.fringe_len});
} 