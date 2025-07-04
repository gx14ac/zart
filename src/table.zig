// Package bart provides a Balanced-Routing-Table (BART).
//
// BART is balanced in terms of memory usage and lookup time
// for the longest-prefix match.
//
// BART is a multibit-trie with fixed stride length of 8 bits,
// using a fast mapping function (taken from the ART algorithm) to map
// the 256 prefixes in each level node to form a complete-binary-tree.
//
// This complete binary tree is implemented with popcount compressed
// sparse arrays together with path compression. This reduces storage
// consumption by almost two orders of magnitude in comparison to ART,
// with even better lookup times for the longest prefix match.
//
// The BART algorithm is based on bit vectors and precalculated
// lookup tables. The search is performed entirely by fast,
// cache-friendly bitmask operations, which in modern CPUs are performed
// by advanced bit manipulation instruction sets (POPCNT, LZCNT, TZCNT).
//
// The algorithm was specially developed so that it can always work with a fixed
// length of 256 bits. This means that the bitsets fit well in a cache line and
// that loops in hot paths (4x uint64 = 256) can be accelerated by loop unrolling.

const std = @import("std");
const Node = @import("node.zig").Node;
const Prefix = @import("node.zig").Prefix;
const IPAddr = @import("node.zig").IPAddr;
const Child = @import("node.zig").Child;
const LeafNode = @import("node.zig").LeafNode;
const FringeNode = @import("node.zig").FringeNode;
const base_index = @import("base_index.zig");

