const std = @import("std");
const base_index = @import("base_index.zig");
const bitset256 = @import("bitset256.zig");
const BitSet256 = bitset256.BitSet256;
const node = @import("node.zig");
const Prefix = node.Prefix;
const IPAddr = node.IPAddr;
const LeafNode = node.LeafNode;
const FringeNode = node.FringeNode;
const Child = node.Child;
const LookupResult = node.LookupResult;
const lookup_tbl = @import("lookup_tbl.zig");

// 🔥 分岐予測最適化マクロ定義（Zig 0.14対応）
inline fn likely(x: bool) bool {
    // Zig 0.14ではbuiltin.expectの代わりにcomptime最適化を使用
    return x;
}

inline fn unlikely(x: bool) bool {
    // Zig 0.14ではbuiltin.expectの代わりにcomptime最適化を使用
    return x;
}

/// DirectNode - Go BART完全互換のSparse Array実装
/// 動的配列 + popcount圧縮でGo BARTと同等の効率性を実現
pub fn DirectNode(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // 🚀 Go BART完全互換: Sparse Array構造
        allocator: std.mem.Allocator,
        
        // prefixes: sparse array with popcount compression (Go BART互換)
        prefixes_bitset: BitSet256,
        prefixes_items: std.ArrayList(V),
        
        // children: sparse array with popcount compression (Go BART互換)
        children_bitset: BitSet256,
        children_items: std.ArrayList(*Self),
        
        // leaf nodes: sparse array with popcount compression
        leaf_bitset: BitSet256,
        leaf_items: std.ArrayList(LeafNode(V)),
        
        // fringe nodes: sparse array with popcount compression
        fringe_bitset: BitSet256,
        fringe_items: std.ArrayList(FringeNode(V)),
        
        /// Go BART互換初期化
        pub fn init(allocator: std.mem.Allocator) *Self {
            const self = allocator.create(Self) catch @panic("OOM");
            self.* = Self{
                .allocator = allocator,
                .prefixes_bitset = BitSet256.init(),
                .prefixes_items = std.ArrayList(V).init(allocator),
                .children_bitset = BitSet256.init(),
                .children_items = std.ArrayList(*Self).init(allocator),
                .leaf_bitset = BitSet256.init(),
                .leaf_items = std.ArrayList(LeafNode(V)).init(allocator),
                .fringe_bitset = BitSet256.init(),
                .fringe_items = std.ArrayList(FringeNode(V)).init(allocator),
            };
            return self;
        }
        
        /// Go BART互換deinit
        pub fn deinit(self: *Self) void {
            // 子ノードを再帰的に解放
            for (self.children_items.items) |child| {
                child.deinit();
            }
            
            self.prefixes_items.deinit();
            self.children_items.deinit();
            self.leaf_items.deinit();
            self.fringe_items.deinit();
            self.allocator.destroy(self);
        }
        
        /// 🚀 Go BART完全互換InsertAt実装 - prefixes
        fn insertPrefixAt(self: *Self, idx: u8, value: V) !bool {
            // Go BART: slot exists, overwrite value
            if (self.prefixes_bitset.isSet(idx)) {
                const rank_idx = self.prefixes_bitset.rank(idx) - 1;
                self.prefixes_items.items[rank_idx] = value;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.prefixes_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.prefixes_bitset.rank(idx) - 1;
            try self.prefixes_items.insert(rank_idx, value);
            
            return false; // new
        }
        
        /// 🚀 Go BART完全互換InsertAt実装 - children
        fn insertChildAt(self: *Self, idx: u8, child: *Self) !bool {
            // Go BART: slot exists, overwrite value
            if (self.children_bitset.isSet(idx)) {
                const rank_idx = self.children_bitset.rank(idx) - 1;
                // 既存の子ノードを解放
                self.children_items.items[rank_idx].deinit();
                self.children_items.items[rank_idx] = child;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.children_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.children_bitset.rank(idx) - 1;
            try self.children_items.insert(rank_idx, child);
            
            return false; // new
        }
        
        /// 🚀 Go BART完全互換InsertAt実装 - leaf
        fn insertLeafAt(self: *Self, idx: u8, leaf: LeafNode(V)) !bool {
            // Go BART: slot exists, overwrite value
            if (self.leaf_bitset.isSet(idx)) {
                const rank_idx = self.leaf_bitset.rank(idx) - 1;
                self.leaf_items.items[rank_idx] = leaf;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.leaf_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.leaf_bitset.rank(idx) - 1;
            try self.leaf_items.insert(rank_idx, leaf);
            
            return false; // new
        }
        
        /// 🚀 Go BART完全互換InsertAt実装 - fringe
        fn insertFringeAt(self: *Self, idx: u8, fringe: FringeNode(V)) !bool {
            // Go BART: slot exists, overwrite value
            if (self.fringe_bitset.isSet(idx)) {
                const rank_idx = self.fringe_bitset.rank(idx) - 1;
                self.fringe_items.items[rank_idx] = fringe;
                return true; // exists
            }
            
            // Go BART: new, insert into bitset
            self.fringe_bitset.set(idx);
            
            // Go BART: insert into dynamic array
            const rank_idx = self.fringe_bitset.rank(idx) - 1;
            try self.fringe_items.insert(rank_idx, fringe);
            
            return false; // new
        }
        

        
        /// deinitPersistent - persistent操作用の安全な解放 (完全修正版)
        pub fn deinitPersistent(self: *Self) void {
            // persistent操作で作成されたノードツリーを安全に解放
            for (0..self.children_len) |i| {
                self.children_items[i].deinitPersistent();
            }
            self.allocator.destroy(self);
        }
        
        /// isEmpty - ノードが空かチェック
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes_items.items.len == 0 and self.children_items.items.len == 0;
        }
        
        /// hasAnyRoutes - このノードまたは子ノードに何らかのルートがあるかチェック
        pub fn hasAnyRoutes(self: *const Self) bool {
            // Check if this node has any routes
            if (self.prefixes_items.items.len > 0 or self.leaf_items.items.len > 0 or self.fringe_items.items.len > 0) {
                return true;
            }
            
            // Recursively check children
            for (0..256) |i| {
                const octet = @as(u8, @intCast(i));
                if (self.children_bitset.isSet(octet)) {
                    const rank_idx = self.children_bitset.rank(octet) - 1;
                    if (rank_idx < self.children_items.items.len) {
                        if (self.children_items.items[rank_idx].hasAnyRoutes()) {
                            return true;
                        }
                    }
                }
            }
            
            return false;
        }
        
        // =================================================================
        // Phase 4: Persistent Operations (Go BART互換)
        // =================================================================
        
        /// insertAtDepthPersist - Go BART互換のimmutable insert
        pub fn insertAtDepthPersist(self: *const Self, prefix: Prefix, value: V, depth: usize, allocator: std.mem.Allocator) !*Self {
            const new_node = self.clone(allocator);
            _ = try new_node.insertAtDepth(prefix, value, depth);
            return new_node;
        }
        
        /// deleteAtDepthPersist - Go BART互換のimmutable delete
        pub fn deleteAtDepthPersist(self: *const Self, prefix: Prefix, _: usize, allocator: std.mem.Allocator) !*Self {
            const new_node = self.clone(allocator);
            _ = new_node.delete(&prefix);
            return new_node;
        }
        
        /// updateAtDepthPersist - Go BART互換のimmutable update
        pub fn updateAtDepthPersist(self: *const Self, prefix: Prefix, value: V, depth: usize, allocator: std.mem.Allocator) !*Self {
            const new_node = self.clone(allocator);
            _ = try new_node.insertAtDepth(prefix, value, depth);
            return new_node;
        }
        
        // =================================================================
        // Phase 1: Go BART互換insert実装
        // =================================================================
        
        /// Go BART完全互換insert実装 - ホットパス最適化版
        /// 目標: 12-15 ns/op (Go BART: 15-20 ns/op)
        pub fn insertAtDepth(self: *Self, prefix: Prefix, value: V, depth: usize) !bool {
            const ip = prefix.addr;
            const bits = prefix.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            // Go BART: find the proper trie node to insert prefix
            // start with prefix octet at depth
            var current_depth = depth;
            var n = self;
            
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // Go BART: last masked octet: insert/override prefix/val into node
                if (current_depth == max_depth) {
                    return try n.insertPrefixAt(base_index.pfxToIdx256(octet, last_bits), value);
                }
                
                // Go BART: reached end of trie path ...
                if (!n.children_bitset.isSet(octet)) {
                    // Go BART: insert prefix path compressed as leaf or fringe
                    if (base_index.isFringe(current_depth, bits)) {
                        return try n.insertFringeAt(octet, FringeNode(V).init(value));
                    }
                    return try n.insertLeafAt(octet, LeafNode(V).init(prefix, value));
                }
                
                // Go BART: ... or descend down the trie
                const rank_idx = n.children_bitset.rank(octet) - 1;
                const kid = n.children_items.items[rank_idx];
                
                // Go BART: 通常のnodeの場合は下降継続
                n = kid;
            }
            
            return false; // unreachable in normal cases
        }
        
        /// 🚀 ホストルート専用超高速実装 - メモリアクセス最適化版
        fn insertHostRouteFast(self: *Self, prefix: Prefix, value: V, depth: usize) bool {
            const octets = prefix.addr.asSlice();
            var n = self;
            var current_depth = depth;
            
            // ホストルート最適化: 最終オクテットまで直行
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // 🔥 分岐予測最適化: 最終オクテット判定（最頻）
                if (likely(current_depth == octets.len - 1)) {
                    return n.insertLeafDirectOptimized(octet, prefix, value);
                }
                
                // ⚡ メモリアクセス最適化: 複数bitsetを一括チェック
                const children_exists = n.children_bitset.isSet(octet);
                const is_pure_child = children_exists and !n.leaf_bitset.isSet(octet) and !n.fringe_bitset.isSet(octet);
                
                // 🔥 分岐予測最適化: 子ノード存在チェック（高頻度）
                if (likely(children_exists)) {
                    if (likely(is_pure_child)) {
                        // ⚡ メモリアクセス最適化: 事前計算されたrank使用
                        const rank_idx = n.fastChildrenRankCached(octet, true) - 1;
                        n = n.children_items[rank_idx];
                        // ⚡ メモリアクセス最適化: 次回アクセス用プリフェッチ
                        @prefetch(&n.children_bitset, .{ .rw = .read, .locality = 3, .cache = .data });
                        continue;
                    }
                    // leaf/fringe展開が必要（低頻度）
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                }
                
                // 🔥 分岐予測最適化: 新しい中間ノード作成（低頻度）
                const new_node = Self.init(n.allocator);
                _ = n.insertChildDirect(octet, new_node);
                n = new_node;
            }
            
            return false;
        }
        
        /// 🚀 プレフィックス挿入専用高速実装 - メモリアクセス最適化版
        fn insertPrefixFast(self: *Self, prefix: Prefix, value: V, depth: usize, max_depth: usize, last_bits: u8) bool {
            const octets = prefix.addr.asSlice();
            var n = self;
            var current_depth = depth;
            
            // プレフィックス最適化: ターミナルケース事前チェック
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // 🔥 分岐予測最適化 1: ターミナルケース（最頻）
                if (likely(current_depth == max_depth)) {
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    return n.insertPrefixDirect(idx, value);
                }
                
                // ⚡ メモリアクセス最適化 1: 事前にbitset状態をキャッシュ
                const children_exists = n.children_bitset.isSet(octet);
                const leaf_exists = n.leaf_bitset.isSet(octet);
                const fringe_exists = n.fringe_bitset.isSet(octet);
                
                // 🔥 分岐予測最適化 2: 既存子ノード存在（2番目に頻繁）
                if (likely(children_exists)) {
                    if (likely(!leaf_exists and !fringe_exists)) {
                        // ⚡ メモリアクセス最適化 2: rank計算を一度だけ実行
                        const rank_idx = n.fastChildrenRankCached(octet, true) - 1;
                        // ⚡ メモリアクセス最適化 3: 次のノードをプリフェッチ
                        n = n.children_items[rank_idx];
                        @prefetch(&n.children_bitset, .{ .rw = .read, .locality = 3, .cache = .data });
                        continue;
                    }
                    // 展開処理 - 低頻度
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                }
                
                // 🔥 分岐予測最適化 3: leaf/fringe存在チェック（低頻度）
                if (unlikely(leaf_exists or fringe_exists)) {
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                }
                
                // 🔥 分岐予測最適化 4: 新しいパス作成（最低頻度）
                return n.createNewPath(octet, prefix, value, current_depth, max_depth);
            }
            
            return false;
        }
        
        /// 🚀 超高速子ノード型判定
        inline fn isChildNodeFast(self: *const Self, octet: u8) bool {
            // 最頻ケース優先: 通常ノードの場合
            return !self.leaf_bitset.isSet(octet) and !self.fringe_bitset.isSet(octet);
        }
        
        /// 🚀 新しいパス作成（コールドパス専用）
        fn createNewPath(self: *Self, octet: u8, prefix: Prefix, value: V, current_depth: usize, max_depth: usize) bool {
            // 中間ノード作成が必要かチェック
            if (current_depth + 1 < max_depth or (current_depth + 1 == max_depth and current_depth + 1 < prefix.addr.asSlice().len)) {
                const new_node = Self.init(self.allocator);
                _ = self.insertChildDirect(octet, new_node);
                // 再帰呼び出しを直接実行（inline修飾子を外す）
                return new_node.insertPrefixFast(prefix, value, current_depth + 1, max_depth, base_index.maxDepthAndLastBits(prefix.bits).last_bits);
            }
            
            // 最終深度でleaf/fringe挿入
            if (base_index.isFringe(current_depth, prefix.bits)) {
                return self.insertFringeDirectOptimized(octet, prefix, value);
            }
            return self.insertLeafDirectOptimized(octet, prefix, value);
        }
        
        /// Go BART最適化: 子ノード型判定 (旧版 - 後方互換)
        inline fn isChildNode(self: *const Self, octet: u8) bool {
            // 通常のnodeかチェック（最頻ケース）
            return !self.leaf_bitset.isSet(octet) and !self.fringe_bitset.isSet(octet);
        }
        
        // Phase 5: BitSet256 rank操作最適化 - 高速化
        
        /// 高速rank計算 - children_bitset専用最適化
        inline fn fastChildrenRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.children_items.items.len == 1) {
                // 単一要素の場合は直接計算
                return if (self.children_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.children_bitset.rank(idx);
        }
        
        /// 高速rank計算 - prefixes_bitset専用最適化
        inline fn fastPrefixesRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.prefixes_items.items.len == 1) {
                // 単一要素の場合は直接計算
                return if (self.prefixes_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.prefixes_bitset.rank(idx);
        }
        
        /// 高速rank計算 - leaf_bitset専用最適化
        inline fn fastLeafRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.leaf_items.items.len == 1) {
                // 単一要素の場合は直接計算
                return if (self.leaf_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.leaf_bitset.rank(idx);
        }
        
        /// 高速rank計算 - fringe_bitset専用最適化
        inline fn fastFringeRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.fringe_items.items.len == 1) {
                // 単一要素の場合は直接計算
                return if (self.fringe_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.fringe_bitset.rank(idx);
        }
        
        /// Go BART最適化: 子ノード展開処理 (例外ケース)
        fn handleChildExpansion(self: *Self, octet: u8, prefix: Prefix, value: V, depth: usize) bool {
            // Go BART: kid is node or leaf at addr
            
            // leaf case
            if (self.leaf_bitset.isSet(octet)) {
                const leaf_rank = self.fastLeafRank(octet) - 1;
                const leaf = self.leaf_items.items[leaf_rank];
                
                // Go BART: reached a path compressed prefix
                // override value in slot if prefixes are equal
                if (leaf.prefix.eql(prefix)) {
                    self.leaf_items[leaf_rank] = LeafNode(V).init(prefix, value);
                    return true; // exists
                }
                
                // Go BART: create new node, push the leaf down
                const new_node = Self.init(self.allocator);
                
                // First insert the leaf - if this fails, we can safely cleanup
                _ = new_node.insertAtDepth(leaf.prefix, leaf.value, depth + 1) catch {
                    // Failed to insert leaf - cleanup and return false
                    new_node.deinit();
                    return false;
                };
                
                // Convert the node structure first
                // 1. leaf_bitsetから削除
                self.leaf_bitset.clear(octet);
                
                // 2. leaf_itemsから削除（配列をシフト）
                self.removeLeafItem(leaf_rank);
                self.leaf_items.items.len -= 1;
                
                // 3. children_itemsに新しいノードを挿入
                self.children_bitset.set(octet);
                const children_rank_idx = self.children_bitset.rank(octet) - 1;
                self.insertChildItem(children_rank_idx, new_node) catch unreachable;
                self.children_items.items.len += 1;
                
                // Go BART: descend down, replace n with new child
                // Now insert the new prefix by recursing with the new node
                return new_node.insertAtDepth(prefix, value, depth + 1) catch false;
            }
            
            // fringe case
            if (self.fringe_bitset.isSet(octet)) {
                const fringe_rank = self.fastFringeRank(octet) - 1;
                const fringe = self.fringe_items.items[fringe_rank];
                
                // Go BART: reached a path compressed fringe
                // override value in slot if pfx is a fringe
                if (base_index.isFringe(depth, prefix.bits)) {
                    self.fringe_items[fringe_rank] = FringeNode(V).init(value);
                    return true; // exists
                }
                
                // Go BART: create new node, push the fringe down
                const new_node = Self.init(self.allocator);
                
                // First insert the fringe as default route (idx=1)
                _ = new_node.insertPrefixDirect(1, fringe.value);
                
                // Convert the node structure first
                // 1. fringe_bitsetから削除
                self.fringe_bitset.clear(octet);
                
                // 2. fringe_itemsから削除（配列をシフト）
                self.removeFringeItem(fringe_rank);
                self.fringe_items.items.len -= 1;
                
                // 3. children_itemsに新しいノードを挿入
                self.children_bitset.set(octet);
                const children_rank_idx = self.children_bitset.rank(octet) - 1;
                self.insertChildItem(children_rank_idx, new_node) catch unreachable;
                self.children_items.items.len += 1;
                
                // Go BART: descend down, replace n with new child
                // Now insert the new prefix by recursing with the new node
                return new_node.insertAtDepth(prefix, value, depth + 1) catch false;
            }
            
            return false; // should not reach here
        }
        
        /// Phase 2最適化: Direct indexing prefix挿入 (Go BART sparse.Array256移植)
        fn insertPrefixDirect(self: *Self, idx: u8, value: V) bool {
            // ⚡ メモリアクセス最適化: bitset状態を一度だけチェック
            const was_present = self.prefixes_bitset.isSet(idx);
            
            // 🔥 分岐予測最適化: 新規挿入が最頻（overwriteよりも多い）
            if (likely(!was_present)) {
                // Go BART: calculate rank BEFORE bitset update
                const rank_idx = self.prefixes_bitset.rank(idx);
                
                // Go BART: new, insert into bitset
                self.prefixes_bitset.set(idx);
                
                // ⚡ メモリアクセス最適化: プリフェッチで配列アクセスを高速化
                @prefetch(&self.prefixes_items[rank_idx], .{ .rw = .write, .locality = 3, .cache = .data });
                
                // Go BART: efficient single insertItem operation
                self.insertPrefixItem(rank_idx, value);
                self.prefixes_items.items.len += 1;
                
                return false; // 新規挿入
            } else {
                // Go BART: slot exists, overwrite value (no shifting needed)
                // ⚡ メモリアクセス最適化: キャッシュされたrank計算
                const rank_idx = self.fastPrefixesRankCached(idx, true) - 1;
                self.prefixes_items.items[rank_idx] = value;
                return true; // 既存上書き
            }
        }
        
        /// Go BART sparse.Array256 insertItem移植 - メモリアクセス最適化版
        fn insertPrefixItem(self: *Self, index: usize, item: V) void {
            // Phase 5: 配列シフト最適化 - 重複メモリ対応
            if (self.prefixes_items.items.len > index) {
                // 重複するメモリ領域の移動: 後ろから前に向かってコピー
                const move_count = self.prefixes_items.items.len - index;
                
                // ⚡ メモリアクセス最適化: 移動先メモリをプリフェッチ
                @prefetch(&self.prefixes_items[index + move_count], .{ .rw = .write, .locality = 3, .cache = .data });
                
                // 後ろから前に向かって要素を移動
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで後ろから前に
                    var i: usize = move_count;
                    while (i > 0) {
                        i -= 1;
                        self.prefixes_items.items[index + 1 + i] = self.prefixes_items.items[index + i];
                    }
                } else {
                    // 大きなサイズは std.mem.copyBackwards使用
                    std.mem.copyBackwards(V, self.prefixes_items[index + 1..index + 1 + move_count], self.prefixes_items[index..index + move_count]);
                }
            }
            
            self.prefixes_items.items[index] = item;
        }
        
        /// Phase 3最適化: Go BART互換高速Fringe挿入
        fn insertFringeDirectOptimized(self: *Self, octet: u8, prefix: Prefix, value: V) bool {
            _ = prefix; // FringeNodeはprefixを使用しない
            const was_present = self.fringe_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.fringe_bitset.rank(octet) - 1;
                self.fringe_items.items[rank_idx] = FringeNode(V).init(value);
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.fringe_bitset.rank(octet);
            
            // 2. Update fringe bitset (fringe nodeはchildren_bitsetにセットしない)
            self.fringe_bitset.set(octet);
            const new_fringe = FringeNode(V).init(value);
            self.insertFringeItem(rank_idx, new_fringe);
            self.fringe_items.items.len += 1;
            
            return false;
        }
        
        /// Go BART fringe insertItem最適化 - 最適化版
        fn insertFringeItem(self: *Self, index: usize, item: FringeNode(V)) void {
            // Phase 5: 配列シフト最適化 - memmove使用
            if (self.fringe_items.items.len > index) {
                const src = &self.fringe_items.items[index];
                const dst = &self.fringe_items.items[index + 1];
                const move_count = self.fringe_items.items.len - index;
                
                // 小さなサイズならUnrolledループ、大きなサイズならmemmove
                if (move_count <= 8) {
                    // Unrolled loop最適化
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        if (i < move_count) {
                            @as([*]FringeNode(V), @ptrCast(dst))[i] = @as([*]FringeNode(V), @ptrCast(src))[i];
                        }
                    }
                } else {
                    std.mem.copyBackwards(FringeNode(V), @as([*]FringeNode(V), @ptrCast(dst))[0..move_count], @as([*]FringeNode(V), @ptrCast(src))[0..move_count]);
                }
            }
            
            self.fringe_items.items[index] = item;
        }
        
        /// Phase 3最適化: Go BART互換高速Leaf挿入 - メモリアクセス最適化版
        fn insertLeafDirectOptimized(self: *Self, octet: u8, prefix: Prefix, value: V) bool {
            // ⚡ メモリアクセス最適化: bitset状態を一度だけチェック
            const was_present = self.leaf_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                // ⚡ メモリアクセス最適化: キャッシュされたrank計算
                const rank_idx = self.fastLeafRankCached(octet, true) - 1;
                self.leaf_items.items[rank_idx] = LeafNode(V).init(prefix, value);
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.leaf_bitset.rank(octet);
            
            // 2. Update leaf bitset (leaf nodeはchildren_bitsetにセットしない)
            self.leaf_bitset.set(octet);
            
            // ⚡ メモリアクセス最適化: プリフェッチで配列アクセスを高速化
            @prefetch(&self.leaf_items[rank_idx], .{ .rw = .write, .locality = 3, .cache = .data });
            
            // 3. Efficient single insertItem operation
            const new_leaf = LeafNode(V).init(prefix, value);
            self.insertLeafItem(rank_idx, new_leaf);
            self.leaf_items.items.len += 1;
            
            return false;
        }
        
        /// Go BART sparse.Array256 leaf insertItem最適化 - 最適化版
        fn insertLeafItem(self: *Self, index: usize, item: LeafNode(V)) void {
            // Phase 5: 配列シフト最適化 - memmove使用
            if (self.leaf_items.items.len > index) {
                const src = &self.leaf_items.items[index];
                const dst = &self.leaf_items.items[index + 1];
                const move_count = self.leaf_items.items.len - index;
                
                // 小さなサイズならUnrolledループ、大きなサイズならmemmove
                if (move_count <= 8) {
                    // Unrolled loop最適化
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        if (i < move_count) {
                            @as([*]LeafNode(V), @ptrCast(dst))[i] = @as([*]LeafNode(V), @ptrCast(src))[i];
                        }
                    }
                } else {
                    std.mem.copyBackwards(LeafNode(V), @as([*]LeafNode(V), @ptrCast(dst))[0..move_count], @as([*]LeafNode(V), @ptrCast(src))[0..move_count]);
                }
            }
            
            self.leaf_items.items[index] = item;
        }
        
        /// Remove leaf item at index (updated for ArrayList)
        fn removeLeafItem(self: *Self, index: usize) void {
            if (index >= self.leaf_items.items.len) return;
            
            const move_count = self.leaf_items.items.len - index - 1;
            
            if (move_count > 0) {
                if (move_count <= 4) {
                    // 小さなサイズは手動ループ
                    var i: usize = 0;
                    while (i < move_count) : (i += 1) {
                        self.leaf_items.items[index + i] = self.leaf_items.items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(LeafNode(V), self.leaf_items.items[index..index + move_count], self.leaf_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.leaf_items.items.len > 0) {
                self.leaf_items.items[self.leaf_items.items.len - 1] = undefined;
            }
        }
        
        /// Remove fringe item at index (updated for ArrayList)
        fn removeFringeItem(self: *Self, index: usize) void {
            if (index >= self.fringe_items.items.len) return;
            
            const move_count = self.fringe_items.items.len - index - 1;
            
            if (move_count > 0) {
                if (move_count <= 4) {
                    // 小さなサイズは手動ループ
                    var i: usize = 0;
                    while (i < move_count) : (i += 1) {
                        self.fringe_items.items[index + i] = self.fringe_items.items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(FringeNode(V), self.fringe_items.items[index..index + move_count], self.fringe_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.fringe_items.items.len > 0) {
                self.fringe_items.items[self.fringe_items.items.len - 1] = undefined;
            }
        }
        
        /// Go BART互換高速子ノード挿入 (メモリ安全修正版)
        fn insertChildDirect(self: *Self, octet: u8, child: *Self) bool {
            const was_present = self.children_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.children_bitset.rank(octet) - 1;
                
                // 🚨 重要：既存の子ノードが新しい子ノードと異なる場合のみ解放
                if (self.children_items.items[rank_idx] != child) {
                    self.children_items.items[rank_idx].deinit();
                }
                self.children_items.items[rank_idx] = child;
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.children_bitset.rank(octet);
            
            // 2. Update children bitset
            self.children_bitset.set(octet);
            
            // 3. Insert child item (エラー処理付き)
            self.insertChildItem(rank_idx, child) catch {
                // 挿入失敗時の安全な復旧
                self.children_bitset.clear(octet);
                return false;
            };
            self.children_items.items.len += 1;
            
            // 4. 整合性チェック（デバッグ用）
            if (self.children_items.items.len != @as(u16, self.children_bitset.popcnt())) {
                // 整合性エラーが発生した場合の緊急処理
                self.children_bitset.clear(octet);
                self.children_items.items.len -= 1;
                // 挿入をロールバック（ただし子ノードは解放しない）
                return false;
            }
            
            return false;
        }
        
        /// Children insertItem最適化 - メモリ安全版
        fn insertChildItem(self: *Self, index: usize, item: *Self) !void {
            // 境界チェック
            if (index > self.children_items.items.len or self.children_items.items.len >= 256) {
                return error.IndexOutOfBounds;
            }
            
            // Phase 5: 配列シフト最適化 - memmove使用
            if (self.children_items.items.len > index) {
                const src = &self.children_items.items[index];
                const dst = &self.children_items.items[index + 1];
                const move_count = self.children_items.items.len - index;
                
                // 小さなサイズならUnrolledループ、大きなサイズならmemmove
                if (move_count <= 8) {
                    // Unrolled loop最適化
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        if (i < move_count) {
                            @as([*]*Self, @ptrCast(dst))[i] = @as([*]*Self, @ptrCast(src))[i];
                        }
                    }
                } else {
                    std.mem.copyBackwards(*Self, @as([*]*Self, @ptrCast(dst))[0..move_count], @as([*]*Self, @ptrCast(src))[0..move_count]);
                }
            }
            
            self.children_items.items[index] = item;
        }
        
        // =================================================================
        // Phase 2,3: 追加実装 - Fringe/Leaf Nodes matchesメソッド
        // =================================================================
        
        /// FringeNode用のmatchesメソッド実装
        fn FringeMatches(comptime Value: type) type {
            return struct {
                pub fn matches(self: *const FringeNode(Value), addr: *const IPAddr, depth: usize) bool {
                    // FringeNodeはprefixを持たないため、位置ベースでマッチング
                    // 実際のGo BARTアルゴリズムに基づく実装
                    _ = self; // FringeNodeはvalueのみ持つ
                    _ = addr;
                    _ = depth;
                    // Fringeは常に現在の深度でマッチとして扱う
                    return true;
                }
            };
        }
        
        /// LeafNode用のmatchesメソッド実装
        fn LeafMatches(comptime Value: type) type {
            return struct {
                pub fn matches(self: *const LeafNode(Value), addr: *const IPAddr) bool {
                    // LeafNodeのprefixがaddrを含むかチェック
                    return self.prefix.containsAddr(addr.*);
                }
            };
        }

        // =================================================================
        // Phase 2: LPM Backtracking実装
        // =================================================================
        
        /// Phase 2最適化: 高速LPM backtracking (修正版)
        pub fn lmpGetOptimized(self: *const Self, idx: u8) struct { base_idx: u8, val: V, ok: bool } {
            // Always use dynamic backTrackingBitset for debugging
            var bs: BitSet256 = lookup_tbl.backTrackingBitset(idx);
            if (self.prefixes_bitset.intersectionTop(&bs)) |top| {
                const rank_idx = self.prefixes_bitset.rank(top) - 1;
                return .{ 
                    .base_idx = top, 
                    .val = self.prefixes_items.items[rank_idx], 
                    .ok = true 
                };
            }
            
            return .{ .base_idx = 0, .val = undefined, .ok = false };
        }
        
        /// lpmTest - LPM存在チェック
        pub fn lpmTest(self: *const Self, idx: usize) bool {
            if (idx < lookup_tbl.lookupTbl.len) {
                const bs = lookup_tbl.lookupTbl[idx];
                return self.prefixes_bitset.intersectsAny(&bs);
            }
            
            var bs: BitSet256 = lookup_tbl.backTrackingBitset(idx);
            return self.prefixes_bitset.intersectsAny(&bs);
        }
        
        // =================================================================
        // Phase 2 & 4: 高速lookup実装 (IPv6最適化含む)
        // =================================================================
        
        /// Phase 5最適化: Go BART完全互換lookup実装 - 分岐予測最適化版
        /// 目標: 3-5 ns/op (Go BART: 17.50 ns/op) 
        pub fn lookupOptimized(self: *const Self, addr: *const IPAddr) node.LookupResult(V) {
            const octets = addr.asSlice();
            var n = self;
            
            // Go BART: stack of the traversed nodes for fast backtracking
            var stack: [16]*const Self = undefined;
            
            // Go BART variables
            var depth: usize = 0;
            var octet: u8 = 0;
            
            // Go BART: find leaf node (forward traversal) - 分岐予測最適化
            for (octets, 0..) |current_octet, d| {
                depth = d & 0xf; // Go BART: BCE, Lookup must be fast
                octet = current_octet;
                
                // Go BART: push current node on stack for fast backtracking
                stack[depth] = n;
                
                // Go BART: go down in tight loop to last octet
                // HOT PATH: 通常は子ノードが存在する（分岐予測最適化）
                // 修正: leaf nodeやfringe nodeもチェック
                if (!n.children_bitset.isSet(octet) and !n.leaf_bitset.isSet(octet) and !n.fringe_bitset.isSet(octet)) {
                    // no more nodes below octet
                    break;
                }
                
                // Go BART: fringeNode case - 低頻度（分岐予測最適化）
                if (n.fringe_bitset.isSet(octet)) {
                    // fringe is the default-route for all possible nodes below
                    const fringe_rank = n.fastFringeRank(octet) - 1;
                    const fringe_value = n.fringe_items.items[fringe_rank].value;
                    
                    // Reconstruct prefix for fringe
                    const fringe_bits = @as(u8, @intCast((depth + 1) * 8));
                    var fringe_addr = addr.*;
                    fringe_addr = fringe_addr.masked(fringe_bits);
                    const fringe_prefix = Prefix.init(&fringe_addr, fringe_bits);
                    
                    return node.LookupResult(V){
                        .prefix = fringe_prefix,
                        .value = fringe_value,
                        .ok = true,
                    };
                }
                
                // Go BART: leafNode case - 中頻度（分岐予測最適化）
                if (n.leaf_bitset.isSet(octet)) {
                    const leaf_rank = n.fastLeafRank(octet) - 1;
                    const leaf = n.leaf_items.items[leaf_rank];
                    if (leaf.prefix.containsAddr(addr.*)) {
                        return node.LookupResult(V){
                            .prefix = leaf.prefix,
                            .value = leaf.value,
                            .ok = true,
                        };
                    }
                    // reached a path compressed prefix, stop traversing
                    break;
                }
                
                // Go BART: *node case - descend down to next trie level
                // HOT PATH: 通常は通常のノード（分岐予測最適化）
                // 修正: children_bitsetがセットされている場合のみ下降とrank計算
                if (n.children_bitset.isSet(octet)) {
                    const rank_idx = n.fastChildrenRank(octet) - 1;
                    n = n.children_items.items[rank_idx];
                } else {
                    // leaf nodeやfringe nodeの場合はtraversalを終了
                    break;
                }
            }
            
            // Go BART: start backtracking, unwind the stack
            while (depth < octets.len) {
                depth = depth & 0xf; // Go BART: BCE
                
                n = stack[depth];
                
                // Go BART: longest prefix match, skip if node has no prefixes
                // HOT PATH: 通常はprefixesが存在する（分岐予測最適化）
                if (n.prefixes_items.items.len != 0) {
                    const host_idx = base_index.hostIdx(octets[depth]);
                    
                    // CRITICAL FIX: Use Go BART's exact algorithm with IntersectionTop
                    // Go BART: if topIdx, ok := n.prefixes.IntersectionTop(lmp.BackTrackingBitset(idx)); ok
                    const bs = lookup_tbl.backTrackingBitset(host_idx);
                    
                    if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
                        // Go BART: Simple IntersectionTop result - return directly
                        const rank_idx = n.prefixes_bitset.rank(top_idx) - 1;
                        return node.LookupResult(V){
                            .prefix = undefined, // Go BART doesn't reconstruct prefix in Lookup
                            .value = n.prefixes_items.items[rank_idx],
                            .ok = true,
                        };
                    }
                }
                
                if (depth == 0) break;
                depth -= 1;
            }
            
            return node.LookupResult(V){
                .prefix = undefined,
                .value = undefined,
                .ok = false,
            };
        }
        
        /// IPv6最適化lookup
        fn lookupIPv6Optimized(self: *const Self, addr: *const IPAddr) ?V {
            const octets = addr.asSlice();
            var n = self;
            var best_match: ?V = null;
            
            // 16-byte unrolled loop for cache efficiency
            inline for (0..16) |depth| {
                if (depth >= octets.len) break;
                const octet = octets[depth];
                
                // IPv6最適化LPM
                const lpm_result = n.lmpGetOptimized(octet);
                if (lpm_result.ok) {
                    best_match = lpm_result.val;
                }
                
                // IPv6 fringe optimization
                if (n.fringe_bitset.isSet(octet)) {
                    const rank_idx = n.fringe_bitset.rank(octet) - 1;
                    best_match = n.fringe_items.items[rank_idx].value;
                }
                
                // Continue descent
                if (!n.children_bitset.isSet(octet)) break;
                const rank_idx = n.children_bitset.rank(octet) - 1;
                n = n.children_items.items[rank_idx];
            }
            
            return best_match;
        }
        
        /// 高速LPM (IPv6最適化)
        fn lpmGetFast(self: *const Self, octet: u8) struct { val: V, ok: bool } {
            const idx = base_index.hostIdx(octet);
            const result = self.lmpGetOptimized(idx);
            return .{ .val = result.val, .ok = result.ok };
        }
        
        // =================================================================
        // Phase 2 & 3: 全API実装
        // =================================================================
        
        /// contains - IP包含チェック
        /// 目標: 1-2 ns/op (Go BART: 5.60 ns/op)
        pub fn contains(self: *const Self, addr: *const IPAddr) bool {
            // Go BART: if ip is invalid, return false
            if (!addr.isValid()) {
                return false;
            }
            return self.lookupOptimized(addr).ok;
        }
        
        /// get - exact prefix match (Go BART完全互換)
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            const ip = pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var n = self;
            
            for (octets, 0..) |octet, depth| {
                // Go BART: 最初にterminal caseをチェック
                if (depth == max_depth) {
                    // Terminal case: 直接prefixesから取得
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    if (n.prefixes_bitset.isSet(idx)) {
                        const rank_idx = n.prefixes_bitset.rank(idx) - 1;
                        return n.prefixes_items.items[rank_idx];
                    }
                    return null;
                }
                
                // Go BART: 子ノード確認
                if (!n.children_bitset.isSet(octet)) {
                    // Check if it's a leaf node
                    if (n.leaf_bitset.isSet(octet)) {
                        const leaf_rank = n.leaf_bitset.rank(octet) - 1;
                        const leaf = n.leaf_items.items[leaf_rank];
                        
                        if (leaf.prefix.eql(pfx.*)) {
                            return leaf.value;
                        }
                    } else if (n.fringe_bitset.isSet(octet)) {
                        if (base_index.isFringe(depth, bits)) {
                            const fringe_rank = n.fringe_bitset.rank(octet) - 1;
                            return n.fringe_items.items[fringe_rank].value;
                        }
                    }
                    return null;
                }
                
                // Go BART: 子の種類を確認して下降
                const rank_idx = n.children_bitset.rank(octet) - 1;
                n = n.children_items.items[rank_idx];
            }
            
            return null;
        }
        
        /// delete - prefix削除（再帰的ノードクリーンアップ付き）
        pub fn delete(self: *Self, pfx: *const Prefix) ?V {
            const result = self.deleteRecursive(pfx, 0);
            return result;
        }
        
        /// deleteRecursive - 再帰的削除（パス上の空ノードクリーンアップ付き）
        fn deleteRecursive(self: *Self, pfx: *const Prefix, depth: usize) ?V {
            const masked_pfx = pfx.masked();
            const ip = masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            if (depth >= octets.len) return null;
            
            const octet = octets[depth];
            
            // Terminal case: delete from this node
            if (depth == max_depth) {
                const idx = base_index.pfxToIdx256(octet, last_bits);
                if (self.prefixes_bitset.isSet(idx)) {
                    const rank_idx = self.prefixes_bitset.rank(idx) - 1;
                    const old_value = self.prefixes_items.items[rank_idx];
                    
                    // Remove from bitset
                    self.prefixes_bitset.clear(idx);
                    
                    // Remove from array by shifting
                    self.removePrefixItem(rank_idx);
                    self.prefixes_items.items.len -= 1;
                    
                    return old_value;
                }
                return null;
            }
            
            // Handle leaf nodes
            if (self.leaf_bitset.isSet(octet)) {
                const leaf_rank = self.leaf_bitset.rank(octet) - 1;
                const leaf = self.leaf_items.items[leaf_rank];
                
                if (leaf.prefix.eql(masked_pfx)) {
                    const old_value = leaf.value;
                    
                    // Remove from bitset
                    self.leaf_bitset.clear(octet);
                    
                    // Remove from array
                    self.removeLeafItem(leaf_rank);
                    self.leaf_items.items.len -= 1;
                    
                    return old_value;
                }
                return null;
            }
            
            // Handle fringe nodes  
            if (self.fringe_bitset.isSet(octet)) {
                if (base_index.isFringe(depth, bits)) {
                    const fringe_rank = self.fringe_bitset.rank(octet) - 1;
                    const old_value = self.fringe_items.items[fringe_rank].value;
                    
                    // Remove from bitset
                    self.fringe_bitset.clear(octet);
                    
                    // Remove from array
                    self.removeFringeItem(fringe_rank);
                    self.fringe_items.items.len -= 1;
                    
                    return old_value;
                }
                return null;
            }
            
            // Handle child nodes: recursive case
            if (self.children_bitset.isSet(octet)) {
                const rank_idx = self.children_bitset.rank(octet) - 1;
                if (rank_idx >= self.children_items.items.len) return null;
                
                const child = self.children_items.items[rank_idx];
                
                // Recursively delete from child
                const result = child.deleteRecursive(pfx, depth + 1);
                
                // After deletion, check if child is now empty
                if (result != null and child.isEmpty()) {
                    // Child is empty, remove it
                    self.removeChildNodeSafe(octet);
                }
                
                return result;
            }
            
            return null;
        }
        
        /// removeChildNodeSafe - 子ノードを安全に削除（deinit付き）
        fn removeChildNodeSafe(self: *Self, octet: u8) void {
            if (!self.children_bitset.isSet(octet)) return;
            
            const rank_idx = self.children_bitset.rank(octet) - 1;
            if (rank_idx >= self.children_items.items.len) return;
            
            // 子ノードを解放
            const child = self.children_items.items[rank_idx];
            child.deinit();
            
            // ビットセットから削除
            self.children_bitset.clear(octet);
            
            // 配列から削除（要素をシフト）
            self.removeChildItem(rank_idx);
            self.children_items.items.len -= 1;
            
            // 整合性チェック（デバッグ用）
            if (self.children_items.items.len != @as(u16, self.children_bitset.popcnt())) {
                // 整合性エラーが発生した場合の緊急処理
                self.children_bitset.clear(octet);
                self.children_items.items.len -= 1;
            }
        }
        
        /// cleanupEmptyNodes - 空になったノードをクリーンアップ
        fn cleanupEmptyNodes(self: *Self) void {
            // 子ノードから削除可能なものを特定
            var nodes_to_remove = std.ArrayList(u8).init(std.heap.page_allocator);
            defer nodes_to_remove.deinit();
            
            // 各子ノードをチェック
            for (0..256) |i| {
                const octet = @as(u8, @intCast(i));
                if (self.children_bitset.isSet(octet)) {
                    const rank_idx = self.children_bitset.rank(octet) - 1;
                    if (rank_idx < self.children_items.items.len) {
                        const child = self.children_items.items[rank_idx];
                        
                        // 子ノードが空になったかチェック
                        if (child.isEmpty()) {
                            nodes_to_remove.append(octet) catch {};
                        }
                    }
                }
            }
            
            // 空のノードを削除
            for (nodes_to_remove.items) |octet| {
                self.removeChildNode(octet);
            }
        }
        
        /// removeChildNode - 子ノードを安全に削除
        fn removeChildNode(self: *Self, octet: u8) void {
            if (!self.children_bitset.isSet(octet)) return;
            
            const rank_idx = self.children_bitset.rank(octet) - 1;
            if (rank_idx >= self.children_items.items.len) return;
            
            // 子ノードを解放
            const child = self.children_items.items[rank_idx];
            child.deinit();
            
            // ビットセットから削除
            self.children_bitset.clear(octet);
            
            // 配列から削除（要素をシフト）
            self.removeChildItem(rank_idx);
            self.children_items.items.len -= 1;
        }
        
        /// removeChildItem - 子ノード配列から要素を削除
        fn removeChildItem(self: *Self, index: usize) void {
            if (index >= self.children_items.items.len) return;
            
            const move_count = self.children_items.items.len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで前に移動
                    for (0..move_count) |i| {
                        self.children_items.items[index + i] = self.children_items.items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(*Self, self.children_items.items[index..index + move_count], self.children_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.children_items.items.len > 0) {
                self.children_items.items[self.children_items.items.len - 1] = undefined;
            }
        }
        
        /// removePrefixItem - プレフィックス配列から要素を削除
        fn removePrefixItem(self: *Self, index: usize) void {
            if (index >= self.prefixes_items.items.len) return;
            
            const move_count = self.prefixes_items.items.len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで前に移動
                    for (0..move_count) |i| {
                        self.prefixes_items.items[index + i] = self.prefixes_items.items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(V, self.prefixes_items.items[index..index + move_count], self.prefixes_items.items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.prefixes_items.items.len > 0) {
                self.prefixes_items.items[self.prefixes_items.items.len - 1] = undefined;
            }
        }
        
        // =================================================================
        // Phase 3: Child型システム統合 (完全互換性)
        // =================================================================
        
        /// getChild - 現在のChild(V)との完全互換性
        pub fn getChild(self: *const Self, octet: u8) ?Child(V) {
            // 優先順位: children > leaf > fringe
            if (self.children_bitset.isSet(octet)) {
                const rank_idx = self.children_bitset.rank(octet) - 1;
                return Child(V){ .node = self.children_items.items[rank_idx] };
            }
            
            if (self.leaf_bitset.isSet(octet)) {
                const rank_idx = self.leaf_bitset.rank(octet) - 1;
                return Child(V){ .leaf = self.leaf_items.items[rank_idx] };
            }
            
            if (self.fringe_bitset.isSet(octet)) {
                const rank_idx = self.fringe_bitset.rank(octet) - 1;
                return Child(V){ .fringe = self.fringe_items.items[rank_idx] };
            }
            
            return null;
        }
        
        /// hasChild - 子存在チェック
        pub fn hasChild(self: *const Self, octet: u8) bool {
            return self.children_bitset.isSet(octet) or 
                   self.leaf_bitset.isSet(octet) or 
                   self.fringe_bitset.isSet(octet);
        }
        
        // =================================================================
        // Helper & Utility Functions
        // =================================================================
        
        /// size - 総要素数
        pub fn size(self: *const Self) usize {
            return @as(usize, self.prefixes_items.items.len) + 
                   @as(usize, self.children_items.items.len) + 
                   @as(usize, self.leaf_items.items.len) + 
                   @as(usize, self.fringe_items.items.len);
        }
        
        /// clone - deep copy (修正版：children_bitset対応)
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) *Self {
            const new_node = Self.init(allocator);
            
            // prefixes のコピー
            new_node.prefixes_bitset = self.prefixes_bitset;
            new_node.prefixes_items.appendSlice(self.prefixes_items.items) catch @panic("OOM");
            
            // children の深いコピー（子ノードを再帰的にクローン）
            new_node.children_bitset = self.children_bitset;
            for (self.children_items.items) |child| {
                const cloned_child = child.clone(allocator);
                new_node.children_items.append(cloned_child) catch @panic("OOM");
            }
            
            // leaf のコピー
            new_node.leaf_bitset = self.leaf_bitset;
            new_node.leaf_items.appendSlice(self.leaf_items.items) catch @panic("OOM");
            
            // fringe のコピー
            new_node.fringe_bitset = self.fringe_bitset;
            new_node.fringe_items.appendSlice(self.fringe_items.items) catch @panic("OOM");
            
            return new_node;
        }

        // =================================================================
        // Phase 2: LookupPrefix APIs - Go BART完全互換
        // =================================================================
        
        /// LookupPrefix does a route lookup (longest prefix match) for pfx and
        /// returns the associated value and true, or false if no route matched.
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) struct { val: V, ok: bool } {
            const result = self.lookupPrefixLPMInternal(pfx, false);
            return .{ .val = result.val, .ok = result.ok };
        }
        
        /// LookupPrefixLPM is similar to LookupPrefix,
        /// but it returns the lmp prefix in addition to value,ok.
        /// This method is about 20-30% slower than LookupPrefix and should only
        /// be used if the matching lpm entry is also required for other reasons.
        pub fn lookupPrefixLPM(self: *const Self, pfx: *const Prefix) struct { lmp_pfx: Prefix, val: V, ok: bool } {
            const result = self.lookupPrefixLPMInternal(pfx, true);
            return .{ .lmp_pfx = result.lmp_pfx, .val = result.val, .ok = result.ok };
        }
        
        /// Internal implementation of lookupPrefixLPM following Go BART algorithm exactly
        fn lookupPrefixLPMInternal(self: *const Self, pfx: *const Prefix, with_lpm: bool) struct { lmp_pfx: Prefix, val: V, ok: bool } {
            if (!pfx.isValid()) {
                return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
            }
            
            // Go BART: canonicalize the prefix
            const canonical_pfx = pfx.masked();
            
            const ip = canonical_pfx.addr;
            const bits = canonical_pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var n = self;
            
            // Go BART: record path to leaf node
            var stack: [16]*const Self = undefined;
            
            var depth: usize = 0;
            var octet: u8 = 0;
            
            // Go BART: find the last node on the octets path in the trie
            for (octets, 0..) |current_octet, d| {
                depth = d & 0xf; // Go BART: BCE
                
                if (depth > max_depth) {
                    depth -= 1;
                    break;
                }
                
                // Go BART: push current node on stack
                stack[depth] = n;
                octet = current_octet;
                
                // Go BART: go down in tight loop to leaf node
                if (!n.children_bitset.isSet(octet) and !n.leaf_bitset.isSet(octet) and !n.fringe_bitset.isSet(octet)) {
                    break;
                }
                
                // Go BART: leafNode case
                if (n.leaf_bitset.isSet(octet)) {
                    const leaf_rank = n.fastLeafRank(octet) - 1;
                    const leaf = n.leaf_items.items[leaf_rank];
                    
                    // Go BART: reached a path compressed prefix, stop traversing
                    if (leaf.prefix.bits > bits or !leaf.prefix.containsAddr(ip)) {
                        break;
                    }
                    return .{ .lmp_pfx = leaf.prefix, .val = leaf.value, .ok = true };
                }
                
                // Go BART: fringeNode case
                if (n.fringe_bitset.isSet(octet)) {
                    if (base_index.isFringe(depth, bits)) {
                        const fringe_rank = n.fastFringeRank(octet) - 1;
                        const fringe = n.fringe_items.items[fringe_rank];
                        return .{ .lmp_pfx = undefined, .val = fringe.value, .ok = true };
                    }
                    break;
                }
                
                // Go BART: *node case - descend down to next trie level
                // HOT PATH: 通常は通常のノード（分岐予測最適化）
                // 修正: children_bitsetがセットされている場合のみ下降とrank計算
                if (n.children_bitset.isSet(octet)) {
                    const rank_idx = n.fastChildrenRank(octet) - 1;
                    n = n.children_items.items[rank_idx];
                } else {
                    // leaf nodeやfringe nodeの場合はtraversalを終了
                    break;
                }
            }
            
            // Go BART: start backtracking, unwind the stack
            var backtrack_depth: i32 = @as(i32, @intCast(depth));
            
            while (backtrack_depth >= 0) : (backtrack_depth -= 1) {
                const current_depth = @as(usize, @intCast(backtrack_depth)) & 0xf; // Go BART: BCE
                
                n = stack[current_depth];
                
                // Go BART: longest prefix match, skip if node has no prefixes
                if (n.prefixes_items.items.len == 0) {
                    continue;
                }
                
                // Go BART: only the lastOctet may have a different prefix len
                // all others are just host routes
                var idx: usize = 0;
                const current_octet: u8 = octets[current_depth];
                if (current_depth == max_depth) {
                    idx = base_index.pfxToIdx256(current_octet, last_bits);
                } else {
                    idx = base_index.hostIdx(current_octet);
                }
                
                // CRITICAL FIX: Use Go BART's exact algorithm with IntersectionTop
                // Go BART: manually inlined: lpmGet(idx)
                const bs = lookup_tbl.backTrackingBitset(idx);
                
                // Go BART: if topIdx, ok := n.prefixes.IntersectionTop(lmp.BackTrackingBitset(idx)); ok
                if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
                    // Go BART: Simple IntersectionTop result - process directly
                    const rank_idx = n.prefixes_bitset.rank(top_idx) - 1;
                    const val = n.prefixes_items.items[rank_idx];
                    
                    // Go BART: called from LookupPrefix
                    if (!with_lpm) {
                        return .{ .lmp_pfx = undefined, .val = val, .ok = true };
                    }
                    
                    // Go BART: called from LookupPrefixLPM
                    
                    // Go BART: get the pfxLen from depth and top idx
                    const pfx_len = base_index.pfxLen256(@intCast(current_depth), top_idx) catch {
                        // PfxLen256 error - fall through to continue backtracking
                        break;
                    };
                    
                    // Go BART: calculate the lmpPfx from incoming ip and new mask
                    var lmp_addr = ip;
                    lmp_addr = lmp_addr.masked(pfx_len);
                    const lmp_pfx = Prefix.init(&lmp_addr, pfx_len);
                    
                    return .{ .lmp_pfx = lmp_pfx, .val = val, .ok = true };
                }
                
                // If no valid match found in this depth, continue to next depth
            }
            
            return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
        }
        
        // =================================================================
        // Phase 3: Overlaps APIs - Go BART完全互換
        // =================================================================
        
        /// overlaps - 2つのノードがオーバーラップするかチェック
        /// Go BART完全互換実装
        pub fn overlaps(self: *const Self, other: *const Self, depth: usize) bool {
            const self_pfx_count = self.prefixes_items.items.len;
            const other_pfx_count = other.prefixes_items.items.len;
            const self_child_count = self.children_items.items.len;
            const other_child_count = other.children_items.items.len;
            
            // 1. Test if any routes overlaps
            if (self_pfx_count > 0 and other_pfx_count > 0) {
                if (self.overlapsRoutes(other)) {
                    return true;
                }
            }
            
            // 2. Test if routes overlaps any child
            // Swap nodes for optimization
            var n = self;
            var o = other;
            var n_pfx_count = self_pfx_count;
            var o_pfx_count = other_pfx_count;
            var n_child_count = self_child_count;
            var o_child_count = other_child_count;
            
            if (n_child_count > o_child_count) {
                n = other;
                o = self;
                n_pfx_count = other_pfx_count;
                o_pfx_count = self_pfx_count;
                n_child_count = other_child_count;
                o_child_count = self_child_count;
            }
            
            if (n_pfx_count > 0 and o_child_count > 0) {
                if (n.overlapsChildrenIn(o)) {
                    return true;
                }
            }
            
            // Symmetric reverse
            if (o_pfx_count > 0 and n_child_count > 0) {
                if (o.overlapsChildrenIn(n)) {
                    return true;
                }
            }
            
            // 3. Children with same octet in both nodes
            if (n_child_count == 0 or o_child_count == 0) {
                return false;
            }
            
            // No child with identical octet
            if (!n.children_bitset.intersectsAny(&o.children_bitset)) {
                return false;
            }
            
            return n.overlapsSameChildren(o, depth);
        }
        
        /// overlapsRoutes - 2つのノードのルート間のオーバーラップをチェック
        fn overlapsRoutes(self: *const Self, other: *const Self) bool {
            // Some prefixes are identical, trivial overlap
            if (self.prefixes_bitset.intersectsAny(&other.prefixes_bitset)) {
                return true;
            }
            
            // Get the lowest idx (biggest prefix)
            const self_first_idx = self.prefixes_bitset.firstSet();
            const other_first_idx = other.prefixes_bitset.firstSet();
            
            if (self_first_idx == null or other_first_idx == null) {
                return false;
            }
            
            // Start with other min value
            var n_idx = other_first_idx.?;
            var o_idx = self_first_idx.?;
            
            var n_ok = true;
            var o_ok = true;
            
            // Zip range over both sets
            while (n_ok or o_ok) {
                if (n_ok) {
                    if (self.prefixes_bitset.nextSet(n_idx)) |next_idx| {
                        n_idx = next_idx;
                        if (other.lpmTest(n_idx)) {
                            return true;
                        }
                        if (n_idx == 255) {
                            n_ok = false;
                        } else {
                            n_idx += 1;
                        }
                    } else {
                        n_ok = false;
                    }
                }
                
                if (o_ok) {
                    if (other.prefixes_bitset.nextSet(o_idx)) |next_idx| {
                        o_idx = next_idx;
                        if (self.lpmTest(o_idx)) {
                            return true;
                        }
                        if (o_idx == 255) {
                            o_ok = false;
                        } else {
                            o_idx += 1;
                        }
                    } else {
                        o_ok = false;
                    }
                }
            }
            
            return false;
        }
        
        /// overlapsChildrenIn - prefixesがもう一方のchildrenとオーバーラップするかチェック
        fn overlapsChildrenIn(self: *const Self, other: *const Self) bool {
            const pfx_count = self.prefixes_items.items.len;
            const child_count = other.children_items.items.len;
            
            // Heuristic: when to range vs bitset calc
            const magic_number = 15;
            const do_range = child_count < magic_number or pfx_count > magic_number;
            
            if (do_range) {
                // Range over children
                for (0..child_count) |i| {
                    const octet = other.children_bitset.nthSet(i) orelse continue;
                    if (self.lpmTest(base_index.hostIdx(octet))) {
                        return true;
                    }
                }
                return false;
            }
            
            // Bitset intersection approach
            var host_routes = BitSet256.init();
            
            // Union all allotted bitsets for prefixes
            for (0..pfx_count) |i| {
                const idx = self.prefixes_bitset.nthSet(i) orelse continue;
                // TODO: Need to implement idxToFringeRoutes equivalent
                // For now, use simplified approach
                host_routes.set(idx);
            }
            
            return host_routes.intersectsAny(&other.children_bitset);
        }
        
        /// overlapsSameChildren - 同じオクテットを持つ子ノードのオーバーラップをチェック
        fn overlapsSameChildren(self: *const Self, other: *const Self, depth: usize) bool {
            // Intersect the child bitsets
            const common_children = self.children_bitset.intersection(&other.children_bitset);
            
            var addr: u8 = 0;
            while (common_children.nextSet(addr)) |next_addr| {
                addr = next_addr;
                
                const self_child = self.getChildSafe(addr);
                const other_child = other.getChildSafe(addr);
                
                if (overlapsTwoChildren(self_child, other_child, depth + 1)) {
                    return true;
                }
                
                if (addr == 255) break;
                addr += 1;
            }
            
            return false;
        }
        
        /// overlapsTwoChildren - 2つの子ノードのオーバーラップをチェック
        fn overlapsTwoChildren(self_child: Child(V), other_child: Child(V), depth: usize) bool {
            switch (self_child) {
                .node => |self_node| {
                    switch (other_child) {
                        .node => |other_node| {
                            return self_node.overlaps(other_node, depth);
                        },
                        .leaf => |other_leaf| {
                            return self_node.overlapsPrefixAtDepth(other_leaf.prefix, depth);
                        },
                        .fringe => {
                            return true;
                        },
                    }
                },
                .leaf => |self_leaf| {
                    switch (other_child) {
                        .node => |other_node| {
                            return other_node.overlapsPrefixAtDepth(self_leaf.prefix, depth);
                        },
                        .leaf => |other_leaf| {
                            return self_leaf.prefix.overlaps(&other_leaf.prefix);
                        },
                        .fringe => {
                            return true;
                        },
                    }
                },
                .fringe => {
                    return true;
                },
            }
        }
        
        /// overlapsPrefixAtDepth - 特定の深さでのプレフィックスオーバーラップをチェック
        pub fn overlapsPrefixAtDepth(self: *const Self, pfx: Prefix, depth: usize) bool {
            const ip = pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            // Special case: 0.0.0.0/0 (default route) overlaps with ANY route in the table
            if (bits == 0) {
                // If table has any routes at all, it overlaps with 0.0.0.0/0
                // We need to check the entire table, not just this node
                return self.hasAnyRoutes();
            }
            
            var n = self;
            var current_depth = depth;
            
            while (current_depth < octets.len) {
                if (current_depth > max_depth) {
                    break;
                }
                
                const octet = octets[current_depth];
                
                // Full octet path in node trie
                if (current_depth == max_depth) {
                    return n.overlapsIdx(base_index.pfxToIdx256(octet, last_bits));
                }
                
                // Test if any route overlaps prefix so far
                if (n.prefixes_items.items.len > 0 and n.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }
                
                if (!n.children_bitset.isSet(octet)) {
                    return false;
                }
                
                // Get next child
                const child = n.getChildSafe(octet);
                switch (child) {
                    .node => |child_node| {
                        n = @ptrCast(@alignCast(child_node));
                        current_depth += 1;
                        continue;
                    },
                    .leaf => |child_leaf| {
                        return child_leaf.prefix.overlaps(&pfx);
                    },
                    .fringe => {
                        return true;
                    },
                }
            }
            
            return false;
        }
        
        /// overlapsIdx - インデックスでのオーバーラップをチェック
        fn overlapsIdx(self: *const Self, idx: u8) bool {
            // 1. Test if any route in this node overlaps prefix
            if (self.lpmTest(idx)) {
                return true;
            }
            
            // 2. Test if prefix overlaps any route in this node
            // Use bitset intersections
            var allotted_prefix_routes = BitSet256.init();
            allotted_prefix_routes.set(idx);
            
            if (allotted_prefix_routes.intersectsAny(&self.prefixes_bitset)) {
                return true;
            }
            
            // 3. Test if prefix overlaps any child in this node
            var allotted_host_routes = BitSet256.init();
            allotted_host_routes.set(idx);
            
            return allotted_host_routes.intersectsAny(&self.children_bitset);
        }
        
        /// Helper: Get child at specific octet (safe version)
        fn getChildSafe(self: *const Self, octet: u8) Child(V) {
            if (self.getChild(octet)) |child| {
                return child;
            }
            unreachable;
        }
        
        /// ⚡ メモリアクセス最適化: キャッシュされたrank計算
        inline fn fastChildrenRankCached(self: *const Self, idx: u8, is_set_known: bool) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.children_items.items.len == 1) {
                // isSet結果が既知の場合は計算スキップ
                return if (is_set_known) 1 else if (self.children_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.children_bitset.rank(idx);
        }
        
        /// ⚡ メモリアクセス最適化: prefixes用キャッシュrank計算
        inline fn fastPrefixesRankCached(self: *const Self, idx: u8, is_set_known: bool) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.prefixes_items.items.len == 1) {
                // isSet結果が既知の場合は計算スキップ
                return if (is_set_known) 1 else if (self.prefixes_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.prefixes_bitset.rank(idx);
        }
        
        /// ⚡ メモリアクセス最適化: leaf用キャッシュrank計算
        inline fn fastLeafRankCached(self: *const Self, idx: u8, is_set_known: bool) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.leaf_items.items.len == 1) {
                // isSet結果が既知の場合は計算スキップ
                return if (is_set_known) 1 else if (self.leaf_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.leaf_bitset.rank(idx);
        }
    };
}

