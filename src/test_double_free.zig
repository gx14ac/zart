const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Double Free Test ===\n\n", .{});
    
    // Test 1: Simple insert and delete
    {
        print("Test 1: Simple insert and delete\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        const prefix = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 24).masked();
        table.insert(&prefix, 100);
        
        _ = table.delete(&prefix);
        print("  Success: No double free\n", .{});
    }
    
    // Test 2: Multiple inserts and deletes
    {
        print("\nTest 2: Multiple inserts and deletes\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // Insert multiple prefixes
        for (0..10) |i| {
            const addr = IPAddr{ .v4 = .{ 10, 0, 0, @intCast(i) } };
            const prefix = Prefix.init(&addr, 32).masked();
            table.insert(&prefix, @intCast(i));
        }
        
        // Delete them
        for (0..10) |i| {
            const addr = IPAddr{ .v4 = .{ 10, 0, 0, @intCast(i) } };
            const prefix = Prefix.init(&addr, 32).masked();
            _ = table.delete(&prefix);
        }
        
        print("  Success: No double free\n", .{});
    }
    
    // Test 3: Insert with intermediate nodes
    {
        print("\nTest 3: Insert with intermediate nodes\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // This will create intermediate nodes
        const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked();
        const prefix2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 1 } }, 32).masked();
        
        table.insert(&prefix1, 1);
        table.insert(&prefix2, 2);
        
        print("  Success: No double free\n", .{});
    }
} 