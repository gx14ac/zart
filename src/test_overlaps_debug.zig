const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== OverlapsPrefix Debug ===\n\n", .{});
    
    // Test case that's failing: empty table with 0.0.0.0/0
    {
        print("Test 1: Empty table with 0.0.0.0/0\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        const default_route = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0).masked();
        const overlaps = table.overlapsPrefix(&default_route);
        print("  overlapsPrefix(0.0.0.0/0) = {}\n", .{overlaps});
        print("  Expected: true (default route should overlap with everything)\n", .{});
        
        // Check internal state
        print("  Table size: {}\n", .{table.size()});
        print("  root4.isEmpty(): {}\n", .{table.root4.isEmpty()});
    }
    
    // Test case 2: Table with some prefixes
    {
        print("\nTest 2: Table with prefixes\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // Insert some prefixes
        const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8).masked();
        table.insert(&prefix1, 1);
        
        const default_route = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0).masked();
        const overlaps = table.overlapsPrefix(&default_route);
        print("  Inserted: 10.0.0.0/8\n", .{});
        print("  overlapsPrefix(0.0.0.0/0) = {}\n", .{overlaps});
        print("  Expected: true\n", .{});
    }
    
    // Test case 3: Other overlapping cases
    {
        print("\nTest 3: Other overlapping cases\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // Insert 10.0.0.0/8
        const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8).masked();
        table.insert(&prefix1, 1);
        
        // Test overlaps with 10.0.0.0/16
        const prefix2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 16).masked();
        const overlaps2 = table.overlapsPrefix(&prefix2);
        print("  Inserted: 10.0.0.0/8\n", .{});
        print("  overlapsPrefix(10.0.0.0/16) = {} (Expected: true)\n", .{overlaps2});
        
        // Test overlaps with 10.1.0.0/16
        const prefix3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 1, 0, 0 } }, 16).masked();
        const overlaps3 = table.overlapsPrefix(&prefix3);
        print("  overlapsPrefix(10.1.0.0/16) = {} (Expected: true)\n", .{overlaps3});
        
        // Test overlaps with 11.0.0.0/8
        const prefix4 = Prefix.init(&IPAddr{ .v4 = .{ 11, 0, 0, 0 } }, 8).masked();
        const overlaps4 = table.overlapsPrefix(&prefix4);
        print("  overlapsPrefix(11.0.0.0/8) = {} (Expected: false)\n", .{overlaps4});
    }
} 