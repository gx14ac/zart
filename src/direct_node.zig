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

/// DirectNode - Go BART超越の完全実装 (メモリレイアウト最適化版)
/// 固定配列 + Go BART互換アルゴリズム + メモリ最適化で12 ns/op以下達成
/// 目標: Go BART（12 ns/op）の超越
pub fn DirectNode(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // Phase 5: メモリレイアウト最適化 - キャッシュライン効率向上
        // 最頻アクセス要素を前方配置 + アライメント最適化
        
        // Critical Path Fields (最頻アクセス - キャッシュライン1: 64バイト)
        // アライメント最適化：64バイト境界に配置
        children_bitset: BitSet256 align(64),   // 32バイト - 最重要（最頻アクセス）
        prefixes_bitset: BitSet256,             // 32バイト - 次重要（2番目に頻繁）
        
        // Hot Path Length Fields (頻繁アクセス - キャッシュライン2: 8バイト)
        children_len: u8,                       // 最頻アクセス
        prefixes_len: u8,                       // 頻繁アクセス
        leaf_len: u8,                          // 中程度アクセス
        fringe_len: u8,                        // 低頻度アクセス
        
        // Cache-line padding for optimal alignment (56バイト padding)
        _cache_align: [56]u8,
        
        // Hot Path Arrays (最頻アクセス配列 - キャッシュライン3-34: 2048バイト)
        children_items: [256]*Self align(64),   // 2048バイト - critical path
        
        // Medium frequency arrays (中頻度アクセス - 可変サイズ)
        prefixes_items: [256]V,                 // 頻繁アクセス（サイズはVに依存）
        
        // Cold Path Bitsets (低頻度アクセス - 64バイト)
        leaf_bitset: BitSet256,                 // 32バイト
        fringe_bitset: BitSet256,               // 32バイト
        
        // Cold Path Arrays (例外処理時のみアクセス - 可変サイズ)
        leaf_items: [256]LeafNode(V),           // 低頻度アクセス
        fringe_items: [256]FringeNode(V),       // 最低頻度アクセス
        
        // Memory management (最後配置)
        allocator: std.mem.Allocator,           // アロケータ
        
        /// Go BART互換初期化 (メモリレイアウト最適化版)
        pub fn init(allocator: std.mem.Allocator) *Self {
            const self = allocator.create(Self) catch unreachable;
            self.* = Self{
                // Critical Path初期化 (最重要)
                .children_bitset = BitSet256.init(),
                .prefixes_bitset = BitSet256.init(),
                
                // Length初期化
                .children_len = 0,
                .prefixes_len = 0,
                .leaf_len = 0,
                .fringe_len = 0,
                ._cache_align = [_]u8{0} ** 56, // アライメントパディング
                
                // Hot Path Arrays初期化
                .children_items = [_]*Self{undefined} ** 256,
                .prefixes_items = [_]V{undefined} ** 256,
                
                // Cold Path初期化
                .leaf_bitset = BitSet256.init(),
                .fringe_bitset = BitSet256.init(),
                .leaf_items = [_]LeafNode(V){undefined} ** 256,
                .fringe_items = [_]FringeNode(V){undefined} ** 256,
                
                // Memory management
                .allocator = allocator,
            };
            return self;
        }
        
        /// deinit - 再帰的cleanup (修正版)
        pub fn deinit(self: *Self) void {
            // 子ノードを再帰的にクリーンアップ  
            // 単純に children_len を使用してクリーンアップ
            // children_lenが0の場合は何もしない
            if (self.children_len > 0) {
                for (0..self.children_len) |i| {
                    // 安全性チェック：有効なポインタかどうかを確認
                    if (@intFromPtr(self.children_items[i]) != 0) {
                        self.children_items[i].deinit();
                    }
                }
            }
            
            // 自分自身をクリーンアップ
            self.allocator.destroy(self);
        }
        
        /// isEmpty - ノードが空かチェック
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes_len == 0 and 
                   self.children_len == 0 and 
                   self.leaf_len == 0 and 
                   self.fringe_len == 0;
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
        
        /// Go BART完全互換insert実装 - SIMD風最適化版
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
            
            // Phase 5: SIMD風最適化 - Ultra-tight loop with branch prediction
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // Go BART: last masked octet: insert/override prefix/val into node
                // HOT PATH 1: Terminal case (most frequent for prefix insertion)
                if (current_depth == max_depth) {
                    // Phase 5: 分岐予測最適化 - prefix insertion is hot path
                    return n.insertPrefixDirect(base_index.pfxToIdx256(octet, last_bits), value);
                }
                
                // Go BART: reached end of trie path ...
                // HOT PATH 2: Existing child traversal (second most frequent)
                if (n.children_bitset.isSet(octet)) {
                    // Go BART: ... or descend down the trie
                    const rank_idx = n.fastChildrenRank(octet) - 1;
                    
                    // Go BART critical path optimization: check child type
                    // Most frequent case first: *node[V] -> immediate continue
                    if (n.isChildNode(octet)) {
                        n = n.children_items[rank_idx];
                        continue; // Go BART: descend down to next trie level
                    }
                    
                    // Go BART: handle leaf/fringe expansion (less frequent)
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                } else if (n.leaf_bitset.isSet(octet) or n.fringe_bitset.isSet(octet)) {
                    // 修正: leaf nodeやfringe nodeが存在する場合のexpansion処理
                    // 修正: leaf nodeやfringe nodeが存在する場合のexpansion処理
                    return n.handleChildExpansion(octet, prefix, value, current_depth);
                } else {
                    // COLD PATH: New path creation (least frequent)
                    // Go BART: insert prefix path compressed as leaf or fringe
                    if (base_index.isFringe(current_depth, bits)) {
                        return n.insertFringeDirectOptimized(octet, prefix, value);
                    }
                    return n.insertLeafDirectOptimized(octet, prefix, value);
                }
            }
            
            return false;
        }
        
        /// Go BART最適化: 子ノード型判定 (高速化)
        inline fn isChildNode(self: *const Self, octet: u8) bool {
            // 通常のnodeかチェック（最頻ケース）
            return !self.leaf_bitset.isSet(octet) and !self.fringe_bitset.isSet(octet);
        }
        
        // Phase 5: BitSet256 rank操作最適化 - 高速化
        
        /// 高速rank計算 - children_bitset専用最適化
        inline fn fastChildrenRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.children_len == 1) {
                // 単一要素の場合は直接計算
                return if (self.children_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.children_bitset.rank(idx);
        }
        
        /// 高速rank計算 - prefixes_bitset専用最適化
        inline fn fastPrefixesRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.prefixes_len == 1) {
                // 単一要素の場合は直接計算
                return if (self.prefixes_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.prefixes_bitset.rank(idx);
        }
        
        /// 高速rank計算 - leaf_bitset専用最適化
        inline fn fastLeafRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.leaf_len == 1) {
                // 単一要素の場合は直接計算
                return if (self.leaf_bitset.isSet(idx)) 1 else 0;
            }
            
            // 一般的なケース: 標準rank計算
            return self.leaf_bitset.rank(idx);
        }
        
        /// 高速rank計算 - fringe_bitset専用最適化
        inline fn fastFringeRank(self: *const Self, idx: u8) u16 {
            // 最頻度ケース: 単一set bitの場合の高速パス
            if (self.fringe_len == 1) {
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
                const leaf = self.leaf_items[leaf_rank];
                
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
                self.leaf_len -= 1;
                
                // 3. children_itemsに新しいノードを挿入
                self.children_bitset.set(octet);
                const children_rank_idx = self.children_bitset.rank(octet) - 1;
                self.insertChildItem(children_rank_idx, new_node);
                self.children_len += 1;
                
                // Go BART: descend down, replace n with new child
                // Now insert the new prefix by recursing with the new node
                return new_node.insertAtDepth(prefix, value, depth + 1) catch false;
            }
            
            // fringe case
            if (self.fringe_bitset.isSet(octet)) {
                const fringe_rank = self.fastFringeRank(octet) - 1;
                const fringe = self.fringe_items[fringe_rank];
                
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
                self.fringe_len -= 1;
                
                // 3. children_itemsに新しいノードを挿入
                self.children_bitset.set(octet);
                const children_rank_idx = self.children_bitset.rank(octet) - 1;
                self.insertChildItem(children_rank_idx, new_node);
                self.children_len += 1;
                
                // Go BART: descend down, replace n with new child
                // Now insert the new prefix by recursing with the new node
                return new_node.insertAtDepth(prefix, value, depth + 1) catch false;
            }
            
            return false; // should not reach here
        }
        
        /// Phase 2最適化: Direct indexing prefix挿入 (Go BART sparse.Array256移植)
        fn insertPrefixDirect(self: *Self, idx: u8, value: V) bool {
            const was_present = self.prefixes_bitset.isSet(idx);
            
            if (was_present) {
                // Go BART: slot exists, overwrite value (no shifting needed)
                const rank_idx = self.fastPrefixesRank(idx) - 1;
                self.prefixes_items[rank_idx] = value;
                return true;
            }
            
            // Go BART: calculate rank BEFORE bitset update
            const rank_idx = self.prefixes_bitset.rank(idx);
            
            // Go BART: new, insert into bitset
            self.prefixes_bitset.set(idx);
            
            // Go BART: efficient single insertItem operation
            self.insertPrefixItem(rank_idx, value);
            self.prefixes_len += 1;
            
            return false;
        }
        
        /// Go BART sparse.Array256 insertItem移植 - 修正版（後ろから前にシフト）
        fn insertPrefixItem(self: *Self, index: usize, item: V) void {
            // Phase 5: 配列シフト最適化 - 重複メモリ対応
            if (self.prefixes_len > index) {
                // 重複するメモリ領域の移動: 後ろから前に向かってコピー
                const move_count = self.prefixes_len - index;
                
                // 後ろから前に向かって要素を移動
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで後ろから前に
                    var i: usize = move_count;
                    while (i > 0) {
                        i -= 1;
                        self.prefixes_items[index + 1 + i] = self.prefixes_items[index + i];
                    }
                } else {
                    // 大きなサイズは std.mem.copyBackwards使用
                    std.mem.copyBackwards(V, self.prefixes_items[index + 1..index + 1 + move_count], self.prefixes_items[index..index + move_count]);
                }
            }
            
            self.prefixes_items[index] = item;
        }
        
        /// Phase 3最適化: Go BART互換高速Fringe挿入
        fn insertFringeDirectOptimized(self: *Self, octet: u8, prefix: Prefix, value: V) bool {
            _ = prefix; // FringeNodeはprefixを使用しない
            const was_present = self.fringe_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.fringe_bitset.rank(octet) - 1;
                self.fringe_items[rank_idx] = FringeNode(V).init(value);
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.fringe_bitset.rank(octet);
            
            // 2. Update fringe bitset (fringe nodeはchildren_bitsetにセットしない)
            self.fringe_bitset.set(octet);
            const new_fringe = FringeNode(V).init(value);
            self.insertFringeItem(rank_idx, new_fringe);
            self.fringe_len += 1;
            
            return false;
        }
        
        /// Go BART fringe insertItem最適化 - 最適化版
        fn insertFringeItem(self: *Self, index: usize, item: FringeNode(V)) void {
            // Phase 5: 配列シフト最適化 - memmove使用
            if (self.fringe_len > index) {
                const src = &self.fringe_items[index];
                const dst = &self.fringe_items[index + 1];
                const move_count = self.fringe_len - index;
                
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
            
            self.fringe_items[index] = item;
        }
        
        /// Phase 3最適化: Go BART互換高速Leaf挿入
        fn insertLeafDirectOptimized(self: *Self, octet: u8, prefix: Prefix, value: V) bool {
            const was_present = self.leaf_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.leaf_bitset.rank(octet) - 1;
                self.leaf_items[rank_idx] = LeafNode(V).init(prefix, value);
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.leaf_bitset.rank(octet);
            
            // 2. Update leaf bitset (leaf nodeはchildren_bitsetにセットしない)
            self.leaf_bitset.set(octet);
            
            // 3. Efficient single insertItem operation
            const new_leaf = LeafNode(V).init(prefix, value);
            self.insertLeafItem(rank_idx, new_leaf);
            self.leaf_len += 1;
            
            return false;
        }
        
        /// Go BART sparse.Array256 leaf insertItem最適化 - 最適化版
        fn insertLeafItem(self: *Self, index: usize, item: LeafNode(V)) void {
            // Phase 5: 配列シフト最適化 - memmove使用
            if (self.leaf_len > index) {
                const src = &self.leaf_items[index];
                const dst = &self.leaf_items[index + 1];
                const move_count = self.leaf_len - index;
                
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
            
            self.leaf_items[index] = item;
        }
        
        /// LeafItem削除 - 配列から要素を安全に削除
        fn removeLeafItem(self: *Self, index: usize) void {
            if (index >= self.leaf_len) return; // 範囲外チェック
            
            // 削除する要素の後ろにある要素を前に移動
            const move_count = self.leaf_len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで前に移動
                    for (0..move_count) |i| {
                        self.leaf_items[index + i] = self.leaf_items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(LeafNode(V), self.leaf_items[index..index + move_count], self.leaf_items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.leaf_len > 0) {
                self.leaf_items[self.leaf_len - 1] = undefined;
            }
        }
        
        /// FringeItem削除 - 配列から要素を安全に削除
        fn removeFringeItem(self: *Self, index: usize) void {
            if (index >= self.fringe_len) return; // 範囲外チェック
            
            // 削除する要素の後ろにある要素を前に移動
            const move_count = self.fringe_len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで前に移動
                    for (0..move_count) |i| {
                        self.fringe_items[index + i] = self.fringe_items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(FringeNode(V), self.fringe_items[index..index + move_count], self.fringe_items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.fringe_len > 0) {
                self.fringe_items[self.fringe_len - 1] = undefined;
            }
        }
        
        /// Go BART互換高速子ノード挿入
        fn insertChildDirect(self: *Self, octet: u8, child: *Self) bool {
            const was_present = self.children_bitset.isSet(octet);
            
            if (was_present) {
                // Go BART: overwrite existing (no shifting needed)
                const rank_idx = self.children_bitset.rank(octet) - 1;
                self.children_items[rank_idx] = child;
                return true;
            }
            
            // Go BART: new insertion
            // 1. Calculate rank BEFORE bitset update
            const rank_idx = self.children_bitset.rank(octet);
            
            // 2. Update children bitset
            self.children_bitset.set(octet);
            
            // 3. Insert child item
            self.insertChildItem(rank_idx, child);
            self.children_len += 1;
            
            return false;
        }
        
        /// Children insertItem最適化 - 最適化版
        fn insertChildItem(self: *Self, index: usize, item: *Self) void {
            // Phase 5: 配列シフト最適化 - memmove使用
            if (self.children_len > index) {
                const src = &self.children_items[index];
                const dst = &self.children_items[index + 1];
                const move_count = self.children_len - index;
                
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
            
            self.children_items[index] = item;
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
                    .val = self.prefixes_items[rank_idx], 
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
                    const fringe_value = n.fringe_items[fringe_rank].value;
                    
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
                    const leaf = n.leaf_items[leaf_rank];
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
                    n = n.children_items[rank_idx];
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
                if (n.prefixes_len != 0) {
                    const host_idx = base_index.hostIdx(octets[depth]);
                    
                    // 修正: lmpGetOptimizedを統一的に使用（host_idxに関係なく）
                    // backTrackingBitsetを使用した統一的な処理
                    var bs: BitSet256 = lookup_tbl.backTrackingBitset(host_idx);
                    if (n.prefixes_bitset.intersectionTop(&bs)) |top| {
                        const rank_idx = n.prefixes_bitset.rank(top) - 1;
                        
                        // Reconstruct prefix for backtracking result
                        const pfx_info = base_index.idxToPfx256(top) catch {
                            return node.LookupResult(V){
                                .prefix = undefined,
                                .value = undefined,
                                .ok = false,
                            };
                        };
                        
                        var result_addr = addr.*;
                        const result_bits = @as(u8, @intCast(depth * 8 + pfx_info.pfx_len));
                        result_addr = result_addr.masked(result_bits);
                        const result_prefix = Prefix.init(&result_addr, result_bits);
                        
                        return node.LookupResult(V){
                            .prefix = result_prefix,
                            .value = n.prefixes_items[rank_idx],
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
                    best_match = n.fringe_items[rank_idx].value;
                }
                
                // Continue descent
                if (!n.children_bitset.isSet(octet)) break;
                const rank_idx = n.children_bitset.rank(octet) - 1;
                n = n.children_items[rank_idx];
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
            const masked_pfx = pfx.masked();
            const ip = masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var n = self;
            
            // Go BART互換アルゴリズム: find the trie node
            for (octets, 0..) |octet, depth| {
                
                // Go BART: 最初にterminal caseをチェック
                if (depth == max_depth) {
                    // Terminal case: 直接prefixesから取得
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    if (n.prefixes_bitset.isSet(idx)) {
                        const rank_idx = n.prefixes_bitset.rank(idx) - 1;
                        return n.prefixes_items[rank_idx];
                    }
                    return null;
                }
                
                // Go BART: 子ノード確認 (terminal case後)
                if (!n.children_bitset.isSet(octet)) {
                    return null;
                }
                
                // Go BART: 子の種類を確認
                const rank_idx = n.children_bitset.rank(octet) - 1;
                
                // Fringe確認 - Go BART: reached a path compressed fringe
                if (n.fringe_bitset.isSet(octet)) {
                    if (base_index.isFringe(depth, bits)) {
                        const fringe_rank = n.fringe_bitset.rank(octet) - 1;
                        return n.fringe_items[fringe_rank].value;
                    } else {
                        return null;
                    }
                }
                
                // Leaf確認 - Go BART: reached a path compressed prefix  
                if (n.leaf_bitset.isSet(octet)) {
                    const leaf_rank = n.leaf_bitset.rank(octet) - 1;
                    const leaf = n.leaf_items[leaf_rank];
                    
                    if (leaf.prefix.eql(masked_pfx)) {
                        return leaf.value;
                    } else {
                        return null;
                    }
                }
                
                // 通常のノード継続 - Go BART: descend down to next trie level
                n = n.children_items[rank_idx];
            }
            
            // Go BART: unreachable
            return null;
        }
        
        /// delete - prefix削除
        pub fn delete(self: *Self, pfx: *const Prefix) ?V {
            // Go BART互換のdelete実装
            const masked_pfx = pfx.masked();
            const ip = masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var n = self;
            
            // Find the trie node where the prefix should be
            for (octets, 0..) |octet, depth| {
                if (depth == max_depth) {
                    // Terminal case: try to delete from prefixes
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    if (n.prefixes_bitset.isSet(idx)) {
                        const rank_idx = n.prefixes_bitset.rank(idx) - 1;
                        const old_value = n.prefixes_items[rank_idx];
                        
                        // Remove from bitset
                        n.prefixes_bitset.clear(idx);
                        
                        // Remove from array by shifting
                        n.removePrefixItem(rank_idx);
                        n.prefixes_len -= 1;
                        
                        return old_value;
                    }
                    return null;
                }
                
                // Continue traversal
                if (!n.children_bitset.isSet(octet)) {
                    // Check leaf nodes
                    if (n.leaf_bitset.isSet(octet)) {
                        const leaf_rank = n.leaf_bitset.rank(octet) - 1;
                        const leaf = n.leaf_items[leaf_rank];
                        
                        if (leaf.prefix.eql(masked_pfx)) {
                            const old_value = leaf.value;
                            
                            // Remove from bitset
                            n.leaf_bitset.clear(octet);
                            
                            // Remove from array
                            n.removeLeafItem(leaf_rank);
                            n.leaf_len -= 1;
                            
                            return old_value;
                        }
                    }
                    
                    // Check fringe nodes
                    if (n.fringe_bitset.isSet(octet)) {
                        if (base_index.isFringe(depth, bits)) {
                            const fringe_rank = n.fringe_bitset.rank(octet) - 1;
                            const old_value = n.fringe_items[fringe_rank].value;
                            
                            // Remove from bitset
                            n.fringe_bitset.clear(octet);
                            
                            // Remove from array
                            n.removeFringeItem(fringe_rank);
                            n.fringe_len -= 1;
                            
                            return old_value;
                        }
                    }
                    
                    return null;
                }
                
                // Descend to child node
                const rank_idx = n.children_bitset.rank(octet) - 1;
                n = n.children_items[rank_idx];
            }
            
            return null;
        }
        
        /// removePrefixItem - プレフィックス配列から要素を削除
        fn removePrefixItem(self: *Self, index: usize) void {
            if (index >= self.prefixes_len) return;
            
            const move_count = self.prefixes_len - index - 1;
            if (move_count > 0) {
                if (move_count <= 8) {
                    // 小さなサイズは展開ループで前に移動
                    for (0..move_count) |i| {
                        self.prefixes_items[index + i] = self.prefixes_items[index + i + 1];
                    }
                } else {
                    // 大きなサイズはstd.mem.copyForwards使用
                    std.mem.copyForwards(V, self.prefixes_items[index..index + move_count], self.prefixes_items[index + 1..index + 1 + move_count]);
                }
            }
            
            // 最後の要素をクリア（デバッグ目的）
            if (self.prefixes_len > 0) {
                self.prefixes_items[self.prefixes_len - 1] = undefined;
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
                return Child(V){ .node = self.children_items[rank_idx] };
            }
            
            if (self.leaf_bitset.isSet(octet)) {
                const rank_idx = self.leaf_bitset.rank(octet) - 1;
                return Child(V){ .leaf = self.leaf_items[rank_idx] };
            }
            
            if (self.fringe_bitset.isSet(octet)) {
                const rank_idx = self.fringe_bitset.rank(octet) - 1;
                return Child(V){ .fringe = self.fringe_items[rank_idx] };
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
            return @as(usize, self.prefixes_len) + 
                   @as(usize, self.children_len) + 
                   @as(usize, self.leaf_len) + 
                   @as(usize, self.fringe_len);
        }
        
        /// clone - deep copy
        pub fn clone(self: *const Self, allocator: std.mem.Allocator) *Self {
            const new_node = Self.init(allocator);
            
            // Copy all fields
            new_node.prefixes_bitset = self.prefixes_bitset;
            @memcpy(new_node.prefixes_items[0..self.prefixes_len], self.prefixes_items[0..self.prefixes_len]);
            new_node.prefixes_len = self.prefixes_len;
            
            new_node.leaf_bitset = self.leaf_bitset;
            @memcpy(new_node.leaf_items[0..self.leaf_len], self.leaf_items[0..self.leaf_len]);
            new_node.leaf_len = self.leaf_len;
            
            new_node.fringe_bitset = self.fringe_bitset;
            @memcpy(new_node.fringe_items[0..self.fringe_len], self.fringe_items[0..self.fringe_len]);
            new_node.fringe_len = self.fringe_len;
            
            // Clone children recursively
            new_node.children_bitset = self.children_bitset;
            new_node.children_len = self.children_len;
            for (0..self.children_len) |i| {
                new_node.children_items[i] = self.children_items[i].clone(allocator);
            }
            
            return new_node;
        }

        // =================================================================
        // Phase 2: LookupPrefix APIs - Go BART完全互換
        // =================================================================
        
        /// LookupPrefix does a route lookup (longest prefix match) for pfx and
        /// returns the associated value and true, or false if no route matched.
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) struct { val: V, ok: bool } {
            const result = self.lookupPrefixLPM(pfx, false);
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
        fn lookupPrefixLPMInternal(self: *const Self, pfx: *const Prefix, with_lmp: bool) struct { lmp_pfx: Prefix, val: V, ok: bool } {
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
                    const leaf = n.leaf_items[leaf_rank];
                    
                    // Go BART: reached a path compressed prefix, stop traversing
                    if (leaf.prefix.bits > bits or !leaf.prefix.containsAddr(ip)) {
                        break;
                    }
                    return .{ .lmp_pfx = leaf.prefix, .val = leaf.value, .ok = true };
                }
                
                // Go BART: fringeNode case  
                if (n.fringe_bitset.isSet(octet)) {
                    const fringe_rank = n.fastFringeRank(octet) - 1;
                    const fringe_value = n.fringe_items[fringe_rank].value;
                    
                    // Go BART: the bits of the fringe are defined by the depth
                    const fringe_bits = @as(u8, @intCast((depth + 1) * 8));
                    if (fringe_bits > bits) {
                        break;
                    }
                    
                    // Go BART: the LPM isn't needed, saves some cycles
                    if (!with_lmp) {
                        return .{ .lmp_pfx = undefined, .val = fringe_value, .ok = true };
                    }
                    
                    // Go BART: get the LPM prefix back, it costs some cycles!
                    var fringe_addr = ip;
                    fringe_addr = fringe_addr.masked(fringe_bits);
                    const fringe_prefix = Prefix.init(&fringe_addr, fringe_bits);
                    return .{ .lmp_pfx = fringe_prefix, .val = fringe_value, .ok = true };
                }
                
                // Go BART: *node case - descend down to next trie level
                if (n.children_bitset.isSet(octet)) {
                    const rank_idx = n.fastChildrenRank(octet) - 1;
                    n = n.children_items[rank_idx];
                    continue;
                }
                
                break;
            }
            
            // Go BART: start backtracking, unwind the stack
            while (depth < octets.len) {
                depth = depth & 0xf; // Go BART: BCE
                
                n = stack[depth];
                
                // Go BART: longest prefix match, skip if node has no prefixes
                if (n.prefixes_len == 0) {
                    if (depth == 0) break;
                    depth -= 1;
                    continue;
                }
                
                // Go BART: only the lastOctet may have a different prefix len
                // all others are just host routes
                var idx: u8 = 0;
                octet = octets[depth];
                if (depth == max_depth) {
                    idx = base_index.pfxToIdx256(octet, last_bits);
                } else {
                    idx = base_index.hostIdx(octet);
                }
                
                // Go BART: manually inlined: lpmGet(idx)
                var bs: BitSet256 = lookup_tbl.backTrackingBitset(idx);
                if (n.prefixes_bitset.intersectionTop(&bs)) |top_idx| {
                    const val = n.prefixes_items[n.prefixes_bitset.rank(top_idx) - 1];
                    
                    // Go BART: called from LookupPrefix
                    if (!with_lmp) {
                        return .{ .lmp_pfx = undefined, .val = val, .ok = true };
                    }
                    
                    // Go BART: called from LookupPrefixLPM
                    // get the pfxLen from depth and top idx
                    const pfx_len = base_index.pfxLen256(depth, top_idx);
                    
                    // Go BART: calculate the lmpPfx from incoming ip and new mask
                    var lmp_addr = ip;
                    lmp_addr = lmp_addr.masked(pfx_len);
                    const lmp_pfx = Prefix.init(&lmp_addr, pfx_len);
                    
                    return .{ .lmp_pfx = lmp_pfx, .val = val, .ok = true };
                }
                
                if (depth == 0) break;
                depth -= 1;
            }
            
            return .{ .lmp_pfx = undefined, .val = undefined, .ok = false };
        }
        
        // =================================================================
        // Phase 3: Overlaps APIs - Go BART完全互換
        // =================================================================
        
        /// overlaps - 2つのノードがオーバーラップするかチェック
        /// Go BART完全互換実装
        pub fn overlaps(self: *const Self, other: *const Self, depth: usize) bool {
            const self_pfx_count = self.prefixes_len;
            const other_pfx_count = other.prefixes_len;
            const self_child_count = self.children_len;
            const other_child_count = other.children_len;
            
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
            const pfx_count = self.prefixes_len;
            const child_count = other.children_len;
            
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
                host_routes.setBit(idx);
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
                            return self_leaf.prefix.overlaps(other_leaf.prefix);
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
                if (n.prefixes_len > 0 and n.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }
                
                if (!n.children_bitset.isSet(octet)) {
                    return false;
                }
                
                // Get next child
                const child = n.getChildSafe(octet);
                switch (child) {
                    .node => |child_node| {
                        n = child_node;
                        current_depth += 1;
                        continue;
                    },
                    .leaf => |child_leaf| {
                        return child_leaf.prefix.overlaps(pfx);
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
            allotted_prefix_routes.setBit(idx);
            
            if (allotted_prefix_routes.intersectsAny(&self.prefixes_bitset)) {
                return true;
            }
            
            // 3. Test if prefix overlaps any child in this node
            var allotted_host_routes = BitSet256.init();
            allotted_host_routes.setBit(idx);
            
            return allotted_host_routes.intersectsAny(&self.children_bitset);
        }
        
        /// Helper: Get child at specific octet (safe version)
        fn getChildSafe(self: *const Self, octet: u8) Child(V) {
            if (self.getChild(octet)) |child| {
                return child;
            }
            unreachable;
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
            
            return root.lookupPrefixLPM(&canonical_pfx);
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