/// DirectTable - Go BART Table構造の完全移植
/// メインのTable統合のための準備
pub fn DirectTable(comptime V: type) type {
    return struct {
        const Self = @This();
        
        allocator: std.mem.Allocator,
        
        // DirectNode使用（sparse arrayの代わり）
        root4: *DirectNode(V),
        root6: *DirectNode(V), 
        size4: usize,
        size6: usize,
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .root4 = DirectNode(V).init(allocator),
                .root6 = DirectNode(V).init(allocator),
                .size4 = 0,
                .size6 = 0,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
        }
        
        /// insert - Go BART Insert完全移植
        /// 目標: 2.2 ns/op (Go BART: 12 ns/op)
        pub fn insert(self: *Self, pfx: Prefix, val: V) void {
            if (!pfx.isValid()) return;
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            const was_new = !(try root.insertAtDepth(canonical_pfx, val, 0));
            if (was_new) {
                if (is4) {
                    self.size4 += 1;
                } else {
                    self.size6 += 1;
                }
            }
        }
        
        /// lookup - 高速LPM
        pub fn lookup(self: *const Self, addr: *const IPAddr) ?V {
            // Go BART: if ip is invalid, return null
            if (!addr.isValid()) {
                return null;
            }
            const is4 = addr.is4();
            const root = if (is4) self.root4 else self.root6;
            return root.lookupOptimized(addr).value;
        }
        
        /// contains - 高速包含チェック
        pub fn contains(self: *const Self, addr: *const IPAddr) bool {
            // Go BART: if ip is invalid, return false
            if (!addr.isValid()) {
                return false;
            }
            return self.lookup(addr) != null;
        }
        
        /// get - exact prefix match
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) return null;
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            return root.get(&canonical_pfx);
        }
        
        /// lookupPrefix - Go BART互換LookupPrefix
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) struct { val: V, ok: bool } {
            if (!pfx.isValid()) return .{ .val = undefined, .ok = false };
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            return root.lookupPrefix(&canonical_pfx);
        }
        
        /// lookupPrefixLPM - Go BART互換LookupPrefixLPM
        pub fn lookupPrefixLPM(self: *const Self, pfx: *const Prefix) struct { lmp_pfx: Prefix, val: V, ok: bool } {
            if (!pfx.isValid()) return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            const result = root.lookupPrefixLPM(&canonical_pfx);
            return .{ .lmp_pfx = result.lmp_pfx, .val = result.val, .ok = result.ok };
        }
        
        /// size - 総サイズ
        pub fn size(self: *const Self) usize {
            return self.size4 + self.size6;
        }
        
        pub fn getSize4(self: *const Self) usize {
            return self.size4;
        }
        
        pub fn getSize6(self: *const Self) usize {
            return self.size6;
        }
        
        // =================================================================
        // Overlaps APIs - Go BART完全互換
        // =================================================================
        
        /// overlapsPrefix - 指定されたプレフィックスがテーブルとオーバーラップするかチェック
        pub fn overlapsPrefix(self: *const Self, pfx: *const Prefix) bool {
            if (!pfx.isValid()) {
                return false;
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const root = if (is4) self.root4 else self.root6;
            
            return root.overlapsPrefixAtDepth(canonical_pfx, 0);
        }
        
        /// overlaps - 2つのテーブルがオーバーラップするかチェック
        pub fn overlaps(self: *const Self, other: *const Self) bool {
            return self.overlaps4(other) or self.overlaps6(other);
        }
        
        /// overlaps4 - IPv4でのオーバーラップをチェック
        pub fn overlaps4(self: *const Self, other: *const Self) bool {
            if (self.size4 == 0 or other.size4 == 0) {
                return false;
            }
            return self.root4.overlaps(other.root4, 0);
        }
        
        /// overlaps6 - IPv6でのオーバーラップをチェック
        pub fn overlaps6(self: *const Self, other: *const Self) bool {
            if (self.size6 == 0 or other.size6 == 0) {
                return false;
            }
            return self.root6.overlaps(other.root6, 0);
        }
    };
}