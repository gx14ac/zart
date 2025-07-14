const std = @import("std");
const print = std.debug.print;
const testing = std.testing;
const expectEqual = testing.expectEqual;

const table_mod = @import("table.zig");
const Table = table_mod.Table;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;

test "LookupPrefixLPM - Go BART完全互換実装テスト" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var table = Table(u32).init(allocator);
    defer table.deinit();

    // Test data setup
    const ip1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const ip2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const ip3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const ip_subnet = IPAddr{ .v4 = .{ 192, 168, 0, 0 } };

    const prefix1 = Prefix.init(&ip1, 32);
    const prefix2 = Prefix.init(&ip2, 32);
    const prefix_subnet = Prefix.init(&ip_subnet, 26);

    // Insert test data
    table.insert(&prefix1, 1);
    table.insert(&prefix2, 2);
    table.insert(&prefix_subnet, 7);

    print("=== LookupPrefixLPM Test Results ===\n", .{});
    
    // Test 1: 192.168.0.1/32 -> should find exact match (value 1)
    const pfx1 = Prefix.init(&ip1, 32);
    const result1 = table.lookupPrefixLPM(&pfx1);
    print("192.168.0.1/32 -> value: {?}, ok: {}\n", .{ result1, result1 != null });
    
    // Test 2: 192.168.0.2/32 -> should find exact match (value 2)
    const pfx2 = Prefix.init(&ip2, 32);
    const result2 = table.lookupPrefixLPM(&pfx2);
    print("192.168.0.2/32 -> value: {?}, ok: {}\n", .{ result2, result2 != null });
    
    // Test 3: 192.168.0.3/32 -> should find subnet match (value 7)
    const pfx3 = Prefix.init(&ip3, 32);
    const result3 = table.lookupPrefixLPM(&pfx3);
    print("192.168.0.3/32 -> value: {?}, ok: {}\n", .{ result3, result3 != null });
    
    // Test 4: 192.168.0.0/26 -> should find exact match (value 7)
    const result4 = table.lookupPrefixLPM(&prefix_subnet);
    print("192.168.0.0/26 -> value: {?}, ok: {}\n", .{ result4, result4 != null });
    
    // Verify results
    try expectEqual(@as(?u32, 1), result1);
    try expectEqual(true, result1 != null);
    
    try expectEqual(@as(?u32, 2), result2);
    try expectEqual(true, result2 != null);
    
    try expectEqual(@as(?u32, 7), result3);
    try expectEqual(true, result3 != null);
    
    try expectEqual(@as(?u32, 7), result4);
    try expectEqual(true, result4 != null);
    
    print("=== All Tests Passed! ===\n", .{});
} 