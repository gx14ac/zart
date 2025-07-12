const std = @import("std");
const node = @import("node.zig");
const Node = node.Node;
// Phase 4 Rollback: Back to sparse_array256 due to cache miss issues
const sparse_array256 = @import("sparse_array256.zig");

/// NodePool - 高速Node確保/解放のためのメモリプール
/// 内部実装のみ、外部からは見えない
/// Contains/Lookupには一切影響しない（Insert/Delete専用）
pub fn NodePool(comptime V: type) type {
    return struct {
        const Self = @This();
        const NodeType = node.Node(V);
        
        // 再利用可能Nodeのスタック
        free_nodes: std.ArrayList(*NodeType),
        allocator: std.mem.Allocator,
        
        // 統計（デバッグ用、リリースでは削除予定）
        total_allocated: usize,
        pool_hits: usize,
        pool_misses: usize,
        
        /// 初期化
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .free_nodes = std.ArrayList(*NodeType).init(allocator),
                .allocator = allocator,
                .total_allocated = 0,
                .pool_hits = 0,
                .pool_misses = 0,
            };
        }
        
        /// Node確保（プールから取得 or 新規作成）
        /// Contains/Lookupには使用されない（Insert/Delete専用）
        pub fn allocateNode(self: *Self) ?*NodeType {
            if (self.free_nodes.items.len > 0) {
                // プールから再利用
                if (self.free_nodes.pop()) |node_ptr| {
                    // Phase 3: 安全なリセット - 新しいArray256で完全に置き換え
                    node_ptr.children.deinit();
                    node_ptr.prefixes.deinit();
                    node_ptr.children = sparse_array256.Array256(node.Child(V)).init(self.allocator);
                    node_ptr.prefixes = sparse_array256.Array256(V).init(self.allocator);
                    self.pool_hits += 1;
                    return node_ptr;
                }
            }
            
            // 新規作成
            const node_ptr = NodeType.init(self.allocator);
            self.total_allocated += 1;
            self.pool_misses += 1;
            return node_ptr;
        }
        
        /// Node解放（プールに返却）
        /// Contains/Lookupには使用されない（Insert/Delete専用）
        pub fn releaseNode(self: *Self, node_ptr: *NodeType) !void {
            // ノードを初期状態にリセット
            // Phase 3: 安全なリセット - 完全に新しいArray256で置き換え
            node_ptr.children.deinit();
            node_ptr.prefixes.deinit();
            node_ptr.children = sparse_array256.Array256(node.Child(V)).init(self.allocator);
            node_ptr.prefixes = sparse_array256.Array256(V).init(self.allocator);
            
            // プールに返却
            try self.free_nodes.append(node_ptr);
        }
        
        /// プール統計表示（デバッグ用）
        pub fn printStats(self: *const Self) void {
            std.debug.print("NodePool Stats:\n", .{});
            std.debug.print("  Total allocated: {}\n", .{self.total_allocated});
            std.debug.print("  Pool hits: {}\n", .{self.pool_hits});
            std.debug.print("  Pool misses: {}\n", .{self.pool_misses});
            std.debug.print("  Current pool size: {}\n", .{self.free_nodes.items.len});
            if (self.pool_hits + self.pool_misses > 0) {
                const hit_rate = @as(f64, @floatFromInt(self.pool_hits)) / @as(f64, @floatFromInt(self.pool_hits + self.pool_misses)) * 100.0;
                std.debug.print("  Hit rate: {d:.1}%\n", .{hit_rate});
            }
        }
        
        /// 終了処理
        pub fn deinit(self: *Self) void {
            // プール内の全Nodeを解放
            for (self.free_nodes.items) |node_ptr| {
                node_ptr.deinit();
                self.allocator.destroy(node_ptr);
            }
            self.free_nodes.deinit();
        }
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "NodePool basic operations" {
    const allocator = std.testing.allocator;
    
    var pool = NodePool(u32).init(allocator);
    defer pool.deinit();
    
    // Test 1: 新規作成
    const node1 = pool.allocateNode();
    try std.testing.expect(pool.total_allocated == 1);
    try std.testing.expect(pool.pool_misses == 1);
    try std.testing.expect(pool.pool_hits == 0);
    
    // Test 2: プールに返却
    try pool.releaseNode(node1.?);
    try std.testing.expect(pool.free_nodes.items.len == 1);
    
    // Test 3: プールから再取得
    const node2 = pool.allocateNode();
    try std.testing.expect(node1.? == node2.?); // 同じNodeが返却される
    try std.testing.expect(pool.pool_hits == 1);
    try std.testing.expect(pool.free_nodes.items.len == 0);
    
    // Test 4: 複数Node管理
    const node3 = pool.allocateNode();
    try std.testing.expect(node2.? != node3.?); // 異なるNode
    try std.testing.expect(pool.total_allocated == 2);
    
    // 正常に返却
    try pool.releaseNode(node2.?);
    try pool.releaseNode(node3.?);
    
    std.debug.print("✅ NodePool basic operations test passed!\n", .{});
}

test "NodePool reset functionality" {
    const allocator = std.testing.allocator;
    
    var pool = NodePool(u32).init(allocator);
    defer pool.deinit();
    
    // ノードを取得してデータを設定
    const node_ptr = pool.allocateNode();
    
    // TODO: ノードにテストデータを設定（Node.reset()実装後）
    // 現在はNode.reset()が未実装なので、基本的な確認のみ
    
    // プールに返却
    try pool.releaseNode(node_ptr.?);
    
    // 再取得して初期状態であることを確認
    const node_ptr2 = pool.allocateNode();
    try std.testing.expect(node_ptr.? == node_ptr2.?);
    
    // 返却
    try pool.releaseNode(node_ptr2.?);
    
    std.debug.print("✅ NodePool reset functionality test passed!\n", .{});
}

test "NodePool performance characteristics" {
    const allocator = std.testing.allocator;
    
    var pool = NodePool(u32).init(allocator);
    defer pool.deinit();
    
    const iterations = 1000;
    var nodes: [iterations]*node.Node(u32) = undefined;
    
    // 大量確保
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        nodes[i] = pool.allocateNode().?;
    }
    
    // 大量返却
    i = 0;
    while (i < iterations) : (i += 1) {
        try pool.releaseNode(nodes[i]);
    }
    
    // プールサイズ確認
    try std.testing.expect(pool.free_nodes.items.len == iterations);
    
    // 再確保（すべてプールヒット）
    i = 0;
    while (i < iterations) : (i += 1) {
        nodes[i] = pool.allocateNode().?;
    }
    
    // ヒット率確認
    try std.testing.expect(pool.pool_hits == iterations);
    
    // 最終返却
    i = 0;
    while (i < iterations) : (i += 1) {
        try pool.releaseNode(nodes[i]);
    }
    
    pool.printStats();
    std.debug.print("✅ NodePool performance characteristics test passed!\n", .{});
} 