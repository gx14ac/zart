const std = @import("std");
const Table = @import("table.zig").Table;
const IPAddr = @import("node.zig").IPAddr;
const Prefix = @import("node.zig").Prefix;

// 確実に動作する小規模ベンチマーク
pub fn microBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("\n🔬 **MICRO BENCHMARK - Zig vs Go 直接対決**\n", .{});
    std.debug.print("================================================================\n", .{});
    
    // 小規模で確実なテスト
    const test_sizes = [_]usize{ 100, 1000 };
    
    for (test_sizes) |size| {
        std.debug.print("\n--- テーブルサイズ: {} ---\n", .{size});
        
        // テスト用プレフィックス生成（安定版）
        var prefixes = std.ArrayList(Prefix).init(allocator);
        defer prefixes.deinit();
        
        var rng = std.Random.DefaultPrng.init(12345); // 固定シード
        for (0..size) |i| {
            const ip_bytes: [4]u8 = .{
                @as(u8, @truncate((i >> 24) & 0xFF)),
                @as(u8, @truncate((i >> 16) & 0xFF)), 
                @as(u8, @truncate((i >> 8) & 0xFF)),
                @as(u8, @truncate(i & 0xFF))
            };
            const addr = IPAddr{ .v4 = ip_bytes };
            const bits: u8 = @as(u8, @intCast(8 + rng.random().uintLessThan(u8, 17))); // /8-/24
            const pfx = Prefix.init(&addr, bits);
            try prefixes.append(pfx);
        }
        
        // テーブル構築
        var table = Table(u32).init(allocator);
        defer table.deinit();
        
        // Insert ベンチマーク
        const insert_start = std.time.nanoTimestamp();
        for (prefixes.items, 0..) |pfx, i| {
            table.insert(&pfx, @as(u32, @intCast(i)));
        }
        const insert_end = std.time.nanoTimestamp();
        const insert_total_ns = insert_end - insert_start;
        const insert_per_op = @as(f64, @floatFromInt(insert_total_ns)) / @as(f64, @floatFromInt(size));
        
        std.debug.print("Insert: {d:.1} ns/op ({} operations)\n", .{ insert_per_op, size });
        
        // Lookup ベンチマーク
        const lookup_iterations = 10000;
        const probe_addr = &prefixes.items[0].addr;
        
        const lookup_start = std.time.nanoTimestamp();
        var dummy_sink: bool = false;
        for (0..lookup_iterations) |_| {
            const result = table.lookup(probe_addr);
            dummy_sink = result.ok;
        }
        const lookup_end = std.time.nanoTimestamp();
        std.mem.doNotOptimizeAway(dummy_sink);
        
        const lookup_total_ns = lookup_end - lookup_start;
        const lookup_per_op = @as(f64, @floatFromInt(lookup_total_ns)) / @as(f64, @floatFromInt(lookup_iterations));
        
        std.debug.print("Lookup: {d:.1} ns/op ({} iterations)\n", .{ lookup_per_op, lookup_iterations });
        
        // Get ベンチマーク
        const get_iterations = 10000;
        const probe_pfx = &prefixes.items[0];
        
        const get_start = std.time.nanoTimestamp();
        var dummy_sink2: bool = false;
        for (0..get_iterations) |_| {
            const result = table.get(probe_pfx);
            dummy_sink2 = (result != null);
        }
        const get_end = std.time.nanoTimestamp();
        std.mem.doNotOptimizeAway(dummy_sink2);
        
        const get_total_ns = get_end - get_start;
        const get_per_op = @as(f64, @floatFromInt(get_total_ns)) / @as(f64, @floatFromInt(get_iterations));
        
        std.debug.print("Get: {d:.1} ns/op ({} iterations)\n", .{ get_per_op, get_iterations });
        
        std.debug.print("Table final size: {}\n", .{table.size()});
    }
    
    std.debug.print("\n📊 **Go実装との比較**\n", .{});
    std.debug.print("Go Insert (10K): ~10 ns/op\n", .{});
    std.debug.print("Go Lookup (10K): ~11.6 ns/op\n", .{});
    std.debug.print("Go Prefix (10K): ~13.7 ns/op\n", .{});
    
    std.debug.print("\n🎯 **結論**\n", .{});
    std.debug.print("上記の結果と比較して性能差を評価してください。\n", .{});
    std.debug.print("現在の実装は開発途上であり、最適化の余地があります。\n", .{});
}

test "micro benchmark" {
    const allocator = std.testing.allocator;
    try microBenchmark(allocator);
} 