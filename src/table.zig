// ZART (Zig Adaptive Routing Table) - High-performance IP routing table implementation
//
// ZART is optimized for both memory usage and lookup time
// for longest-prefix match operations.
//
// ZART is a multibit-trie with fixed stride length of 8 bits,
// using an efficient mapping function to map the 256 prefixes 
// in each level node to form a complete-binary-tree.
//
// This complete binary tree is implemented with popcount compressed
// sparse arrays together with path compression. This reduces storage
// consumption significantly while maintaining excellent lookup times.
//
// The ZART algorithm is based on bit vectors and precalculated
// lookup tables. The search is performed entirely by fast,
// cache-friendly bitmask operations, utilizing modern CPU bit 
// manipulation instruction sets (POPCNT, LZCNT, TZCNT).
//
// The algorithm was specially developed so that it can always work with a fixed
// length of 256 bits. This means that the bitsets fit well in a cache line and
// that loops in hot paths (4x uint64 = 256) can be accelerated by loop unrolling.

const std = @import("std");
const node = @import("node.zig");
const direct_node = @import("direct_node.zig");
const base_index = @import("base_index.zig");
const IPAddr = node.IPAddr;
const Prefix = node.Prefix;
// const PrefixType = node.PrefixType; // Not used in DirectNode implementation