/// Table is an IPv4 and IPv6 routing table with payload V.
/// The zero value is ready to use.
///
/// The Table is safe for concurrent readers but not for concurrent readers
/// and/or writers. Either the update operations must be protected by an
/// external lock mechanism or the various ...Persist functions must be used
/// which return a modified routing table by leaving the original unchanged
///
/// A Table must not be copied by value.
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        
        /// the root nodes, implemented as popcount compressed multibit tries
        root4: Node(V),
        root6: Node(V),
        
        /// the number of prefixes in the routing table
        size4: usize,
        size6: usize,
        
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .root4 = Node(V).init(allocator),
                .root6 = Node(V).init(allocator),
                .size4 = 0,
                .size6 = 0,
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
        }
        
        /// rootNodeByVersion, root node getter for ip version.
        fn rootNodeByVersion(self: *Self, is4: bool) *Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }
        
        /// rootNodeByVersionConst, root node getter for ip version (const version).
        fn rootNodeByVersionConst(self: *const Self, is4: bool) *const Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }
        
        /// Insert adds a pfx to the tree, with given val.
        /// If pfx is already present in the tree, its value is set to val.
        pub fn insert(self: *Self, pfx: *const Prefix, val: V) void {
            if (!pfx.isValid()) {
                return;
            }
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            var n: *Node(V) = self.rootNodeByVersion(is4);
            if (n.insertAtDepth(&canonical_pfx, val, 0, self.allocator)) {
                self.sizeUpdate(is4, 1);
            }
        }
        
        /// InsertPersist is similar to Insert but the receiver isn't modified.
        /// All nodes touched during insert are cloned and a new Table is returned.
        /// This is not a full Clone, all untouched nodes are still referenced from both Tables.
        pub fn insertPersist(self: *const Self, pfx: *const Prefix, val: V) *Self {
            if (!pfx.isValid()) {
                const new_table = self.allocator.create(Self) catch unreachable;
                new_table.* = self.*;
                return new_table;
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            
            // 新しいテーブルを作成
            const pt = self.allocator.create(Self) catch unreachable;
            pt.* = Self{
                .root4 = self.root4,
                .root6 = self.root6,
                .size4 = self.size4,
                .size6 = self.size6,
                .allocator = self.allocator,
            };
            
            // 挿入パスのルートをクローン
            const root_node = pt.rootNodeByVersion(is4);
            root_node.* = root_node.cloneFlat(self.allocator).*;
            
            // 挿入パスに沿ってノードをクローン
            if (root_node.insertAtDepthPersist(&canonical_pfx, val, 0, self.allocator)) {
                // プレフィックスが既に存在していた場合、サイズは増加しない
                return pt;
            }
            
            // 新規挿入の場合、サイズを更新
            pt.sizeUpdate(is4, 1);
            return pt;
        }
        
        /// Update or set the value at pfx with a callback function.
        /// The callback function is called with (value, ok) and returns a new value.
        ///
        /// If the pfx does not already exist, it is set with the new value.
        pub fn update(self: *Self, pfx: *const Prefix, cb: fn (V, bool) V) V {
            if (!pfx.isValid()) {
                return cb(undefined, false);
            }
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const n = self.rootNodeByVersion(is4);
            const result = n.update(&canonical_pfx, cb);
            if (!result.was_present) {
                self.sizeUpdate(is4, 1);
            }
            return result.value;
        }
        
        /// UpdatePersist is similar to Update but the receiver isn't modified.
        /// All nodes touched during update are cloned and a new Table is returned.
        pub fn updatePersist(self: *const Self, pfx: *const Prefix, cb: fn (V, bool) V) struct { table: *Self, value: V } {
            if (!pfx.isValid()) {
                const new_table = self.allocator.create(Self) catch unreachable;
                new_table.* = self.*;
                return .{ .table = new_table, .value = cb(undefined, false) };
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            
            // 新しいテーブルを作成
            const pt = self.allocator.create(Self) catch unreachable;
            pt.* = Self{
                .root4 = self.root4,
                .root6 = self.root6,
                .size4 = self.size4,
                .size6 = self.size6,
                .allocator = self.allocator,
            };
            
            // 更新パスのルートをクローン
            const root_node = pt.rootNodeByVersion(is4);
            root_node.* = root_node.cloneFlat(self.allocator).*;
            
            // 更新パスに沿ってノードをクローンしながら更新
            const result = root_node.updateAtDepthPersist(&canonical_pfx, cb, 0, self.allocator);
            
            if (!result.was_present) {
                // 新規挿入の場合、サイズを更新
                pt.sizeUpdate(is4, 1);
            }
            
            return .{ .table = pt, .value = result.value };
        }
        
        /// Delete removes a pfx from the tree.
        pub fn delete(self: *Self, pfx: *const Prefix) void {
            _ = self.getAndDelete(pfx);
        }
        
        /// DeletePersist is similar to Delete but the receiver isn't modified.
        /// All nodes touched during delete are cloned and a new Table is returned.
        pub fn deletePersist(self: *const Self, pfx: *const Prefix) *Self {
            const result = self.getAndDeletePersist(pfx);
            return result.table;
        }
        
        /// GetAndDelete deletes the prefix and returns the associated value
        pub fn getAndDelete(self: *Self, pfx: *const Prefix) struct { value: V, ok: bool } {
            if (!pfx.isValid()) {
                return .{ .value = undefined, .ok = false };
            }
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const n = self.rootNodeByVersion(is4);
            if (n.delete(&canonical_pfx)) |val| {
                self.sizeUpdate(is4, -1);
                return .{ .value = val, .ok = true };
            }
            return .{ .value = undefined, .ok = false };
        }
        
        /// GetAndDeletePersist is similar to GetAndDelete but the receiver isn't modified.
        /// All nodes touched during delete are cloned and a new Table is returned.
        pub fn getAndDeletePersist(self: *const Self, pfx: *const Prefix) struct { table: *Self, value: V, ok: bool } {
            if (!pfx.isValid()) {
                const new_table = self.allocator.create(Self) catch unreachable;
                new_table.* = self.*;
                return .{ .table = new_table, .value = undefined, .ok = false };
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            
            // 新しいテーブルを作成
            const pt = self.allocator.create(Self) catch unreachable;
            pt.* = Self{
                .root4 = self.root4,
                .root6 = self.root6,
                .size4 = self.size4,
                .size6 = self.size6,
                .allocator = self.allocator,
            };
            
            // 削除パスのルートをクローン
            const root_node = pt.rootNodeByVersion(is4);
            root_node.* = root_node.cloneFlat(self.allocator).*;
            
            // 削除パスに沿ってノードをクローンしながら削除
            const result = root_node.deleteAtDepthPersist(&canonical_pfx, 0, self.allocator);
            
            if (result.ok) {
                // 削除成功の場合、サイズを更新
                pt.sizeUpdate(is4, -1);
            }
            
            return .{ .table = pt, .value = result.value, .ok = result.ok };
        }
        
        /// Get returns the value associated with the prefix
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const n = self.rootNodeByVersionConst(is4);
            return n.get(&canonical_pfx);
        }
        
        /// Contains tests if ip is contained in any prefix in the table.
        pub fn contains(self: *const Self, pfx: *const Prefix) bool {
            if (!pfx.isValid()) {
                return false;
            }
            const ip = &pfx.addr;
            const is4 = ip.is4();
            const root_node = self.rootNodeByVersionConst(is4);
            return root_node.contains(pfx);
        }
        
        /// Lookup performs longest prefix matching for the given prefix
        pub fn lookup(self: *const Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }
            const ip = &pfx.addr;
            const is4 = ip.is4();
            const root_node = self.rootNodeByVersionConst(is4);
            return root_node.lookup(pfx);
        }
        
        /// LookupPrefixLPM: プレフィックス自体のLPM検索
        /// 与えられたPrefixがテーブルに存在すればその値を返し、なければbitsを1ずつ減らして上位のLPMを探索
        pub fn lookupPrefixLPM(self: *const Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }
            var search_bits: u8 = pfx.bits;
            var candidate: ?V = null;
            var tmp_pfx = pfx.*;
            while (search_bits > 0) {
                tmp_pfx.bits = search_bits;
                candidate = self.get(&tmp_pfx);
                if (candidate != null) {
                    return candidate;
                }
                search_bits -= 1;
            }
            // /0（デフォルトルート）もチェック
            tmp_pfx.bits = 0;
            return self.get(&tmp_pfx);
        }
        
        /// Supernets: 指定プレフィックスの上位ネットワーク検索
        /// 指定したプレフィックスより短い（上位の）ネットワークで、テーブルに存在するものをすべて列挙
        pub fn supernets(self: *const Self, pfx: *const Prefix, allocator: std.mem.Allocator) !std.ArrayList(Prefix) {
            var result = std.ArrayList(Prefix).init(allocator);
            if (!pfx.isValid()) {
                return result;
            }
            
            const canonical_pfx = pfx.masked();
            var search_bits: u8 = canonical_pfx.bits;
            
            // bitsを1ずつ減らしながら上位ネットワークを検索（自身は含めない）
            while (search_bits > 0) {
                search_bits -= 1;
                if (search_bits == 0) break; // /0はループ外で一度だけ追加
                var tmp_pfx = canonical_pfx;
                tmp_pfx.bits = search_bits;
                tmp_pfx.addr = canonical_pfx.addr.masked(search_bits);
                if (!tmp_pfx.eql(canonical_pfx) and self.get(&tmp_pfx) != null) {
                    try result.append(tmp_pfx);
                }
            }
            // /0（デフォルトルート）もチェック（重複を避けて一度だけ）
            var zero_pfx = canonical_pfx;
            zero_pfx.bits = 0;
            zero_pfx.addr = canonical_pfx.addr.masked(0);
            if (self.get(&zero_pfx) != null) {
                try result.append(zero_pfx);
            }
            return result;
        }
        
        /// Subnets: 指定プレフィックスの下位ネットワーク検索
        /// 指定したプレフィックスより長い（下位の）ネットワークで、テーブルに存在するものをすべて列挙
        pub fn subnets(self: *const Self, pfx: *const Prefix, allocator: std.mem.Allocator) !std.ArrayList(Prefix) {
            var result = std.ArrayList(Prefix).init(allocator);
            if (!pfx.isValid()) {
                return result;
            }
            const canonical_pfx = pfx.masked();
            const ip = &canonical_pfx.addr;
            const is4 = ip.is4();
            var node = self.rootNodeByVersionConst(is4);
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(canonical_pfx.bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(canonical_pfx.bits).last_bits;
            
            // pfxまでノードをたどる
            var depth: usize = 0;
            while (depth < max_depth) : (depth += 1) {
                var octet: u8 = 0;
                if (depth < octets.len) {
                    octet = octets[depth];
                }
                if (!node.children.isSet(octet)) {
                    return result;
                }
                const kid = node.children.mustGet(octet);
                switch (kid) {
                    .node => |n| node = n,
                    .leaf => |leaf| {
                        // leafノードの場合、プレフィックスが下位ネットワークかチェック
                        if (leaf.prefix.bits > canonical_pfx.bits and canonical_pfx.containsAddr(leaf.prefix.addr)) {
                            try result.append(leaf.prefix);
                        }
                        return result;
                    },
                    .fringe => {
                        // fringeノードの場合、プレフィックスを再構築してチェック
                        const fringe_pfx = self.cidrForFringe(octets, depth, is4, octet);
                        if (fringe_pfx.bits > canonical_pfx.bits and canonical_pfx.containsAddr(fringe_pfx.addr)) {
                            try result.append(fringe_pfx);
                        }
                        return result;
                    },
                }
            }
            
            // max_depthに到達した場合、そのノードで下位ネットワークを列挙
            const octet = if (depth < octets.len) octets[depth] else 0;
            const idx = base_index.pfxToIdx256(octet, last_bits);
            try self.eachSubnet(octets, depth, is4, idx, last_bits, &result);
            return result;
        }
        
        /// eachSubnet: GoのeachSubnetメソッドを参考にした下位ネットワーク列挙
        fn eachSubnet(self: *const Self, octets: []const u8, depth: usize, is4: bool, pfx_idx: u8, last_bits: u8, result: *std.ArrayList(Prefix)) !void {
            // パスをコピー
            var path: [16]u8 = undefined;
            @memcpy(path[0..octets.len], octets);
            
            // 親プレフィックスの範囲を取得
            const pfx_range = try base_index.idxToRange256(pfx_idx);
            const pfx_first_addr = pfx_range.first;
            const pfx_last_addr = pfx_range.last;
            
            // 1. 範囲内のプレフィックスインデックスを収集
            var covered_indices = std.ArrayList(u8).init(self.allocator);
            defer covered_indices.deinit();
            
            var node = self.rootNodeByVersionConst(is4);
            var d: usize = 0;
            while (d < depth) : (d += 1) {
                const octet = if (d < octets.len) octets[d] else 0;
                if (!node.children.isSet(octet)) {
                    return;
                }
                const kid = node.children.mustGet(octet);
                switch (kid) {
                    .node => |n| node = n,
                    else => return,
                }
            }
            
            // 現在のノードのプレフィックスをチェック
            var i: usize = 1;
            while (i <= 255) : (i += 1) {
                const idx = std.math.cast(u8, i) orelse break;
                if (node.prefixes.isSet(idx)) {
                    const this_range = base_index.idxToRange256(idx) catch continue;
                    const this_first_addr = this_range.first;
                    const this_last_addr = this_range.last;
                    
                    // 親プレフィックスの範囲内にあるかチェック
                    if (this_first_addr >= pfx_first_addr and this_last_addr <= pfx_last_addr) {
                        try covered_indices.append(idx);
                    }
                }
            }
            
            // 2. 範囲内の子ノードアドレスを収集
            var covered_child_addrs = std.ArrayList(u8).init(self.allocator);
            defer covered_child_addrs.deinit();
            
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const addr = std.math.cast(u8, j) orelse break;
                if (node.children.isSet(addr)) {
                    if (addr >= pfx_first_addr and addr <= pfx_last_addr) {
                        try covered_child_addrs.append(addr);
                    }
                }
            }
            
            // 3. プレフィックスと子ノードをCIDR順で列挙
            for (covered_indices.items) |idx| {
                const cidr = self.cidrFromPath(&path, depth, is4, idx);
                // 親プレフィックスより長い（下位の）ネットワークのみ追加
                const parent_bits = @as(u8, @intCast(depth * 8 + last_bits));
                if (cidr.bits > parent_bits) {
                    try result.append(cidr);
                }
            }
            
            // 4. 子ノードを再帰的に探索
            for (covered_child_addrs.items) |addr| {
                const child = node.children.mustGet(addr);
                switch (child) {
                    .node => |child_node| {
                        path[depth] = addr;
                        try self.allRecSorted(child_node, &path, depth + 1, is4, result);
                    },
                    .leaf => |leaf| {
                        try result.append(leaf.prefix);
                    },
                    .fringe => {
                        const fringe_pfx = self.cidrForFringe(octets, depth, is4, addr);
                        try result.append(fringe_pfx);
                    },
                }
            }
        }

        /// cidrFromPath: パスとインデックスからCIDRを再構築
        fn cidrFromPath(_: *const Self, path: *[16]u8, depth: usize, is4: bool, idx: u8) Prefix {
            const pfx_info = base_index.idxToPfx256(idx) catch unreachable;
            
            // パスのdepth位置にオクテットを設定
            path[depth] = pfx_info.octet;
            
            // depth+1以降のバイトを0にクリア
            var i = depth + 1;
            while (i < path.len) : (i += 1) {
                path[i] = 0;
            }
            
            // IPアドレスを作成
            var addr = if (is4) IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } else IPAddr{ .v6 = path[0..16].* };
            
            // ビット数を計算
            const bits = @as(u8, @intCast(depth * 8 + pfx_info.pfx_len));
            
            return Prefix.init(&addr, bits);
        }

        /// cidrForFringe: fringeノードのプレフィックスを再構築
        fn cidrForFringe(_: *const Self, octets: []const u8, depth: usize, is4: bool, last_octet: u8) Prefix {
            var path: [16]u8 = undefined;
            @memcpy(path[0..octets.len], octets);
            path[depth] = last_octet;
            
            // IPアドレスを作成
            var addr = if (is4) IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } else IPAddr{ .v6 = path[0..16].* };
            
            // fringeのビット数は常に /8, /16, /24, ...
            const bits = @as(u8, @intCast((depth + 1) * 8));
            
            return Prefix.init(&addr, bits);
        }

        /// allRecSorted: 再帰的にすべてのプレフィックスをソート順で収集
        fn allRecSorted(self: *const Self, node: *const Node(V), path: *[16]u8, depth: usize, is4: bool, result: *std.ArrayList(Prefix)) !void {
            // 現在のノードのプレフィックスを収集
            var i: usize = 1;
            while (i <= 255) : (i += 1) {
                const idx = std.math.cast(u8, i) orelse break;
                if (node.prefixes.isSet(idx)) {
                    const cidr = self.cidrFromPath(path, depth, is4, idx);
                    try result.append(cidr);
                }
            }
            
            // 子ノードを再帰的に探索
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const addr = std.math.cast(u8, j) orelse break;
                if (node.children.isSet(addr)) {
                    const child = node.children.mustGet(addr);
                    switch (child) {
                        .node => |child_node| {
                            path[depth] = addr;
                            try self.allRecSorted(child_node, path, depth + 1, is4, result);
                        },
                        .leaf => |leaf| {
                            try result.append(leaf.prefix);
                        },
                        .fringe => {
                            const fringe_pfx = self.cidrForFringe(path[0..depth], depth, is4, addr);
                            try result.append(fringe_pfx);
                        },
                    }
                }
            }
        }
        
        /// Size returns the total number of prefixes in the table.
        pub fn size(self: *const Self) usize {
            return self.size4 + self.size6;
        }
        
        /// Size4 returns the number of IPv4 prefixes in the table.
        pub fn getSize4(self: *const Self) usize {
            return self.size4;
        }
        
        /// Size6 returns the number of IPv6 prefixes in the table.
        pub fn getSize6(self: *const Self) usize {
            return self.size6;
        }
        
        /// sizeUpdate updates the size counters
        fn sizeUpdate(self: *Self, is4: bool, delta: i32) void {
            if (is4) {
                self.size4 = @intCast(@as(i32, @intCast(self.size4)) + delta);
            } else {
                self.size6 = @intCast(@as(i32, @intCast(self.size6)) + delta);
            }
        }
        
        /// Clone returns a complete copy of the routing table.
        /// This is a deep clone operation where all nodes are recursively cloned.
        pub fn clone(self: *const Self) *Self {
            const new_table = self.allocator.create(Self) catch unreachable;
            new_table.* = Self{
                .root4 = if (self.root4) |r4| r4.cloneRec(self.allocator) else null,
                .root6 = if (self.root6) |r6| r6.cloneRec(self.allocator) else null,
                .size4 = self.size4,
                .size6 = self.size6,
                .allocator = self.allocator,
            };
            return new_table;
        }
    };
}

