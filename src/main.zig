const std = @import("std");
const table_mod = @import("table.zig");
const node_mod = @import("node.zig");

const Table = table_mod.Table;
const Prefix = node_mod.Prefix;
const IPAddr = node_mod.IPAddr;

/// BART-compliant main function demonstrating standard API
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🌟 **ZART - BART-Compliant Routing Table**\n", .{});
    std.debug.print("==========================================\n", .{});

    // Create table - standard BART API
    var tbl = Table(u32).init(allocator);
    defer tbl.deinit();

    // Insert IPv4 prefixes - standard BART API
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 12);
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0); // Default route
    
    tbl.insert(&pfx1, 100);
    tbl.insert(&pfx2, 200);
    tbl.insert(&pfx3, 300);
    tbl.insert(&pfx4, 500);

    // Insert IPv6 prefix - standard BART API
    const pfx6 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32);
    tbl.insert(&pfx6, 600);

    // Display table information - standard BART API
    std.debug.print("\n📊 **Table Statistics**\n", .{});
    std.debug.print("Total size: {}\n", .{tbl.size()});
    std.debug.print("IPv4 prefixes: {}\n", .{tbl.getSize4()});
    std.debug.print("IPv6 prefixes: {}\n", .{tbl.getSize6()});

    // Test Get operations - standard BART API
    std.debug.print("\n🔍 **Get Operations**\n", .{});
    std.debug.print("10.0.0.0/8: {?}\n", .{tbl.get(&pfx1)});
    std.debug.print("192.168.1.0/24: {?}\n", .{tbl.get(&pfx2)});
    std.debug.print("172.16.0.0/12: {?}\n", .{tbl.get(&pfx3)});

    // Test Lookup operations - standard BART API
    std.debug.print("\n🎯 **Lookup Operations (LPM)**\n", .{});
    const lookup_ip1 = IPAddr{ .v4 = .{ 10, 1, 2, 3 } };
    const lookup_ip2 = IPAddr{ .v4 = .{ 192, 168, 1, 100 } };
    const lookup_ip3 = IPAddr{ .v4 = .{ 8, 8, 8, 8 } };
    
    const result1 = tbl.lookup(&lookup_ip1);
    const result2 = tbl.lookup(&lookup_ip2);
    const result3 = tbl.lookup(&lookup_ip3);
    
    std.debug.print("10.1.2.3 -> {?}\n", .{if (result1.ok) result1.value else null});
    std.debug.print("192.168.1.100 -> {?}\n", .{if (result2.ok) result2.value else null});
    std.debug.print("8.8.8.8 -> {?} (default route)\n", .{if (result3.ok) result3.value else null});

    // Demonstrate insert performance with simple benchmark
    std.debug.print("\n⚡ **Insert Performance Test**\n", .{});
    try simpleInsertBenchmark(allocator);

    std.debug.print("\n✅ **BART-compliant demonstration completed successfully!**\n", .{});
    std.debug.print("📚 All operations use standard BART API only.\n", .{});
}

/// Simple insert benchmark using standard BART API only
fn simpleInsertBenchmark(allocator: std.mem.Allocator) !void {
    const test_sizes = [_]usize{ 1000, 10000, 100000 };
    
    for (test_sizes) |size| {
        std.debug.print("\n--- Testing {} prefixes ---\n", .{size});
        
        // Generate test prefixes
        var prefixes = std.ArrayList(Prefix).init(allocator);
        defer prefixes.deinit();
        
        var rng = std.Random.DefaultPrng.init(42);
        for (0..size) |i| {
            const addr = IPAddr{ .v4 = .{
                @as(u8, @truncate(i >> 16)),
                @as(u8, @truncate(i >> 8)),
                @as(u8, @truncate(i)),
                @as(u8, @truncate(rng.random().uintLessThan(u8, 255))),
            } };
            const bits = @as(u8, @intCast(16 + rng.random().uintLessThan(u8, 17))); // /16-/32
            try prefixes.append(Prefix.init(&addr, bits));
        }
        
        // Create table and benchmark inserts
        var table = Table(u32).init(allocator);
        defer table.deinit();
        
        const start_time = std.time.nanoTimestamp();
        
        for (prefixes.items, 0..) |pfx, i| {
            table.insert(&pfx, @as(u32, @intCast(i)));
        }
        
        const end_time = std.time.nanoTimestamp();
        const total_ns = end_time - start_time;
        const per_op_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(size));
        
        std.debug.print("Insert: {d:.1} ns/op\n", .{per_op_ns});
        std.debug.print("Final table size: {}\n", .{table.size()});
        
        // Go BART comparison
        if (per_op_ns <= 20.0) {
            std.debug.print("🏆 Go BARTレベル達成! ({d:.1} ns/op)\n", .{per_op_ns});
        } else if (per_op_ns <= 50.0) {
            std.debug.print("🥇 優秀な性能! ({d:.1} ns/op)\n", .{per_op_ns});
        } else if (per_op_ns <= 100.0) {
            std.debug.print("🥈 良好な性能 ({d:.1} ns/op)\n", .{per_op_ns});
        } else {
            std.debug.print("🥉 改善の余地あり ({d:.1} ns/op)\n", .{per_op_ns});
        }
    }
}
