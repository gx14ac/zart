const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");
const DirectNode = @import("direct_node.zig").DirectNode;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Detailed Get Method Debug ===\n\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // First, let's test with a simple /24 prefix
    const addr24 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const prefix24 = Prefix.init(&addr24, 24).masked();
    print("Test 1: Inserting 10.0.0.0/24 -> 999\n", .{});
    table.insert(&prefix24, 999);
    
    const result24 = table.get(&prefix24);
    if (result24) |val| {
        print("  get(10.0.0.0/24): {} (SUCCESS)\n", .{val});
    } else {
        print("  get(10.0.0.0/24): null (FAILED)\n", .{});
    }
    
    // Check the internal structure
    print("\nChecking internal structure:\n", .{});
    print("  Table size (IPv4): {}\n", .{table.size4});
    
    // Now test with /32
    const addr32 = IPAddr{ .v4 = .{ 1, 2, 3, 4 } };
    const prefix32 = Prefix.init(&addr32, 32).masked();
    print("\nTest 2: Inserting 1.2.3.4/32 -> 1234\n", .{});
    table.insert(&prefix32, 1234);
    
    print("  Table size (IPv4): {}\n", .{table.size4});
    
    const result32 = table.get(&prefix32);
    if (result32) |val| {
        print("  get(1.2.3.4/32): {} (SUCCESS)\n", .{val});
    } else {
        print("  get(1.2.3.4/32): null (FAILED)\n", .{});
    }
    
    // Let's also check the root node
    print("\nDebug info:\n", .{});
    print("  root4 exists (not optional in ZART)\n", .{});
    
    // Try calling get directly on the root
    const direct_result = table.root4.get(&prefix24);
    if (direct_result) |val| {
        print("  Direct root.get(10.0.0.0/24): {} (SUCCESS)\n", .{val});
    } else {
        print("  Direct root.get(10.0.0.0/24): null (FAILED)\n", .{});
    }
} 