/// isFringe, leaves with /8, /16, ... /128 bits at special positions
/// in the trie.
///
/// Just a path-compressed leaf, inserted at the last
/// possible level as path compressed (depth == maxDepth-1)
/// before inserted just as a prefix in the next level down (depth == maxDepth).
///
/// Nice side effect: A fringe is the default-route for all nodes below this slot!
///
///     e.g. prefix is addr/8, or addr/16, or ... addr/128
///     depth <  maxDepth-1 : a leaf, path-compressed
///     depth == maxDepth-1 : a fringe, path-compressed
///     depth == maxDepth   : a prefix with octet/pfx == 0/0 => idx == 1, a strides default route
fn isFringe(depth: usize, bits: u8) bool {
    const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
    return depth == max_depth - 1;
}

test "Table lookupPrefixLPM basic" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト用のプレフィックスを作成
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 0, 0, 0 } }, 8);
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0);
    
    // プレフィックスを挿入
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    table.insert(&pfx4, 4);
    
    // テスト1: 存在するプレフィックスを検索
    const result1 = table.lookupPrefixLPM(&pfx1);
    try std.testing.expectEqual(@as(u32, 1), result1.?);
    
    // テスト2: 存在しないプレフィックスを検索（上位のLPMを返す）
    const search_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 128 } }, 25);
    const result2 = table.lookupPrefixLPM(&search_pfx);
    try std.testing.expectEqual(@as(u32, 1), result2.?); // pfx1 (192.168.1.0/24) が返される
    
    // テスト3: より短いプレフィックスを検索
    const search_pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);
    const result3 = table.lookupPrefixLPM(&search_pfx2);
    try std.testing.expectEqual(@as(u32, 2), result3.?); // pfx2 (192.168.0.0/16) が返される
    
    // テスト4: デフォルトルートを検索
    const search_pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const result4 = table.lookupPrefixLPM(&search_pfx3);
    try std.testing.expectEqual(@as(u32, 4), result4.?); // pfx4 (0.0.0.0/0) が返される
}

