const std = @import("std");
const print = std.debug.print;
const table_mod = @import("table.zig");
const Table = table_mod.Table;
const node = @import("node.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var table = Table(u32).init(allocator);
    defer table.deinit();

    // Test data setup - same as Go BART
    print("=== 192.168.0.3 LookupPrefixLPM Debug ===\n", .{});
    
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
    
    print("Table size: {}\n", .{table.size()});
    
    // Test case: 192.168.0.3/32
    const test_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 3 } }, 32);
    print("\n=== Testing 192.168.0.3/32 ===\n", .{});
    
    // Test regular lookup first
    const test_addr = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const lookup_result = table.lookup(&test_addr);
    print("Regular lookup 192.168.0.3: value={}, ok={}\n", .{ lookup_result.value, lookup_result.ok });
    
    // Test LookupPrefixLPM
    const lpm_result = table.lookupPrefixLPM(&test_pfx);
    print("LookupPrefixLPM 192.168.0.3/32: value={?}, ok={}\n", .{ lpm_result, lpm_result != null });
    
    // Test IPv4-specific node lookup
    const root4 = table.root4;
    const direct_lookup = root4.lookupOptimized(&test_addr);
    print("DirectNode lookup 192.168.0.3: value={}, ok={}\n", .{ direct_lookup.value, direct_lookup.ok });
    
    // Test IPv4-specific node LookupPrefixLPM
    const direct_lpm = root4.lookupPrefixLPM(&test_pfx);
    print("DirectNode LookupPrefixLPM 192.168.0.3/32: value={}, ok={}\n", .{ direct_lpm.val, direct_lpm.ok });
    
    // Test other cases for comparison
    print("\n=== Comparison with other cases ===\n", .{});
    
    const pfx_1_test = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32);
    const result_1 = table.lookupPrefixLPM(&pfx_1_test);
    print("192.168.0.1/32 LookupPrefixLPM: value={?}\n", .{result_1});
    
    const pfx_2_test = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32);
    const result_2 = table.lookupPrefixLPM(&pfx_2_test);
    print("192.168.0.2/32 LookupPrefixLPM: value={?}\n", .{result_2});
    
    const pfx_0_test = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26);
    const result_0 = table.lookupPrefixLPM(&pfx_0_test);
    print("192.168.0.0/26 LookupPrefixLPM: value={?}\n", .{result_0});
    
    print("\n=== Expected: 192.168.0.3/32 should return 7 (Go BART confirmed) ===\n", .{});
} 