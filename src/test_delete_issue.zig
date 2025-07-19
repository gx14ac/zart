const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Delete Issue Debug ===\n\n", .{});
    
    // Test case from testGetAndDelete
    {
        print("Test: Simple insert and delete\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // Insert some prefixes
        const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 24).masked();
        const prefix2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 1, 0 } }, 24).masked();
        const prefix3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 2, 0 } }, 24).masked();
        
        print("  Inserting 10.0.0.0/24 -> 100\n", .{});
        table.insert(&prefix1, 100);
        
        print("  Inserting 10.0.1.0/24 -> 101\n", .{});
        table.insert(&prefix2, 101);
        
        print("  Inserting 10.0.2.0/24 -> 102\n", .{});
        table.insert(&prefix3, 102);
        
        print("  Table size: {}\n", .{table.size()});
        
        // Delete one prefix
        print("\n  Deleting 10.0.1.0/24\n", .{});
        const deleted = table.delete(&prefix2);
        print("  Deleted value: {?}\n", .{deleted});
        print("  Table size after delete: {}\n", .{table.size()});
        
        // Verify remaining prefixes
        const get1 = table.get(&prefix1);
        const get2 = table.get(&prefix2);
        const get3 = table.get(&prefix3);
        
        print("\n  Remaining prefixes:\n", .{});
        print("    10.0.0.0/24: {?}\n", .{get1});
        print("    10.0.1.0/24: {?} (should be null)\n", .{get2});
        print("    10.0.2.0/24: {?}\n", .{get3});
        
        print("\n  Test completed successfully\n", .{});
    }
    
    // Test case with intermediate nodes
    {
        print("\n\nTest: Delete with intermediate nodes\n", .{});
        var table = Table(i32).init(allocator);
        defer table.deinit();
        
        // Create a structure with intermediate nodes
        const prefix1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 24).masked();
        const prefix2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 1 } }, 32).masked();
        const prefix3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 2 } }, 32).masked();
        
        table.insert(&prefix1, 1);
        table.insert(&prefix2, 2);
        table.insert(&prefix3, 3);
        
        print("  Initial size: {}\n", .{table.size()});
        
        // Delete /32 prefixes
        print("  Deleting 192.168.0.1/32\n", .{});
        _ = table.delete(&prefix2);
        
        print("  Deleting 192.168.0.2/32\n", .{});
        _ = table.delete(&prefix3);
        
        print("  Final size: {}\n", .{table.size()});
        
        // Verify /24 is still there
        const get1 = table.get(&prefix1);
        print("  192.168.0.0/24: {?}\n", .{get1});
        
        print("\n  Test completed successfully\n", .{});
    }
} 