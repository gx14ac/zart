const std = @import("std");
const print = std.debug.print;
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

/// Helper function - equivalent to Go BART's netip.MustParseAddr
fn mpa(_: []const u8) IPAddr {
    return IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
}

/// Helper function - equivalent to Go BART's netip.MustParsePrefix
fn mpp(_: []const u8) Prefix {
    // For simplicity, just handle 192.168.0.1/32
    const addr = IPAddr{ .v4 = .{ 192, 168, 0, 1 } };
    return Prefix.init(&addr, 32).masked();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Simple DirectNode Test ===\n", .{});
    
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    print("Step 1: Insert 192.168.0.1/32 -> 1\n", .{});
    const prefix1 = mpp("192.168.0.1/32");
    table.insert(&prefix1, 1);
    
    print("Step 2: Test lookup 192.168.0.1\n", .{});
    const addr1 = mpa("192.168.0.1");
    const result1 = table.lookup(&addr1);
    print("Lookup result: ok={}, value={}\n", .{ result1.ok, if (result1.ok) result1.value else 0 });
    
    print("Step 3: Insert 192.168.0.2/32 -> 2\n", .{});
    const addr2 = IPAddr{ .v4 = .{ 192, 168, 0, 2 } };
    const prefix2 = Prefix.init(&addr2, 32).masked();
    table.insert(&prefix2, 2);
    
    print("Step 4: Test lookup 192.168.0.2\n", .{});
    const result2 = table.lookup(&addr2);
    print("Lookup result: ok={}, value={}\n", .{ result2.ok, if (result2.ok) result2.value else 0 });
    
    print("Step 5: Test lookup 192.168.0.3 (should fail)\n", .{});
    const addr3 = IPAddr{ .v4 = .{ 192, 168, 0, 3 } };
    const result3 = table.lookup(&addr3);
    print("Lookup result: ok={}, value={}\n", .{ result3.ok, if (result3.ok) result3.value else 0 });
    
    print("=== Test completed ===\n", .{});
} 