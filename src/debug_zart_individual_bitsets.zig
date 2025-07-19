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

    print("=== ZART Individual BackTrackingBitsets Analysis ===\n", .{});
    
    // Create the same table as Go BART test
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Insert the same prefixes
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const prefix1 = Prefix.init(&addr1, 32).masked();
    table.insert(&prefix1, 1);
    
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const prefix2 = Prefix.init(&addr2, 32).masked();
    table.insert(&prefix2, 2);
    
    print("Inserted prefixes:\n", .{});
    print("  192.168.0.1/32 -> index {}\n", .{base_index.pfxToIdx256(1, 8)});
    print("  192.168.0.2/32 -> index {}\n", .{base_index.pfxToIdx256(2, 8)});
    
    print("\n=== BackTrackingBitset Analysis for Each IP ===\n", .{});
    
    // Test IPs 0-5 in the 192.168.0.x range
    for (0..6) |i| {
        print("\n--- IP: 192.168.0.{} ---\n", .{i});
        
        // Calculate HostIdx
        const host_idx = base_index.hostIdx(@intCast(i));
        print("HostIdx({}) = {}\n", .{ i, host_idx });
        
        // Get BackTrackingBitset
        const bs = lookup_tbl.backTrackingBitset(host_idx);
        print("BackTrackingBitset({}) contains: ", .{host_idx});
        for (0..256) |j| {
            if (bs.isSet(@intCast(j))) {
                print("{} ", .{j});
            }
        }
        print("\n", .{});
        
        // Check which of our stored indices are contained
        print("Contains index 128 (192.168.0.1/32): {}\n", .{bs.isSet(128)});
        print("Contains index 129 (192.168.0.2/32): {}\n", .{bs.isSet(129)});
        
        // Perform actual lookup
        const test_addr = IPAddr{ .v4 = .{ 192, 168, 0, @intCast(i) } };
        const result = table.lookup(&test_addr);
        print("Actual lookup result: value={}, ok={}\n", .{ if (result.ok) result.value else 0, result.ok });
        
        // Analyze what IntersectionTop should return
        print("Expected intersection with [128, 129]: ", .{});
        var intersection = std.ArrayList(u8).init(allocator);
        defer intersection.deinit();
        
        if (bs.isSet(128)) {
            try intersection.append(128);
            print("128 ", .{});
        }
        if (bs.isSet(129)) {
            try intersection.append(129);
            print("129 ", .{});
        }
        print("\n", .{});
        
        if (intersection.items.len > 0) {
            const highest = intersection.items[intersection.items.len - 1];
            print("Expected IntersectionTop result: {}\n", .{highest});
            
            // Predict what the lookup should return
            if (highest == 128) {
                print("Should return: value=1, ok=true\n", .{});
            } else if (highest == 129) {
                print("Should return: value=2, ok=true\n", .{});
            }
        } else {
            print("Expected IntersectionTop result: none\n", .{});
            print("Should return: value=0, ok=false\n", .{});
        }
        
        // Compare prediction with actual result
        if (intersection.items.len > 0) {
            const highest = intersection.items[intersection.items.len - 1];
            const expected_value: i32 = if (highest == 128) 1 else if (highest == 129) 2 else 0;
            
            if (result.ok and result.value == expected_value) {
                print("✅ Prediction matches actual result\n", .{});
            } else {
                print("❌ Prediction MISMATCH: expected value={},ok=true, got value={},ok={}\n", 
                    .{ expected_value, if (result.ok) result.value else 0, result.ok });
            }
        } else {
            if (!result.ok) {
                print("✅ Prediction matches actual result\n", .{});
            } else {
                print("❌ Prediction MISMATCH: expected ok=false, got value={},ok={}\n", 
                    .{ result.value, result.ok });
            }
        }
    }
    
    print("\n=== Summary ===\n", .{});
    print("This analysis should reveal:\n", .{});
    print("1. Whether ZART's BackTrackingBitsets match Go BART's\n", .{});
    print("2. Whether ZART's actual results match Go BART's\n", .{});
    print("3. Where the differences lie\n", .{});
} 