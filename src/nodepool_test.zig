const std = @import("std");
const table = @import("table.zig");
const node = @import("node.zig");
const Table = table.Table;
const Prefix = node.Prefix;
const IPAddr = node.IPAddr;

/// NodePool統計確認テスト
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("🔍 **NodePool使用状況テスト**\n", .{});
    std.debug.print("================================\n", .{});
    
    // テーブルを作成（NodePool有効）
    var tbl = Table(u32).init(allocator);
    defer tbl.deinit();
    
    // NodePool統計初期状態
    if (tbl.node_pool) |pool| {
        std.debug.print("NodePool初期状態:\n", .{});
        pool.printStats();
    } else {
        std.debug.print("❌ NodePoolが初期化されていません！\n", .{});
        return;
    }
    
    std.debug.print("\n📊 **Insert操作テスト（1000件）**\n", .{});
    
    // 1000件のプレフィックスを挿入
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const addr = IPAddr{ .v4 = .{ 
            @as(u8, @intCast((i >> 24) & 0xFF)),
            @as(u8, @intCast((i >> 16) & 0xFF)), 
            @as(u8, @intCast((i >> 8) & 0xFF)),
            @as(u8, @intCast(i & 0xFF))
        } };
        const pfx = Prefix.init(&addr, 24);
        tbl.insert(&pfx, i);
    }
    
    // NodePool統計結果表示
    if (tbl.node_pool) |pool| {
        std.debug.print("\nNodePool最終統計:\n", .{});
        pool.printStats();
        
        const total_ops = pool.pool_hits + pool.pool_misses;
        if (total_ops > 0) {
            const hit_rate = @as(f64, @floatFromInt(pool.pool_hits)) / @as(f64, @floatFromInt(total_ops)) * 100.0;
            std.debug.print("実際の効率: {d:.1}%\n", .{hit_rate});
            
            if (pool.pool_hits > 0) {
                std.debug.print("✅ NodePool使用中！ヒット数: {}\n", .{pool.pool_hits});
            } else {
                std.debug.print("⚠️ NodePoolがヒットしていません\n", .{});
            }
        }
    }
    
    std.debug.print("\nテーブルサイズ: {}\n", .{tbl.size()});
    std.debug.print("✅ NodePool統計確認完了\n", .{});
} 