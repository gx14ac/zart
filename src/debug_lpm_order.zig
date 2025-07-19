const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const base_index = @import("base_index.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== LPM Order Investigation ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Step 1: Insert 192.168.0.1/32
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const prefix1 = Prefix.init(&addr1, 32).masked();
    table.insert(&prefix1, 1);
    print("\nStep 1: Inserted 192.168.0.1/32 -> 1\n", .{});
    
    // Step 2: Insert 192.168.0.2/32
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const prefix2 = Prefix.init(&addr2, 32).masked();
    table.insert(&prefix2, 2);
    print("Step 2: Inserted 192.168.0.2/32 -> 2\n", .{});
    
    // Test lookup before /26 insertion
    const test_addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const result_before = table.lookup(&test_addr3);
    print("\nBefore /26: Lookup 192.168.0.3 = value:{}, ok:{}\n", .{ 
        if (result_before.ok) result_before.value else 0, result_before.ok 
    });
    
    // Step 3: Insert 192.168.0.0/26
    const addr_subnet = IPAddr{ .v4 = .{ 192, 168, 0, 0 } };
    const prefix_subnet = Prefix.init(&addr_subnet, 26).masked();
    print("\nStep 3: Inserting 192.168.0.0/26 -> 7\n", .{});
    
    // Calculate index for /26
    const idx_26 = base_index.pfxToIdx256(0, 2); // octet=0, pfxLen=2 (26 % 8 = 2)
    print("  /26 will be stored at index: {}\n", .{idx_26});
    
    table.insert(&prefix_subnet, 7);
    
    // Test all lookups after /26 insertion
    print("\nAfter /26 insertion:\n", .{});
    
    for (0..5) |i| {
        const test_addr = IPAddr{ .v4 = .{ 192, 168, 0, @intCast(i) } };
        const lookup_result = table.lookup(&test_addr);
        print("  Lookup 192.168.0.{}: value={}, ok={}\n", .{ 
            i, 
            if (lookup_result.ok) lookup_result.value else 0, 
            lookup_result.ok 
        });
    }
    
    // Analyze the problem
    print("\n=== Analysis ===\n", .{});
    print("Expected: 192.168.0.3 should return 7 (from /26)\n", .{});
    const result_after = table.lookup(&test_addr3);
    print("Actual: 192.168.0.3 returns {}\n", .{
        if (result_after.ok) result_after.value else 0
    });
    
    // Check what indices are involved
    print("\nIndex analysis:\n", .{});
    print("  192.168.0.1/32 -> index {}\n", .{base_index.pfxToIdx256(1, 8)});
    print("  192.168.0.2/32 -> index {}\n", .{base_index.pfxToIdx256(2, 8)});
    print("  192.168.0.0/26 -> index {}\n", .{base_index.pfxToIdx256(0, 2)});
    
    // The key question
    print("\nKey question: Why doesn't /26 match for 192.168.0.3?\n", .{});
    print("Possible reasons:\n", .{});
    print("1. /26 is stored as leafNode (due to maxDepth issue)\n", .{});
    print("2. LPM backtracking doesn't check the right indices\n", .{});
    print("3. /26 is not being inserted at the correct depth\n", .{});
} 