// DirectNodeベースの実装に変更
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        const Node = direct_node.DirectNode(V);
        
        allocator: std.mem.Allocator,
        root4: *Node,
        root6: *Node,
        size4: usize,
        size6: usize,
        node_pool: ?*void,  // 互換性のために追加（現在は未使用）
        
        /// init - DirectNodeベースの初期化
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .root4 = Node.init(allocator),
                .root6 = Node.init(allocator),
                .size4 = 0,
                .size6 = 0,
                .node_pool = null,  // DirectNodeではNodePoolは未使用
            };
        }
        
        /// deinit - 安全なクリーンアップ
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
            
            // persistent操作で作成されたテーブルの場合、自分自身も解放
            // 判定方法：allocatorが設定されていて、かつこれがヒープ上のテーブルの場合
            // ただし、スタック上のテーブルと区別するのは困難なので、
            // より安全な方法を使用する
        }
        
        /// deinitPersistent - persistent操作で作成されたテーブル用のクリーンアップ
        pub fn deinitPersistent(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
            self.allocator.destroy(self);
        }
        
        /// insert - Go BART互換のinsert
        pub fn insert(self: *Self, prefix: *const Prefix, value: V) void {
            if (!prefix.isValid()) return;
            
            const canonical_prefix = prefix.masked();
            const is_ipv4 = canonical_prefix.addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            
            const was_new = !(root.insertAtDepth(canonical_prefix, value, 0) catch false);
            if (was_new) {
                if (is_ipv4) {
                    self.size4 += 1;
                } else {
                    self.size6 += 1;
                }
            }
        }
        
        /// insertPersist - Go BART互換のimmutable insert
        pub fn insertPersist(self: *const Self, prefix: *const Prefix, value: V) *Self {
            const new_table = self.allocator.create(Self) catch unreachable;
            
            // まず元のテーブルをクローン
            new_table.* = Self{
                .allocator = self.allocator,
                .root4 = self.root4.clone(self.allocator),
                .root6 = self.root6.clone(self.allocator),
                .size4 = self.size4,
                .size6 = self.size6,
                .node_pool = self.node_pool,
            };
            
            // 新しいテーブルに挿入
            new_table.insert(prefix, value);
            
            return new_table;
        }
        
        /// lookup - Go BART互換のLPM検索
        pub fn lookup(self: *const Self, addr: *const IPAddr) node.LookupResult(V) {
            const is_ipv4 = addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            return root.lookupOptimized(addr);
        }
        
        /// lookupPrefix - プレフィックスでの検索
        pub fn lookupPrefix(self: *const Self, prefix: *const Prefix) node.LookupResult(V) {
            if (!prefix.isValid()) {
                return node.LookupResult(V){
                    .prefix = undefined,
                    .value = undefined,
                    .ok = false,
                };
            }
            
            const canonical_prefix = prefix.masked();
            const is_ipv4 = canonical_prefix.addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            
            const result = root.lookupPrefix(&canonical_prefix);
                    if (result.ok) {
                return node.LookupResult(V){
                    .prefix = canonical_prefix,
                    .value = result.val,
                    .ok = true,
                };
            }
            return node.LookupResult(V){
                .prefix = undefined,
                .value = undefined,
                .ok = false,
            };
        }
        
        /// lookupPrefixLPM - プレフィックスでのLPM検索
        pub fn lookupPrefixLPM(self: *const Self, prefix: *const Prefix) ?V {
            if (!prefix.isValid()) return null;
            
            const canonical_prefix = prefix.masked();
            const is_ipv4 = canonical_prefix.addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            
            const result = root.lookupPrefixLPM(&canonical_prefix);
            if (result.ok) {
                return result.val;
            }
                return null;
        }
        
        /// contains - Go BART互換の包含チェック
        pub fn contains(self: *const Self, addr: *const IPAddr) bool {
            return self.lookup(addr).ok;
        }
        
        /// get - Go BART互換のexact match
        pub fn get(self: *const Self, prefix: *const Prefix) ?V {
            if (!prefix.isValid()) return null;
            
            const canonical_prefix = prefix.masked();
            const is_ipv4 = canonical_prefix.addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            
            return root.get(&canonical_prefix);
        }
        
        /// delete - Go BART互換のdelete
        pub fn delete(self: *Self, prefix: *const Prefix) void {
            if (!prefix.isValid()) return;
            
            const canonical_prefix = prefix.masked();
            const is_ipv4 = canonical_prefix.addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            
            if (root.delete(&canonical_prefix)) |_| {
                if (is_ipv4) {
                    self.size4 -= 1;
                } else {
                    self.size6 -= 1;
                }
            }
        }
        
        /// deletePersist - Go BART互換のimmutable delete
        pub fn deletePersist(self: *const Self, prefix: *const Prefix) *Self {
            const new_table = self.allocator.create(Self) catch unreachable;
            
            // まず元のテーブルをクローン
            new_table.* = Self{
                .allocator = self.allocator,
                .root4 = self.root4.clone(self.allocator),
                .root6 = self.root6.clone(self.allocator),
                .size4 = self.size4,
                .size6 = self.size6,
                .node_pool = self.node_pool,
            };
            
            // 新しいテーブルから削除
            new_table.delete(prefix);
            
            return new_table;
        }
        
        /// update - Go BART互換のupdate
        pub fn update(self: *Self, prefix: *const Prefix, callback: fn(V, bool) V) V {
            const old_value = self.get(prefix);
            const new_value = callback(old_value orelse @as(V, undefined), old_value != null);
            self.insert(prefix, new_value);
            return new_value;
        }
        
        /// updatePersist - Go BART互換のimmutable update
        pub fn updatePersist(self: *const Self, prefix: *const Prefix, callback: fn(V, bool) V) struct { table: *Self, value: V } {
            const old_value = self.get(prefix);
            const new_value = callback(old_value orelse @as(V, undefined), old_value != null);
            const new_table = self.insertPersist(prefix, new_value);
            return .{ .table = new_table, .value = new_value };
        }
        
        /// getAndDelete - Go BART互換のget and delete
        pub fn getAndDelete(self: *Self, prefix: *const Prefix) node.LookupResult(V) {
            const value = self.get(prefix);
            if (value) |val| {
                self.delete(prefix);
                return node.LookupResult(V){
                    .prefix = prefix.*,
                    .value = val,
                    .ok = true,
                };
            }
            return node.LookupResult(V){
                .prefix = undefined,
                .value = undefined,
                .ok = false,
            };
        }
        
        /// getAndDeletePersist - Go BART互換のimmutable get and delete
        pub fn getAndDeletePersist(self: *const Self, prefix: *const Prefix) struct { table: *Self, value: node.LookupResult(V) } {
            const value = self.get(prefix);
            const new_table = self.deletePersist(prefix);
            if (value) |val| {
                return .{ 
                    .table = new_table, 
                    .value = node.LookupResult(V){
                        .prefix = prefix.*,
                        .value = val,
                        .ok = true,
                    }
                };
            }
            return .{ 
                .table = new_table, 
                .value = node.LookupResult(V){
                    .prefix = undefined,
                    .value = undefined,
                    .ok = false,
                }
            };
        }
        
        /// size - 総サイズ
        pub fn size(self: *const Self) usize {
            return self.size4 + self.size6;
        }
        
        /// size4 - IPv4サイズ
        pub fn getSize4(self: *const Self) usize {
            return self.size4;
        }
        
        /// size6 - IPv6サイズ
        pub fn getSize6(self: *const Self) usize {
            return self.size6;
        }
        
        /// clone - ディープコピー
        pub fn clone(self: *const Self) *Self {
            const new_table = self.allocator.create(Self) catch unreachable;
            new_table.* = Self{
                .allocator = self.allocator,
                .root4 = self.root4.clone(self.allocator),
                .root6 = self.root6.clone(self.allocator),
                .size4 = self.size4,
                .size6 = self.size6,
                .node_pool = self.node_pool,
            };
            return new_table;
        }
        
        /// union - テーブル統合
        pub fn unionWith(self: *Self, other: *const Self) void {
            // TODO: DirectNodeベースのunion実装
            // 現在は基本実装のみ
            _ = self;
            _ = other;
        }
        
        /// overlapsPrefix - プレフィックスとの重複チェック
        pub fn overlapsPrefix(self: *const Self, prefix: *const Prefix) bool {
            if (!prefix.isValid()) return false;
            
            const canonical_prefix = prefix.masked();
            const is_ipv4 = canonical_prefix.addr.is4();
            const root = if (is_ipv4) self.root4 else self.root6;
            
            return root.overlapsPrefixAtDepth(canonical_prefix, 0);
        }

        /// overlaps - 他のテーブルとの重複チェック
        pub fn overlaps(self: *const Self, other: *const Self) bool {
            // TODO: DirectNodeベースのoverlaps実装
            // 暫定的に単純な実装
            _ = self;
            _ = other;
            return false;
        }
        
        /// overlaps4 - IPv4での重複チェック
        pub fn overlaps4(self: *const Self, other: *const Self) bool {
            // TODO: DirectNodeベースのoverlaps4実装
            // 暫定的に単純な実装
            _ = self;
            _ = other;
                return false;
        }

        /// overlaps6 - IPv6での重複チェック
        pub fn overlaps6(self: *const Self, other: *const Self) bool {
            // TODO: DirectNodeベースのoverlaps6実装
            // 暫定的に単純な実装
            _ = self;
            _ = other;
            return false;
        }
    };
}