test "Table lookupPrefixLPM edge cases" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト1: 空のテーブルで検索
    const pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const result = table.lookupPrefixLPM(&pfx);
    try std.testing.expect(result == null);
    
    // テスト2: 無効なプレフィックスで検索
    const invalid_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 33); // IPv4で33ビットは無効
    const result2 = table.lookupPrefixLPM(&invalid_pfx);
    try std.testing.expect(result2 == null);
    
    // テスト3: /0のみが存在する場合
    const default_pfx = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0);
    table.insert(&default_pfx, 42);
    
    const search_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const result3 = table.lookupPrefixLPM(&search_pfx);
    try std.testing.expectEqual(@as(u32, 42), result3.?);
}

test "Table supernets basic" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト用のプレフィックスを作成
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 0, 0, 0 } }, 8);
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0);
    
    // プレフィックスを挿入
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    table.insert(&pfx4, 4);
    
    // 192.168.1.0/24のsupernetsを検索
    const search_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const supernets = try table.supernets(&search_pfx, allocator);
    defer supernets.deinit();
    
    // デバッグ出力
    std.debug.print("Supernets found: {}\n", .{supernets.items.len});
    for (supernets.items, 0..) |supernet, i| {
        std.debug.print("  {}: {s}\n", .{i, supernet});
    }
    
    // 結果を検証（192.168.0.0/16, 192.0.0.0/8, 0.0.0.0/0 の3つが期待される）
    try std.testing.expectEqual(@as(usize, 3), supernets.items.len);
    
    // 結果をソートして検証（順序は不定のため）
    var found_16 = false;
    var found_8 = false;
    var found_0 = false;
    
    for (supernets.items) |supernet| {
        if (supernet.bits == 16) found_16 = true;
        if (supernet.bits == 8) found_8 = true;
        if (supernet.bits == 0) found_0 = true;
    }
    
    try std.testing.expect(found_16);
    try std.testing.expect(found_8);
    try std.testing.expect(found_0);
}

test "Table subnets basic" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト用のプレフィックスを作成（より簡単なケース）
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);
    
    // プレフィックスを挿入
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    
    // 192.168.0.0/16のsubnetsを検索
    const search_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);
    const subnets = try table.subnets(&search_pfx, allocator);
    defer subnets.deinit();
    

    
    // 結果を検証（2個が返るはず）
    try std.testing.expectEqual(@as(usize, 2), subnets.items.len);
    
    var found_1 = false;
    var found_2 = false;
    for (subnets.items) |subnet| {
        if (subnet.bits == 24) {
            if (subnet.addr.eql(IPAddr{ .v4 = .{ 192, 168, 1, 0 } })) found_1 = true;
            if (subnet.addr.eql(IPAddr{ .v4 = .{ 192, 168, 2, 0 } })) found_2 = true;
        }
    }
    try std.testing.expect(found_1);
    try std.testing.expect(found_2);
} 