const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Correct ZART vs Go BART Comparison ===\n", .{});
    
    // Test case 1: Go BARTのBehaviorAnalysisと同じ条件
    print("\n=== Test Case 1: Full prefix set (like Go BART BehaviorAnalysis) ===\n", .{});
    {
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // Go BARTのBehaviorAnalysisと同じプレフィックスを挿入
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26).masked(), 4);
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked(), 1);
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked(), 2);
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 31).masked(), 7);
        
        const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
        const result = table.lookup(&addr3);
        
        print("ZART Lookup(192.168.0.3): value={}, ok={}\n", .{ result.value, result.ok });
        print("Go BART expected: value=7, ok=true\n", .{});
        
        if (result.ok and result.value == 7) {
            print("✅ MATCH: ZART matches Go BART behavior\n", .{});
        } else {
            print("❌ DIFFERENCE: ZART differs from Go BART\n", .{});
        }
    }
    
    // Test case 2: Go BARTのExactBehaviorと同じ条件（段階的）
    print("\n=== Test Case 2: Step-by-step (like Go BART ExactBehavior) ===\n", .{});
    {
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        print("Step 1: Insert only 192.168.0.1/32 -> 1\n", .{});
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked(), 1);
        
        const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
        const result1 = table.lookup(&addr3);
        print("ZART Lookup(192.168.0.3): value={}, ok={} (Go BART: value=0, ok=false)\n", .{ result1.value, result1.ok });
        
        print("\nStep 2: Add 192.168.0.2/32 -> 2\n", .{});
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked(), 2);
        
        const result2 = table.lookup(&addr3);
        print("ZART Lookup(192.168.0.3): value={}, ok={} (Go BART: value=0, ok=false)\n", .{ result2.value, result2.ok });
        
        print("\nStep 3: Add 192.168.0.0/26 -> 7\n", .{});
        table.insert(&Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 26).masked(), 7);
        
        const result3 = table.lookup(&addr3);
        print("ZART Lookup(192.168.0.3): value={}, ok={} (Go BART: value=7, ok=true)\n", .{ result3.value, result3.ok });
        
        // 最終結果の比較
        if (!result1.ok and !result2.ok and result3.ok and result3.value == 7) {
            print("✅ PERFECT MATCH: ZART exactly matches Go BART step-by-step behavior\n", .{});
        } else {
            print("❌ DIFFERENCE found in step-by-step behavior\n", .{});
            if (result1.ok) print("  - Step 1: ZART returns true, Go BART returns false\n", .{});
            if (result2.ok) print("  - Step 2: ZART returns true, Go BART returns false\n", .{});
            if (!result3.ok or result3.value != 7) print("  - Step 3: Final result differs\n", .{});
        }
    }
} 