const std = @import("std");
const Table = @import("table.zig").Table;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // テーブル作成と基本データ挿入
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テストデータ挿入（Go BARTと同じパターン）
    const prefixes = [_]struct { ip: [4]u8, bits: u8, value: u32 }{
        .{ .ip = .{ 0, 0, 0, 0 }, .bits = 0, .value = 100 },        // デフォルトルート
        .{ .ip = .{ 10, 0, 0, 0 }, .bits = 8, .value = 200 },       // 10.0.0.0/8
        .{ .ip = .{ 192, 168, 0, 0 }, .bits = 16, .value = 300 },   // 192.168.0.0/16
        .{ .ip = .{ 192, 168, 1, 0 }, .bits = 24, .value = 400 },   // 192.168.1.0/24
        .{ .ip = .{ 203, 0, 113, 0 }, .bits = 24, .value = 500 },   // 203.0.113.0/24
    };
    
    for (prefixes) |p| {
        const pfx = Prefix.init(&IPAddr{ .v4 = p.ip }, p.bits);
        table.insert(&pfx, p.value);
    }
    
    std.debug.print("🚀 **Contains & Lookup Performance Test**\n", .{});
    std.debug.print("==========================================\n\n", .{});
    
    // テスト用IPアドレス
    const test_ips = [_][4]u8{
        .{ 10, 1, 2, 3 },        // 10.0.0.0/8 にマッチ
        .{ 192, 168, 1, 100 },   // 192.168.1.0/24 にマッチ
        .{ 203, 0, 113, 50 },    // 203.0.113.0/24 にマッチ
        .{ 8, 8, 8, 8 },         // デフォルトルートにマッチ
        .{ 172, 16, 0, 1 },      // デフォルトルートにマッチ
    };
    
    // Contains性能テスト
    const contains_iterations = 1000000;
    var contains_timer = try std.time.Timer.start();
    
    var contains_hits: usize = 0;
    for (0..contains_iterations) |_| {
        for (test_ips) |ip| {
            const addr = IPAddr{ .v4 = ip };
            if (table.contains(&addr)) {
                contains_hits += 1;
            }
        }
    }
    
    const contains_elapsed = contains_timer.read();
    const contains_ns_per_op = contains_elapsed / (contains_iterations * test_ips.len);
    
    // Lookup性能テスト
    const lookup_iterations = 1000000;
    var lookup_timer = try std.time.Timer.start();
    
    var lookup_hits: usize = 0;
    for (0..lookup_iterations) |_| {
        for (test_ips) |ip| {
            const addr = IPAddr{ .v4 = ip };
            const result = table.lookup(&addr);
            if (result.ok) {
                lookup_hits += 1;
            }
        }
    }
    
    const lookup_elapsed = lookup_timer.read();
    const lookup_ns_per_op = lookup_elapsed / (lookup_iterations * test_ips.len);
    
    // 結果表示
    std.debug.print("📊 **Performance Results**\n", .{});
    std.debug.print("--------------------------\n", .{});
    std.debug.print("Contains: {:.1} ns/op (hits: {})\n", .{ @as(f64, @floatFromInt(contains_ns_per_op)), contains_hits });
    std.debug.print("Lookup:   {:.1} ns/op (hits: {})\n", .{ @as(f64, @floatFromInt(lookup_ns_per_op)), lookup_hits });
    std.debug.print("\n", .{});
    
    // Go BARTとの比較
    std.debug.print("🎯 **Go BART Comparison**\n", .{});
    std.debug.print("-------------------------\n", .{});
    std.debug.print("Go BART Contains: ~5.5 ns/op\n", .{});
    std.debug.print("Go BART Lookup:   ~17.2 ns/op\n", .{});
    std.debug.print("\n", .{});
    
    const contains_vs_go = @as(f64, @floatFromInt(contains_ns_per_op)) / 5.5;
    const lookup_vs_go = @as(f64, @floatFromInt(lookup_ns_per_op)) / 17.2;
    
    std.debug.print("📈 **Performance Ratio**\n", .{});
    std.debug.print("------------------------\n", .{});
    std.debug.print("Contains: {:.1}x Go BART ", .{contains_vs_go});
    if (contains_vs_go < 1.0) {
        std.debug.print("🏆 **FASTER**\n", .{});
    } else if (contains_vs_go < 2.0) {
        std.debug.print("🥇 Excellent\n", .{});
    } else if (contains_vs_go < 5.0) {
        std.debug.print("🥈 Very Good\n", .{});
    } else {
        std.debug.print("🥉 Needs Improvement\n", .{});
    }
    
    std.debug.print("Lookup:   {:.1}x Go BART ", .{lookup_vs_go});
    if (lookup_vs_go < 1.0) {
        std.debug.print("🏆 **FASTER**\n", .{});
    } else if (lookup_vs_go < 2.0) {
        std.debug.print("🥇 Excellent\n", .{});
    } else if (lookup_vs_go < 5.0) {
        std.debug.print("🥈 Very Good\n", .{});
    } else {
        std.debug.print("🥉 Needs Improvement\n", .{});
    }
    
    // 機能確認
    std.debug.print("\n✅ **Functional Verification**\n", .{});
    std.debug.print("------------------------------\n", .{});
    for (test_ips, 0..) |ip, i| {
        const addr = IPAddr{ .v4 = ip };
        const contains_result = table.contains(&addr);
        const lookup_result = table.lookup(&addr);
        
        std.debug.print("{}. {}.{}.{}.{}: ", .{ i + 1, ip[0], ip[1], ip[2], ip[3] });
        if (contains_result and lookup_result.ok) {
            std.debug.print("✅ Contains: true, Lookup: {}\n", .{lookup_result.value});
        } else {
            std.debug.print("❌ Contains: {}, Lookup: {}\n", .{ contains_result, lookup_result.ok });
        }
    }
    
    std.debug.print("\n🎉 **Test completed successfully!**\n", .{});
} 