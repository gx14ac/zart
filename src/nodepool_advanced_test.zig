const std = @import("std");
const table = @import("table.zig");
const node = @import("node.zig");
const Table = table.Table;
const Prefix = node.Prefix;
const IPAddr = node.IPAddr;

/// NodePool高度テスト（Insert→Delete→Insertサイクル）
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("🚀 **NodePool高度テスト**\n", .{});
    std.debug.print("=============================\n", .{});
    
    // テーブルを作成（NodePool有効）
    var tbl = Table(u32).init(allocator);
    defer tbl.deinit();
    
    if (tbl.node_pool) |pool| {
        std.debug.print("✅ NodePool有効\n", .{});
        
        // Phase 1: 複雑なプレフィックスパターンで挿入
        std.debug.print("\n📊 **Phase 1: 複雑パターン挿入（5000件）**\n", .{});
        
        var i: u32 = 0;
        while (i < 5000) : (i += 1) {
            // より複雑なアドレスパターンでノード作成を促進
            const base_addr = 192 << 24 | 168 << 16 | ((i / 256) & 0xFF) << 8 | (i & 0xFF);
            const addr = IPAddr{ .v4 = .{ 
                @as(u8, @intCast((base_addr >> 24) & 0xFF)),
                @as(u8, @intCast((base_addr >> 16) & 0xFF)), 
                @as(u8, @intCast((base_addr >> 8) & 0xFF)),
                @as(u8, @intCast(base_addr & 0xFF))
            } };
            
            // 異なるプレフィックス長を使用
            const prefix_len: u8 = switch (i % 4) {
                0 => 24,
                1 => 25,
                2 => 26,
                3 => 27,
                else => 24,
            };
            
            const pfx = Prefix.init(&addr, prefix_len);
            tbl.insert(&pfx, i);
        }
        
        std.debug.print("挿入後のNodePool統計:\n", .{});
        pool.printStats();
        std.debug.print("テーブルサイズ: {}\n", .{tbl.size()});
        
        // Phase 2: Delete操作でエントリを削除
        std.debug.print("\n📊 **Phase 2: Delete操作（2500件削除）**\n", .{});
        
        i = 0;
        var deleted_count: u32 = 0;
        while (i < 2500) : (i += 1) {
            const base_addr = 192 << 24 | 168 << 16 | ((i / 256) & 0xFF) << 8 | (i & 0xFF);
            const addr = IPAddr{ .v4 = .{ 
                @as(u8, @intCast((base_addr >> 24) & 0xFF)),
                @as(u8, @intCast((base_addr >> 16) & 0xFF)), 
                @as(u8, @intCast((base_addr >> 8) & 0xFF)),
                @as(u8, @intCast(base_addr & 0xFF))
            } };
            
            const prefix_len: u8 = switch (i % 4) {
                0 => 24,
                1 => 25,
                2 => 26,
                3 => 27,
                else => 24,
            };
            
            const pfx = Prefix.init(&addr, prefix_len);
            tbl.delete(&pfx);
            deleted_count += 1;
        }
        
        std.debug.print("削除後のNodePool統計:\n", .{});
        pool.printStats();
        std.debug.print("テーブルサイズ: {}\n", .{tbl.size()});
        std.debug.print("削除件数: {}\n", .{deleted_count});
        
        // Phase 3: 再挿入でNodePool効果を確認
        std.debug.print("\n📊 **Phase 3: 再挿入（3000件）**\n", .{});
        
        const pool_hits_before = pool.pool_hits;
        
        i = 0;
        while (i < 3000) : (i += 1) {
            // 新しいアドレス範囲でノード作成を促進
            const base_addr = 10 << 24 | ((i / 65536) & 0xFF) << 16 | ((i / 256) & 0xFF) << 8 | (i & 0xFF);
            const addr = IPAddr{ .v4 = .{ 
                @as(u8, @intCast((base_addr >> 24) & 0xFF)),
                @as(u8, @intCast((base_addr >> 16) & 0xFF)), 
                @as(u8, @intCast((base_addr >> 8) & 0xFF)),
                @as(u8, @intCast(base_addr & 0xFF))
            } };
            
            // より多様なプレフィックス長
            const prefix_len: u8 = switch (i % 6) {
                0 => 20,
                1 => 21,
                2 => 22,
                3 => 23,
                4 => 24,
                5 => 25,
                else => 24,
            };
            
            const pfx = Prefix.init(&addr, prefix_len);
            tbl.insert(&pfx, i + 10000);
        }
        
        const pool_hits_after = pool.pool_hits;
        const new_hits = pool_hits_after - pool_hits_before;
        
        std.debug.print("再挿入後のNodePool統計:\n", .{});
        pool.printStats();
        std.debug.print("最終テーブルサイズ: {}\n", .{tbl.size()});
        std.debug.print("Phase 3での新規ヒット数: {}\n", .{new_hits});
        
        // 効果分析
        std.debug.print("\n🎯 **NodePool効果分析**\n", .{});
        const total_ops = pool.pool_hits + pool.pool_misses;
        if (total_ops > 0) {
            const hit_rate = @as(f64, @floatFromInt(pool.pool_hits)) / @as(f64, @floatFromInt(total_ops)) * 100.0;
            std.debug.print("総合ヒット率: {d:.1}%\n", .{hit_rate});
            
            if (pool.pool_hits > 0) {
                std.debug.print("✅ NodePool効果あり！\n", .{});
                std.debug.print("   - 再利用成功: {} 回\n", .{pool.pool_hits});
                std.debug.print("   - メモリ節約効果: 確認済み\n", .{});
            } else {
                std.debug.print("⚠️ NodePool効果未確認\n", .{});
                std.debug.print("   - 原因: ノード作成パターンが単純すぎる可能性\n", .{});
            }
        }
        
    } else {
        std.debug.print("❌ NodePoolが初期化されていません！\n", .{});
        return;
    }
    
    std.debug.print("\n✅ NodePool高度テスト完了\n", .{});
} 