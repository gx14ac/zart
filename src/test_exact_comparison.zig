const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== ZART vs Go BART Exact Behavior Comparison ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // Replicate Go BART's exact test case
    print("Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked();
    table.insert(&prefix1, 1);
    
    // Test lookup after first insert
    const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const result1 = table.lookup(&addr3);
    print("After first insert - Lookup(192.168.0.3): value={}, ok={}\n", .{ result1.value, result1.ok });
    
    print("\nStep 2: Insert 192.168.0.2/32 -> 2\n", .{});
    const prefix2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked();
    table.insert(&prefix2, 2);
    
    // Test lookup after second insert - THIS IS WHERE THE DIFFERENCE SHOULD BE
    const result2 = table.lookup(&addr3);
    print("After second insert - Lookup(192.168.0.3): value={}, ok={} (Go BART: value=0, ok=false)\n", .{ result2.value, result2.ok });
    
    print("\nStep 3: Insert 192.168.0.0/26 -> 7\n", .{});
    const prefix_subnet = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26).masked();
    table.insert(&prefix_subnet, 7);
    
    // Test lookup after third insert
    const result3 = table.lookup(&addr3);
    print("After third insert - Lookup(192.168.0.3): value={}, ok={} (Go BART: value=7, ok=true)\n", .{ result3.value, result3.ok });
    
    // Test individual lookups
    print("\n=== Individual Lookup Tests ===\n", .{});
    const addr1 = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    
    const result_1 = table.lookup(&addr1);
    const result_2 = table.lookup(&addr2);
    const result_3 = table.lookup(&addr3);
    
    print("ZART Lookup(192.168.0.1): value={}, ok={} (Go BART: value=1, ok=true)\n", .{ result_1.value, result_1.ok });
    print("ZART Lookup(192.168.0.2): value={}, ok={} (Go BART: value=2, ok=true)\n", .{ result_2.value, result_2.ok });
    print("ZART Lookup(192.168.0.3): value={}, ok={} (Go BART: value=0, ok=false)\n", .{ result_3.value, result_3.ok });
    
    // Comparison summary
    print("\n=== COMPARISON SUMMARY ===\n", .{});
    const is_1_correct = result_1.ok and result_1.value == 1;
    const is_2_correct = result_2.ok and result_2.value == 2;
    const is_3_correct = !result_3.ok;  // Go BART returns false for 192.168.0.3
    
    print("192.168.0.1: {} (expected: true)\n", .{is_1_correct});
    print("192.168.0.2: {} (expected: true)\n", .{is_2_correct});
    print("192.168.0.3: {} (expected: true for Go BART compatibility)\n", .{is_3_correct});
    
    if (is_1_correct and is_2_correct and is_3_correct) {
        print("✅ ZART is FULLY compatible with Go BART!\n", .{});
    } else {
        print("❌ ZART has differences from Go BART:\n", .{});
        if (!is_1_correct) print("  - 192.168.0.1 lookup differs\n", .{});
        if (!is_2_correct) print("  - 192.168.0.2 lookup differs\n", .{});
        if (!is_3_correct) print("  - 192.168.0.3 lookup differs (ZART returns true, Go BART returns false)\n", .{});
    }
} 