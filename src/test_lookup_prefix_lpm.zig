const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== LookupPrefixLPM Test ===\n\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert test data (same as Go BART test)
    const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked();
    const prefix2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked();
    const prefix3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26).masked();
    
    table.insert(&prefix1, 1);
    table.insert(&prefix2, 2);
    table.insert(&prefix3, 7);
    
    print("Inserted:\n", .{});
    print("  192.168.0.1/32 -> 1\n", .{});
    print("  192.168.0.2/32 -> 2\n", .{});
    print("  192.168.0.0/26 -> 7\n", .{});
    
    // Test lookupPrefixLPM
    print("\nTesting lookupPrefixLPM:\n", .{});
    
    // Test 1: Exact match
    const test1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked();
    const result1 = table.lookupPrefixLPM(&test1);
    print("  192.168.0.1/32: val={?}\n", .{result1});
    
    // Test 2: Exact match
    const test2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked();
    const result2 = table.lookupPrefixLPM(&test2);
    print("  192.168.0.2/32: val={?}\n", .{result2});
    
    // Test 3: Should match /26
    const test3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 3 } }, 32).masked();
    const result3 = table.lookupPrefixLPM(&test3);
    print("  192.168.0.3/32: val={?}\n", .{result3});
    
    // Test 4: Exact match /26
    const test4 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26).masked();
    const result4 = table.lookupPrefixLPM(&test4);
    print("  192.168.0.0/26: val={?}\n", .{result4});
    
    // Test 5: No match
    const test5 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 32).masked();
    const result5 = table.lookupPrefixLPM(&test5);
    print("  10.0.0.0/32: val={?}\n", .{result5});
    
    // Test regular lookup
    print("\nTesting regular lookup:\n", .{});
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    
    const lookup1 = table.lookup(&addr1);
    const lookup2 = table.lookup(&addr2);
    const lookup3 = table.lookup(&addr3);
    
    print("  lookup(192.168.0.1): {?}\n", .{lookup1});
    print("  lookup(192.168.0.2): {?}\n", .{lookup2});
    print("  lookup(192.168.0.3): {?}\n", .{lookup3});
} 