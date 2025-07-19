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

    var table = Table(i32).init(allocator);
    defer table.deinit();

    print("=== Debug Octet Matching Logic ===\n", .{});
    
    // Test 1: Insert 192.168.0.1/32 -> 1
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32);
    table.insert(&pfx1, 1);
    print("Inserted: 192.168.0.1/32 -> 1\n", .{});
    
    // Test what index is used for this prefix
    const expected_idx1 = base_index.pfxToIdx256(1, 8);
    print("Expected index for 192.168.0.1/32: {}\n", .{expected_idx1});
    
    const pfx_info1 = base_index.idxToPfx256(expected_idx1) catch unreachable;
    print("Index {} represents: octet={}, pfx_len={}\n", .{ expected_idx1, pfx_info1.octet, pfx_info1.pfx_len });
    
    // Now test lookup for 192.168.0.1
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const result1 = table.lookup(&addr1);
    print("Lookup 192.168.0.1: value={}, ok={}\n", .{ result1.value, result1.ok });
    
    if (!result1.ok) {
        print("❌ BUG: 192.168.0.1 lookup failed!\n", .{});
        print("Investigating why...\n", .{});
        
        // Check what the exact octet matching does
        print("Lookup octet at depth 3: 1\n", .{});
        print("Index {} represents octet: {}\n", .{ expected_idx1, pfx_info1.octet });
        print("Octet match? {}\n", .{pfx_info1.octet == 1});
        
        if (pfx_info1.octet != 1) {
            print("❌ PROBLEM: Index represents different octet!\n", .{});
        }
    } else {
        print("✅ 192.168.0.1 lookup succeeded\n", .{});
    }
    
    print("\n=== Testing 192.168.0.2 ===\n", .{});
    
    // Test 2: Insert 192.168.0.2/32 -> 2
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32);
    table.insert(&pfx2, 2);
    print("Inserted: 192.168.0.2/32 -> 2\n", .{});
    
    const expected_idx2 = base_index.pfxToIdx256(2, 8);
    print("Expected index for 192.168.0.2/32: {}\n", .{expected_idx2});
    
    const pfx_info2 = base_index.idxToPfx256(expected_idx2) catch unreachable;
    print("Index {} represents: octet={}, pfx_len={}\n", .{ expected_idx2, pfx_info2.octet, pfx_info2.pfx_len });
    
    // Test lookup for 192.168.0.2
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const result2 = table.lookup(&addr2);
    print("Lookup 192.168.0.2: value={}, ok={}\n", .{ result2.value, result2.ok });
    
    print("\n=== Testing 192.168.0.3 (should fail) ===\n", .{});
    
    const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const result3 = table.lookup(&addr3);
    print("Lookup 192.168.0.3: value={}, ok={}\n", .{ result3.value, result3.ok });
    
    if (result3.ok) {
        print("❌ BUG: 192.168.0.3 should not match but did!\n", .{});
    } else {
        print("✅ 192.168.0.3 correctly returned false\n", .{});
    }
    
    print("\n=== Analysis ===\n", .{});
    print("The issue might be in how we're interpreting the ART algorithm.\n", .{});
    print("Let's check what Go BART actually does with idxToPfx256.\n", .{});
} 