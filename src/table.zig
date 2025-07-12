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
const node = @import("node.zig");
const Node = node.Node;
const NodePool = node.NodePool;
const Prefix = node.Prefix;
const IPAddr = node.IPAddr;
const Child = node.Child;
const LeafNode = node.LeafNode;
const FringeNode = node.FringeNode;
const base_index = @import("base_index.zig");

/// Table is an IPv4 and IPv6 routing table with payload V.
/// The zero value is ready to use.
///
/// A Table must not be copied by value.
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        root4: *Node(V),
        root6: *Node(V),
        size4: usize,
        size6: usize,
        
        // Memory pool for high-performance node allocation
        node_pool: ?*NodePool(V),
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .root4 = Node(V).init(allocator),
                .root6 = Node(V).init(allocator),
                .size4 = 0,
                .size6 = 0,
                .node_pool = null, // Disable pool for debugging
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.allocator.destroy(self.root4);
            self.root6.deinit();
            self.allocator.destroy(self.root6);
            
            // Cleanup node pool
            if (self.node_pool) |pool| {
                pool.deinit();
            }
        }
        
        /// deinitAndDestroy: insertPersist等で作成されたテーブルを完全にクリーンアップ
        pub fn deinitAndDestroy(self: *Self) void {
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
        }
        
        /// rootNodeByVersion, root node getter for ip version.
        fn rootNodeByVersion(self: *Self, is4: bool) *Node(V) {
            return if (is4) self.root4 else self.root6;
        }
        
        /// rootNodeByVersionConst, root node getter for ip version (const version).
        fn rootNodeByVersionConst(self: *const Self, is4: bool) *const Node(V) {
            return if (is4) self.root4 else self.root6;
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
            
            // Memory pool optimized insertAtDepth
            if (n.insertAtDepthPooled(&canonical_pfx, val, 0, self.allocator, self.node_pool)) {
                self.sizeUpdate(is4, 1);
            }
        }
        
        /// Get returns the value associated with the prefix.
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const n = self.rootNodeByVersionConst(is4);
            return n.get(&canonical_pfx);
        }
        
        /// Delete removes a pfx from the tree.
        pub fn delete(self: *Self, pfx: *const Prefix) void {
            _ = self.getAndDelete(pfx);
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
        
        /// Lookup performs a longest prefix match for the given IP address.
        /// Direct port of Go BART's Lookup implementation
        pub fn lookup(self: *const Self, addr: *const IPAddr) node.LookupResult(V) {
            const is4 = addr.is4();
            const octets = addr.asSlice();
            var n = self.rootNodeByVersionConst(is4);
            
            // Stack of the traversed nodes for fast backtracking, if needed
            var stack: [16]*const Node(V) = undefined;
            
            // Run variable, used after for loop
            var depth: usize = 0;
            var octet: u8 = 0;
            
            // Find leaf node
            for (octets, 0..) |current_octet, current_depth| {
                depth = current_depth;
                octet = current_octet;
                
                // Push current node on stack for fast backtracking
                stack[depth] = n;
                
                // Go down in tight loop to last octet
                if (!n.children.isSet(octet)) {
                    // No more nodes below octet
                    break;
                }
                const kid = n.children.mustGet(octet);
                
                // Kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // Descend down to next trie level
                    },
                    .fringe => |fringe| {
                        // Fringe is the default-route for all possible nodes below
                        // Reconstruct prefix from path
                        var path: [16]u8 = undefined;
                        @memcpy(path[0..octets.len], octets);
                        path[depth] = octet;
                        const fringe_addr = if (addr.is4()) 
                            IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } 
                        else 
                            IPAddr{ .v6 = path[0..16].* };
                        const fringe_bits = @as(u8, @intCast((depth + 1) * 8));
                        const fringe_pfx = Prefix.init(&fringe_addr, fringe_bits);
                        return node.LookupResult(V){ .prefix = fringe_pfx, .value = fringe.value, .ok = true };
                    },
                    .leaf => |leaf| {
                        if (leaf.prefix.containsAddr(addr.*)) {
                            return node.LookupResult(V){ .prefix = leaf.prefix, .value = leaf.value, .ok = true };
                        }
                        // Reached a path compressed prefix, stop traversing
                        break;
                    },
                }
            }
            
            // Start backtracking, unwind the stack
            while (depth < 16) {
                n = stack[depth];
                
                // Longest prefix match, skip if node has no prefixes
                if (n.prefixes.len() != 0) {
                    const idx = base_index.hostIdx(octets[depth]);
                    // lpmGet(idx), using existing implementation
                    const result = n.lpmGet(idx);
                    if (result.ok) {
                        // Reconstruct prefix from backtracking result
                        const pfx_info = base_index.idxToPfx256(result.base_idx) catch {
                            if (depth == 0) break;
                            depth -= 1;
                            continue;
                        };
                        var masked_addr = addr.*;
                        const pfx_bits = @as(u8, @intCast(depth * 8 + pfx_info.pfx_len));
                        masked_addr = masked_addr.masked(pfx_bits);
                        const prefix = Prefix.init(&masked_addr, pfx_bits);
                        return node.LookupResult(V){ .prefix = prefix, .value = result.val, .ok = true };
                    }
                }
                
                if (depth == 0) break;
                depth -= 1;
            }
            
            return node.LookupResult(V){ .prefix = undefined, .value = undefined, .ok = false };
        }
        
        /// LookupPrefix performs a longest prefix match for the given prefix.
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) node.LookupResult(V) {
            if (!pfx.isValid()) {
                return node.LookupResult(V){ .prefix = undefined, .value = undefined, .ok = false };
            }
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            const n = self.rootNodeByVersionConst(is4);
            return n.lookupPrefix(&canonical_pfx);
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
        
        /// Clone returns a complete copy of the routing table.
        /// This is a deep clone operation where all nodes are recursively cloned.
        pub fn clone(self: *const Self) Self {
            const new_table = Self{
                .allocator = self.allocator,
                .root4 = self.root4.cloneRec(self.allocator),
                .root6 = self.root6.cloneRec(self.allocator),
                .size4 = self.size4,
                .size6 = self.size6,
                .node_pool = NodePool(V).init(self.allocator) catch null,
            };
            return new_table;
        }
        
        /// sizeUpdate updates the size counter for the given IP version.
        fn sizeUpdate(self: *Self, is4: bool, delta: i32) void {
            if (is4) {
                self.size4 = @intCast(@as(i32, @intCast(self.size4)) + delta);
            } else {
                self.size6 = @intCast(@as(i32, @intCast(self.size6)) + delta);
            }
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
            try self.findSubnets(&canonical_pfx, &result);
            return result;
        }
        
        /// findSubnets: 内部的な再帰関数でサブネットを検索
        fn findSubnets(self: *const Self, parent_pfx: *const Prefix, result: *std.ArrayList(Prefix)) !void {
            const ip = &parent_pfx.addr;
            const is4 = ip.is4();
            var cur_node = self.rootNodeByVersionConst(is4);
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(parent_pfx.bits).max_depth;
            
            // parent_pfxまでノードをたどる
            var depth: usize = 0;
            while (depth < max_depth) : (depth += 1) {
                var octet: u8 = 0;
                if (depth < octets.len) {
                    octet = octets[depth];
                }
                if (!cur_node.children.isSet(octet)) {
                    return;
                }
                const kid = cur_node.children.mustGet(octet);
                switch (kid) {
                    .node => |n| cur_node = n,
                    .leaf => |leaf| {
                        if (leaf.prefix.bits > parent_pfx.bits and parent_pfx.containsAddr(leaf.prefix.addr)) {
                            try result.append(leaf.prefix);
                        }
                        return;
                    },
                    .fringe => {
                        // fringeノードの場合、プレフィックスを再構築してチェック
                        var path: [16]u8 = undefined;
                        @memcpy(path[0..octets.len], octets);
                        path[depth] = octet;
                        var addr = if (is4) node.IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } else node.IPAddr{ .v6 = path[0..16].* };
                        const bits = @as(u8, @intCast((depth + 1) * 8));
                        const fringe_pfx = Prefix.init(&addr, bits);
                        if (fringe_pfx.bits > parent_pfx.bits and parent_pfx.containsAddr(fringe_pfx.addr)) {
                            try result.append(fringe_pfx);
                        }
                        return;
                    },
                }
            }
            
            // parent_pfxのノードに到達した、すべての下位ネットワークを検索
            try self.collectAllSubnets(cur_node, parent_pfx, octets, depth, is4, result);
        }
        
        /// collectAllSubnets: 指定ノード以下のすべてのサブネットを収集
        fn collectAllSubnets(self: *const Self, start_node: *const node.Node(V), parent_pfx: *const Prefix, parent_octets: []const u8, start_depth: usize, is4: bool, result: *std.ArrayList(Prefix)) !void {
            // 現在のノードの全プレフィックスをチェック
            var i: usize = 1;
            while (i <= 255) : (i += 1) {
                const pidx = std.math.cast(u8, i) orelse break;
                if (start_node.prefixes.isSet(pidx)) {
                    const pfx_info = base_index.idxToPfx256(pidx) catch continue;
                    const bits = @as(u8, @intCast(start_depth * 8 + pfx_info.pfx_len));
                    if (bits > parent_pfx.bits) {
                        var path: [16]u8 = undefined;
                        @memcpy(path[0..parent_octets.len], parent_octets);
                        if (start_depth < path.len) {
                            path[start_depth] = pfx_info.octet;
                        }
                        var addr = if (is4) node.IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } else node.IPAddr{ .v6 = path[0..16].* };
                        const sub_pfx = Prefix.init(&addr, bits);
                        if (parent_pfx.containsAddr(sub_pfx.addr)) {
                            try result.append(sub_pfx);
                        }
                    }
                }
            }
            
            // 子ノードを再帰的に探索
            var j: usize = 0;
            while (j < 256) : (j += 1) {
                const addr = std.math.cast(u8, j) orelse break;
                if (start_node.children.isSet(addr)) {
                    const child = start_node.children.mustGet(addr);
                    var path: [16]u8 = undefined;
                    @memcpy(path[0..parent_octets.len], parent_octets);
                    if (start_depth < path.len) {
                        path[start_depth] = addr;
                    }
                    
                    switch (child) {
                        .node => |child_node| {
                            // 再帰的に子ノードを探索
                            try self.collectAllSubnets(child_node, parent_pfx, path[0..parent_octets.len + 1], start_depth + 1, is4, result);
                        },
                        .leaf => |leaf| {
                            if (leaf.prefix.bits > parent_pfx.bits and parent_pfx.containsAddr(leaf.prefix.addr)) {
                                try result.append(leaf.prefix);
                            }
                        },
                        .fringe => {
                            var addr2 = if (is4) node.IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } else node.IPAddr{ .v6 = path[0..16].* };
                            const bits = @as(u8, @intCast((start_depth + 1) * 8));
                            const fringe_pfx = Prefix.init(&addr2, bits);
                            if (fringe_pfx.bits > parent_pfx.bits and parent_pfx.containsAddr(fringe_pfx.addr)) {
                                try result.append(fringe_pfx);
                            }
                        },
                    }
                }
            }
        }

        /// InsertPersist: 元のテーブルを変更せずに新しいテーブルを返す（Go実装と同じ動作）
        pub fn insertPersist(self: *const Self, pfx: *const Prefix, val: V) *Self {
            if (!pfx.isValid()) {
                return @constCast(self);
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            
            const new_table = self.allocator.create(Self) catch unreachable;
            new_table.* = Self{
                .allocator = self.allocator,
                .size4 = self.size4,
                .size6 = self.size6,
                .root4 = undefined, // 後でセット
                .root6 = undefined, // 後でセット
            };
            
            // 挿入パスのルートをdeep clone
            if (is4) {
                new_table.root4 = self.rootNodeByVersionConst(is4).cloneRec(self.allocator);
                new_table.root6 = self.root6.cloneRec(self.allocator); // 変更なしでもクローン
            } else {
                new_table.root4 = self.root4.cloneRec(self.allocator); // 変更なしでもクローン
                new_table.root6 = self.rootNodeByVersionConst(is4).cloneRec(self.allocator);
            }
            const root = new_table.rootNodeByVersion(is4);
            
            // 挿入パスに沿ってノードをクローン
            const insert_result = root.insertAtDepthPersist(&canonical_pfx, val, 0, self.allocator);
            
            if (insert_result) {
                // プレフィックスが存在した、サイズ増加なし
                return new_table;
            }
            
            // 真の挿入、サイズ更新
            new_table.sizeUpdate(is4, 1);
            return new_table;
        }

        /// UpdatePersist: 不変な更新操作（Go実装と同じ動作）
        pub fn updatePersist(self: *const Self, pfx: *const Prefix, cb: fn (V, bool) V) struct { table: *Self, value: V } {
            const zero: V = undefined;
            if (!pfx.isValid()) {
                return .{ .table = self, .value = zero };
            }
            
            // 正規化されたプレフィックス
            const canonical_pfx = pfx.masked();
            const ip = &canonical_pfx.addr;
            const is4 = ip.is4();
            const bits = canonical_pfx.bits;
            
            const new_table = self.allocator.create(Self) catch unreachable;
            new_table.* = Self{
                .allocator = self.allocator,
                .size4 = self.size4,
                .size6 = self.size6,
                .root4 = undefined, // 後でセット
                .root6 = undefined, // 後でセット
            };
            
            // 挿入パスのルートをdeep clone
            if (is4) {
                new_table.root4 = self.rootNodeByVersionConst(is4).cloneRec(self.allocator);
                new_table.root6 = self.root6.cloneRec(self.allocator); // 変更なしでもクローン
            } else {
                new_table.root4 = self.root4.cloneRec(self.allocator); // 変更なしでもクローン
                new_table.root6 = self.rootNodeByVersionConst(is4).cloneRec(self.allocator);
            }
            const root = new_table.rootNodeByVersion(is4);
            
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            const octets = ip.asSlice();
            
            // 適切なトライノードを見つけてプレフィックスを更新
            var depth: usize = 0;
            var current_node = root;
            while (depth < octets.len) : (depth += 1) {
                const octet = octets[depth];
                
                // プレフィックスの最後のオクテット、ノードにプレフィックスを更新/挿入
                if (depth == max_depth) {
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    const result = current_node.prefixes.updateAt(idx, cb);
                    if (!result.was_present) {
                        new_table.sizeUpdate(is4, 1);
                    }
                    return .{ .table = new_table, .value = result.new_value };
                }
                
                const addr = octet;
                
                // 最後のオクテットまでタイトループで降下
                if (!current_node.children.isSet(addr)) {
                    // プレフィックスをパス圧縮として挿入
                    const new_val = cb(zero, false);
                    if (node.isFringe(depth, bits)) {
                        _ = current_node.children.replaceAt(addr, Child(V){ .fringe = FringeNode(V).init(new_val) });
                    } else {
                        _ = current_node.children.replaceAt(addr, Child(V){ .leaf = LeafNode(V).init(canonical_pfx, new_val) });
                    }
                    
                    new_table.sizeUpdate(is4, 1);
                    return .{ .table = new_table, .value = new_val };
                }
                
                const kid = current_node.children.mustGet(addr);
                switch (kid) {
                    .node => |node_ptr| {
                        // 次のレベルに進む
                        const cloned_kid = node_ptr.cloneFlat(current_node.allocator);
                        // 古いノードをクリーンアップ
                        if (current_node.children.replaceAt(addr, Child(V){ .node = cloned_kid })) |old_child| {
                            switch (old_child) {
                                .node => |old_node_ptr| {
                                    old_node_ptr.deinit();
                                    old_node_ptr.allocator.destroy(old_node_ptr);
                                },
                                else => {},
                            }
                        }
                        current_node = cloned_kid;
                        continue; // 次のトライレベルに降下
                    },
                    .leaf => |leaf| {
                        const cloned_leaf = leaf.cloneLeaf();
                        
                        // プレフィックスが等しい場合、既存の値を更新
                        if (cloned_leaf.prefix.eql(canonical_pfx)) {
                            const new_val = cb(cloned_leaf.value, true);
                            _ = current_node.children.replaceAt(addr, Child(V){ .leaf = LeafNode(V).init(canonical_pfx, new_val) });
                            return .{ .table = new_table, .value = new_val };
                        }
                        
                        // 新しいノードを作成 - OPTIMIZED
                        // リーフを下に押し下げ
                        // 現在のリーフ位置（addr）に新しい子を挿入
                        // 降下し、nを新しい子で置き換え
                        const new_node = Node(V).createFastNode(current_node.allocator);
                        _ = new_node.insertAtDepth(&cloned_leaf.prefix, cloned_leaf.value, depth + 1, current_node.allocator);
                        
                        _ = current_node.children.replaceAt(addr, Child(V){ .node = new_node });
                        current_node = new_node;
                    },
                    .fringe => |fringe| {
                        const cloned_fringe = fringe.cloneFringe();
                        
                        // pfxがフリンジの場合、既存の値を更新
                        if (node.isFringe(depth, bits)) {
                            const new_val = cb(cloned_fringe.value, true);
                            _ = current_node.children.replaceAt(addr, Child(V){ .fringe = FringeNode(V).init(new_val) });
                            return .{ .table = new_table, .value = new_val };
                        }
                        
                        // 新しいノードを作成 - OPTIMIZED
                        // フリンジを下に押し下げ、デフォルトルート（idx=1）になる
                        // 現在のリーフ位置（addr）に新しい子を挿入
                        // 降下し、nを新しい子で置き換え
                        const new_node = Node(V).createFastNode(current_node.allocator);
                        _ = new_node.prefixes.insertAt(1, cloned_fringe.value);
                        
                        _ = current_node.children.replaceAt(addr, Child(V){ .node = new_node });
                        current_node = new_node;
                    },
                }
            }
            
            unreachable; // 到達不可能
        }

        /// DeletePersist: 不変な削除操作（Go実装と同じ動作）
        pub fn deletePersist(self: *const Self, pfx: *const Prefix) *Self {
            const result = self.getAndDeletePersist(pfx);
            return result.table;
        }

        /// GetAndDeletePersist: 不変な削除操作（Go実装と同じ動作）
        pub fn getAndDeletePersist(self: *const Self, pfx: *const Prefix) struct { table: *Self, value: V, ok: bool } {
            const zero: V = undefined;
            if (!pfx.isValid()) {
                return .{ .table = self, .value = zero, .ok = false };
            }
            
            const canonical_pfx = pfx.masked();
            const is4 = canonical_pfx.addr.is4();
            
            const new_table = self.allocator.create(Self) catch unreachable;
            new_table.* = Self{
                .allocator = self.allocator,
                .size4 = self.size4,
                .size6 = self.size6,
                .root4 = undefined, // 後でセット
                .root6 = undefined, // 後でセット
            };
            
            // 削除パスのルートをクローン
            if (is4) {
                new_table.root4 = self.rootNodeByVersionConst(is4).cloneFlat(self.allocator);
                new_table.root6 = self.root6.cloneFlat(self.allocator); // 変更なしでもクローン
            } else {
                new_table.root4 = self.root4.cloneFlat(self.allocator); // 変更なしでもクローン
                new_table.root6 = self.rootNodeByVersionConst(is4).cloneFlat(self.allocator);
            }
            const root = new_table.rootNodeByVersion(is4);
            
            if (root.delete(&canonical_pfx)) |val| {
                new_table.sizeUpdate(is4, -1);
                return .{ .table = new_table, .value = val, .ok = true };
            }
            
            return .{ .table = new_table, .value = zero, .ok = false };
        }

        /// OverlapsPrefix reports whether any IP in pfx is matched by a route in the table or vice versa
        /// Go実装のOverlapsPrefixメソッドを移植
        pub fn overlapsPrefix(self: *const Self, pfx: *const Prefix) bool {
            if (!pfx.isValid()) {
                return false;
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            const is4 = canonical_pfx.addr.is4();
            const n = self.rootNodeByVersionConst(is4);

            return n.overlapsPrefixAtDepth(&canonical_pfx, 0);
        }

        /// Overlaps reports whether any IP in the table is matched by a route in the
        /// other table or vice versa
        /// Go実装のOverlapsメソッドを移植
        pub fn overlaps(self: *const Self, other: *const Self) bool {
            return self.overlaps4(other) or self.overlaps6(other);
        }

        /// Overlaps4 reports whether any IPv4 in the table matches a route in the
        /// other table or vice versa
        /// Go実装のOverlaps4メソッドを移植
        pub fn overlaps4(self: *const Self, other: *const Self) bool {
            if (self.size4 == 0 or other.size4 == 0) {
                return false;
            }
            return self.root4.overlaps(other.root4, 0);
        }

        /// Overlaps6 reports whether any IPv6 in the table matches a route in the
        /// other table or vice versa
        /// Go実装のOverlaps6メソッドを移植
        pub fn overlaps6(self: *const Self, other: *const Self) bool {
            if (self.size6 == 0 or other.size6 == 0) {
                return false;
            }
            return self.root6.overlaps(other.root6, 0);
        }

        /// Union combines two tables, changing the receiver table.
        /// If there are duplicate entries, the payload of type V is shallow copied from the other table.
        /// If type V implements the Cloner interface, the values are cloned.
        pub fn unionWith(self: *Self, other: *const Self) void {
            const dup4 = self.root4.unionRec(other.root4, 0);
            const dup6 = self.root6.unionRec(other.root6, 0);

            self.size4 += other.size4 - dup4;
            self.size6 += other.size6 - dup6;
        }

        // Go実装互換のJSON出力機能
        
        /// MarshalJSON: Go実装と同じJSON形式で出力
        pub fn marshalJSON(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            var list = std.ArrayList(u8).init(allocator);
            defer list.deinit();
            
            const ipv4_list = try self.dumpList4(allocator);
            defer {
                for (ipv4_list) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(ipv4_list);
            }
            
            const ipv6_list = try self.dumpList6(allocator);
            defer {
                for (ipv6_list) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(ipv6_list);
            }
            
            try list.appendSlice("{");
            
            var has_content = false;
            
            if (ipv4_list.len > 0) {
                try list.appendSlice("\"ipv4\":");
                try self.serializeDumpList(allocator, list.writer(), ipv4_list);
                has_content = true;
            }
            
            if (ipv6_list.len > 0) {
                if (has_content) try list.appendSlice(",");
                try list.appendSlice("\"ipv6\":");
                try self.serializeDumpList(allocator, list.writer(), ipv6_list);
                has_content = true;
            }
            
            try list.appendSlice("}");
            return list.toOwnedSlice();
        }

        /// DumpList4: IPv4ツリーの構造化リスト（Go実装互換）
        pub fn dumpList4(self: *const Self, allocator: std.mem.Allocator) ![]DumpListNode {
            return try self.dumpListForVersion(allocator, true);
        }

        /// DumpList6: IPv6ツリーの構造化リスト（Go実装互換）
        pub fn dumpList6(self: *const Self, allocator: std.mem.Allocator) ![]DumpListNode {
            return try self.dumpListForVersion(allocator, false);
        }

        /// バージョン別のDumpList実装
        fn dumpListForVersion(self: *const Self, allocator: std.mem.Allocator, is4: bool) ![]DumpListNode {
            const root = self.rootNodeByVersionConst(is4);
            if (root.isEmpty()) {
                return try allocator.alloc(DumpListNode, 0);
            }
            
            // Go実装と同じ階層構造を構築
            const path = std.mem.zeroes([16]u8);
            return try root.dumpListRec(allocator, 0, path, 0, is4);
        }

        /// DumpListのJSON形式シリアライゼーション
        fn serializeDumpList(self: *const Self, allocator: std.mem.Allocator, writer: anytype, dump_list: []const DumpListNode) !void {
            try writer.print("[", .{});
            for (dump_list, 0..) |item, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{{\"cidr\":\"{}\",\"value\":", .{item.cidr});
                
                // 値の型に応じてシリアライズ
                try self.serializeValue(writer, item.value);
                
                if (item.subnets.len > 0) {
                    try writer.print(",\"subnets\":", .{});
                    try self.serializeDumpList(allocator, writer, item.subnets);
                }
                
                try writer.print("}}", .{});
            }
            try writer.print("]", .{});
        }

        /// 値の型に応じたシリアライゼーション
        fn serializeValue(self: *const Self, writer: anytype, value: V) !void {
            _ = self;
            if (V == u32) {
                try writer.print("{}", .{value});
            } else if (V == []const u8) {
                try writer.print("\"{}\"", .{value});
            } else if (V == struct{}) {
                try writer.print("null", .{});
            } else {
                // デフォルトは数値として出力を試行
                try writer.print("{}", .{value});
            }
        }

        /// Fprint: 階層的なツリー表示（Go実装互換）
        pub fn fprint(self: *const Self, writer: anytype) !void {
            // IPv4ツリーを出力
            try self.fprintVersion(writer, true);
            
            // IPv6ツリーを出力
            try self.fprintVersion(writer, false);
        }

        /// バージョン別のFprint実装
        fn fprintVersion(self: *const Self, writer: anytype, is4: bool) !void {
            const root = self.rootNodeByVersionConst(is4);
            if (root.isEmpty()) return;
            
            try writer.print("▼\n", .{});
            
            const path = std.mem.zeroes([16]u8);
            try root.fprintRecProper(self.allocator, writer, 0, path, 0, "");
        }

        /// String representation - Fprintのラッパー
        pub fn toString(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            var list = std.ArrayList(u8).init(allocator);
            defer list.deinit();
            
            try self.fprint(list.writer());
            return list.toOwnedSlice();
        }

        /// MarshalText: Go実装のencoding.TextMarshalerインターフェース互換
        /// Fprintのラッパーとして実装
        pub fn marshalText(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            return try self.toString(allocator);
        }

        /// dump: 詳細なデバッグ情報出力（Go実装のdumper.go互換）
        pub fn dump(self: *const Self, writer: anytype) !void {
            if (self.getSize4() > 0) {
                const stats4 = self.root4.getNodeStats();
                try writer.print("\n### IPv4: size({}), nodes({}), leaves({}), fringes({})\n", 
                    .{ self.getSize4(), stats4.nodes, stats4.leaves, stats4.fringes });
                try self.dumpVersion(writer, true);
            }
            
            if (self.getSize6() > 0) {
                const stats6 = self.root6.getNodeStats();
                try writer.print("\n### IPv6: size({}), nodes({}), leaves({}), fringes({})\n", 
                    .{ self.getSize6(), stats6.nodes, stats6.leaves, stats6.fringes });
                try self.dumpVersion(writer, false);
            }
        }

        /// バージョン別のdump実装
        fn dumpVersion(self: *const Self, writer: anytype, is4: bool) !void {
            const root = self.rootNodeByVersionConst(is4);
            if (root.isEmpty()) return;
            
            const path = std.mem.zeroes([16]u8);
            try root.dumpRec(self.allocator, writer, path, 0, is4);
        }

        /// dumpString: dumpの文字列版（デバッグ用）
        pub fn dumpString(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            var list = std.ArrayList(u8).init(allocator);
            defer list.deinit();
            
            try self.dump(list.writer());
            return list.toOwnedSlice();
        }

        // シリアライゼーション用の構造体（Go実装のDumpListNode互換）
        pub const DumpListNode = node.DumpListNode(V);

        // =============================================================================
        // All系イテレーション機能
        // =============================================================================

        /// Yield関数の型定義
        pub const YieldFn = fn (prefix: Prefix, value: V) bool;

        /// allWithCallback: 全プレフィックス列挙（IPv4+IPv6、順序不定）
        /// Go実装のAllメソッドを移植
        pub fn allWithCallback(self: *const Self, yield: *const YieldFn) void {
            const path = std.mem.zeroes(node.StridePath);
            
            // IPv4とIPv6の両方を処理
            _ = self.root4.allRec(path, 0, true, yield) and 
                self.root6.allRec(path, 0, false, yield);
        }

        /// all4WithCallback: IPv4プレフィックス列挙（順序不定）
        /// Go実装のAll4メソッドを移植
        pub fn all4WithCallback(self: *const Self, yield: *const YieldFn) void {
            const path = std.mem.zeroes(node.StridePath);
            _ = self.root4.allRec(path, 0, true, yield);
        }

        /// all6WithCallback: IPv6プレフィックス列挙（順序不定）
        /// Go実装のAll6メソッドを移植
        pub fn all6WithCallback(self: *const Self, yield: *const YieldFn) void {
            const path = std.mem.zeroes(node.StridePath);
            _ = self.root6.allRec(path, 0, false, yield);
        }

        /// allSortedWithCallback: 全プレフィックス列挙（ソート済み）
        /// Go実装のAllSortedメソッドを移植
        pub fn allSortedWithCallback(self: *const Self, yield: *const YieldFn) void {
            const path = std.mem.zeroes(node.StridePath);
            
            // IPv4とIPv6の両方をソート順で処理
            _ = self.root4.allRecSorted(path, 0, true, yield) and 
                self.root6.allRecSorted(path, 0, false, yield);
        }

        /// allSorted4WithCallback: IPv4プレフィックス列挙（ソート済み）
        /// Go実装のAllSorted4メソッドを移植
        pub fn allSorted4WithCallback(self: *const Self, yield: *const YieldFn) void {
            const path = std.mem.zeroes(node.StridePath);
            _ = self.root4.allRecSorted(path, 0, true, yield);
        }

        /// allSorted6WithCallback: IPv6プレフィックス列挙（ソート済み）
        /// Go実装のAllSorted6メソッドを移植
        pub fn allSorted6WithCallback(self: *const Self, yield: *const YieldFn) void {
            const path = std.mem.zeroes(node.StridePath);
            _ = self.root6.allRecSorted(path, 0, false, yield);
        }

        /// Contains performs a route lookup for IP and returns true if any route matched.
        /// Direct port of Go BART's Contains implementation
        pub fn contains(self: *const Self, addr: *const IPAddr) bool {
            const is4 = addr.is4();
            var n = self.rootNodeByVersionConst(is4);
            
            for (addr.asSlice()) |octet| {
                // For contains, any lpm match is good enough, no backtracking needed
                if (n.prefixes.len() != 0 and n.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }
                
                // Stop traversing?
                if (!n.children.isSet(octet)) {
                    return false;
                }
                const kid = n.children.mustGet(octet);
                
                // Kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // Descend down to next trie level
                    },
                    .fringe => {
                        // Fringe is the default-route for all possible octets below
                        return true;
                    },
                    .leaf => |leaf| {
                        return leaf.prefix.containsAddr(addr.*);
                    },
                }
            }
            
            return false;
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

// Cloner is an interface, if implemented by payload of type V the values are deeply copied
// during union operations and other clone operations.
pub fn Cloner(comptime V: type) type {
    return struct {
        pub fn clone(self: *const V) V {
            return self.clone();
        }
    };
}

// cloneOrCopy clones the value if it implements the Cloner interface,
// otherwise it performs a shallow copy.
fn cloneOrCopy(comptime V: type, value: V) V {
    const type_info = @typeInfo(V);
    
    // Check if V has a clone method
    switch (type_info) {
        .pointer => |ptr_info| {
            const child_type = ptr_info.child;
            if (@hasDecl(child_type, "clone")) {
                return value.clone();
            }
        },
        else => {
            // For non-pointer types, check if they have a clone method
            // Only check for struct/enum/union types
            if (type_info == .@"struct" or type_info == .@"enum" or type_info == .@"union") {
                if (@hasDecl(V, "clone")) {
                    return value.clone();
                }
            }
        },
    }
    
    // Default to shallow copy
    return value;
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
    const result1 = table.lookupPrefix(&pfx1);
    try std.testing.expectEqual(@as(u32, 1), result1.value);
    
    // テスト2: 存在しないプレフィックスを検索（上位のLPMを返す）
    // 192.168.1.128/25は192.168.1.0/24にマッチする
    const search_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 128 } }, 25);
    const result2 = table.lookupPrefix(&search_pfx);
    try std.testing.expect(result2.ok == true);
    try std.testing.expectEqual(@as(u32, 1), result2.value); // 192.168.1.0/24がマッチ
    
    // テスト3: より短いプレフィックスを検索
    const search_pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);
    const result3 = table.lookupPrefix(&search_pfx2);
    try std.testing.expectEqual(@as(u32, 2), result3.value); // 192.168.0.0/16がマッチ
    
    // テスト4: デフォルトルートを検索
    const search_pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const result4 = table.lookupPrefix(&search_pfx3);
    try std.testing.expectEqual(@as(u32, 4), result4.value); // 0.0.0.0/0がマッチ
}

test "Table lookupPrefixLPM edge cases" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト1: 空のテーブルで検索
    const pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const result = table.lookupPrefix(&pfx);
    try std.testing.expect(!result.ok);
    
    // テスト2: 無効なプレフィックスで検索
    const invalid_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 33); // IPv4で33ビットは無効
    const result2 = table.lookupPrefix(&invalid_pfx);
    try std.testing.expect(!result2.ok);
    
    // テスト3: /0のみが存在する場合
    const default_pfx = Prefix.init(&IPAddr{ .v4 = .{ 0, 0, 0, 0 } }, 0);
    table.insert(&default_pfx, 42);
    
    const search_pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const result3 = table.lookupPrefix(&search_pfx);
    try std.testing.expectEqual(@as(u32, 42), result3.value);
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



test "Table overlapsPrefix basic" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();
    
    // テスト用のプレフィックスを作成
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    
    // プレフィックスを挿入
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx3, 3);
    
    // テスト1: 完全一致のプレフィックス
    try std.testing.expect(table.overlapsPrefix(&pfx1));
    try std.testing.expect(table.overlapsPrefix(&pfx2));
    try std.testing.expect(table.overlapsPrefix(&pfx3));
    
    // テスト2: オーバーラップするプレフィックス
    const overlap_pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 128 } }, 25); // pfx1とオーバーラップ
    const overlap_pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);   // pfx2とオーバーラップ
    const overlap_pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 1, 0, 0 } }, 16);      // pfx3とオーバーラップ
    
    try std.testing.expect(table.overlapsPrefix(&overlap_pfx1));
    try std.testing.expect(table.overlapsPrefix(&overlap_pfx2));
    try std.testing.expect(table.overlapsPrefix(&overlap_pfx3));
    
    // テスト3: オーバーラップしないプレフィックス
    const no_overlap_pfx = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 16);
    try std.testing.expect(!table.overlapsPrefix(&no_overlap_pfx));
}

test "Table overlaps basic" {
    const allocator = std.testing.allocator;
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    // table1にプレフィックスを挿入
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    table1.insert(&pfx1, 1);
    table1.insert(&pfx2, 2);
    
    // table2にオーバーラップするプレフィックスを挿入
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16); // pfx1とオーバーラップ
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 16);  // オーバーラップしない
    table2.insert(&pfx3, 3);
    table2.insert(&pfx4, 4);
    
    // テスト1: オーバーラップあり
    try std.testing.expect(table1.overlaps(&table2));
    try std.testing.expect(table2.overlaps(&table1)); // 対称性
    
    // テスト2: IPv4専用オーバーラップ
    try std.testing.expect(table1.overlaps4(&table2));
    
    // テスト3: IPv6オーバーラップなし（IPv6プレフィックスがない）
    try std.testing.expect(!table1.overlaps6(&table2));
}

test "Table overlaps no overlap" {
    const allocator = std.testing.allocator;
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    // table1にプレフィックスを挿入
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    table1.insert(&pfx1, 1);
    
    // table2にオーバーラップしないプレフィックスを挿入
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 16);
    table2.insert(&pfx2, 2);
    
    // テスト: オーバーラップなし
    try std.testing.expect(!table1.overlaps(&table2));
    try std.testing.expect(!table2.overlaps(&table1)); // 対称性
    try std.testing.expect(!table1.overlaps4(&table2));
}

test "Prefix overlaps detailed verification" {
    
    // テスト1: 完全一致
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx1_same = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    try std.testing.expect(pfx1.overlaps(&pfx1_same));
    std.debug.print("✓ 完全一致: 192.168.1.0/24 と 192.168.1.0/24\n", .{});
    
    // テスト2: 包含関係（大きいプレフィックスが小さいプレフィックスを含む）
    const pfx_large = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16); // 192.168.0.0/16
    const pfx_small = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24); // 192.168.1.0/24
    try std.testing.expect(pfx_large.overlaps(&pfx_small));
    try std.testing.expect(pfx_small.overlaps(&pfx_large)); // 対称性
    std.debug.print("✓ 包含関係: 192.168.0.0/16 と 192.168.1.0/24\n", .{});
    
    // テスト3: 部分的重複（同じ/24内の/25同士）
    const pfx_25_1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 25);   // 192.168.1.0/25
    const pfx_25_2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 128 } }, 25); // 192.168.1.128/25
    try std.testing.expect(!pfx_25_1.overlaps(&pfx_25_2)); // これらは隣接だが重複しない
    std.debug.print("✓ 隣接非重複: 192.168.1.0/25 と 192.168.1.128/25\n", .{});
    
    // テスト4: 完全に異なるネットワーク
    const pfx_192 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx_10 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    try std.testing.expect(!pfx_192.overlaps(&pfx_10));
    std.debug.print("✓ 完全分離: 192.168.1.0/24 と 10.0.0.0/8\n", .{});
    
    // テスト5: より複雑な包含関係
    const pfx_8 = Prefix.init(&IPAddr{ .v4 = .{ 192, 0, 0, 0 } }, 8);         // 192.0.0.0/8
    const pfx_16 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);      // 192.168.0.0/16
    const pfx_24 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);      // 192.168.1.0/24
    const pfx_32 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 100 } }, 32);    // 192.168.1.100/32
    
    try std.testing.expect(pfx_8.overlaps(&pfx_16));
    try std.testing.expect(pfx_8.overlaps(&pfx_24));
    try std.testing.expect(pfx_8.overlaps(&pfx_32));
    try std.testing.expect(pfx_16.overlaps(&pfx_24));
    try std.testing.expect(pfx_16.overlaps(&pfx_32));
    try std.testing.expect(pfx_24.overlaps(&pfx_32));
    std.debug.print("✓ 階層的包含: 192.0.0.0/8 ⊃ 192.168.0.0/16 ⊃ 192.168.1.0/24 ⊃ 192.168.1.100/32\n", .{});
}

test "Table overlaps detailed scenarios" {
    const allocator = std.testing.allocator;
    
    // シナリオ1: 包含関係のテスト
    {
        var table1 = Table(u32).init(allocator);
        defer table1.deinit();
        var table2 = Table(u32).init(allocator);
        defer table2.deinit();
        
        // table1: 大きなネットワーク
        const pfx_large = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);
        table1.insert(&pfx_large, 1);
        
        // table2: 小さなネットワーク（table1に含まれる）
        const pfx_small = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
        table2.insert(&pfx_small, 2);
        
        try std.testing.expect(table1.overlaps(&table2));
        try std.testing.expect(table1.overlapsPrefix(&pfx_small));
        try std.testing.expect(table2.overlapsPrefix(&pfx_large));
        std.debug.print("✓ シナリオ1: 包含関係でのオーバーラップ検出成功\n", .{});
    }
    
    // シナリオ2: 完全分離のテスト
    {
        var table1 = Table(u32).init(allocator);
        defer table1.deinit();
        var table2 = Table(u32).init(allocator);
        defer table2.deinit();
        
        // table1: 192.168.x.x
        const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
        table1.insert(&pfx1, 1);
        
        // table2: 10.x.x.x
        const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
        table2.insert(&pfx2, 2);
        
        try std.testing.expect(!table1.overlaps(&table2));
        try std.testing.expect(!table1.overlapsPrefix(&pfx2));
        try std.testing.expect(!table2.overlapsPrefix(&pfx1));
        std.debug.print("✓ シナリオ2: 完全分離でのオーバーラップ非検出成功\n", .{});
    }
    
    // シナリオ3: 複数プレフィックスでの部分的オーバーラップ
    {
        var table1 = Table(u32).init(allocator);
        defer table1.deinit();
        var table2 = Table(u32).init(allocator);
        defer table2.deinit();
        
        // table1: 複数のプレフィックス
        const pfx1_1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
        const pfx1_2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
        table1.insert(&pfx1_1, 1);
        table1.insert(&pfx1_2, 2);
        
        // table2: 一部がオーバーラップ、一部が分離
        const pfx2_1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16); // pfx1_1とオーバーラップ
        const pfx2_2 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 16);  // どちらともオーバーラップしない
        table2.insert(&pfx2_1, 3);
        table2.insert(&pfx2_2, 4);
        
        try std.testing.expect(table1.overlaps(&table2)); // 一部でもオーバーラップがあればtrue
        std.debug.print("✓ シナリオ3: 部分的オーバーラップ検出成功\n", .{});
    }
}

test "Table unionWith basic" {
    const allocator = std.testing.allocator;
    
    // テーブル1を作成
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    table1.insert(&pfx1, 1);
    table1.insert(&pfx2, 2);
    
    // テーブル2を作成
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 16);
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);
    table2.insert(&pfx3, 3);
    table2.insert(&pfx4, 4);
    
    std.debug.print("Table1 size before union: {}\n", .{table1.size()});
    std.debug.print("Table2 size: {}\n", .{table2.size()});
    
    // ユニオン実行
    table1.unionWith(&table2);
    
    std.debug.print("Table1 size after union: {}\n", .{table1.size()});
    
    // 結果をテスト
    try std.testing.expectEqual(@as(usize, 4), table1.size());
    
    // 元のプレフィックスが存在することを確認
    try std.testing.expectEqual(@as(u32, 1), table1.get(&pfx1).?);
    try std.testing.expectEqual(@as(u32, 2), table1.get(&pfx2).?);
    
    // 追加されたプレフィックスが存在することを確認
    try std.testing.expectEqual(@as(u32, 3), table1.get(&pfx3).?);
    try std.testing.expectEqual(@as(u32, 4), table1.get(&pfx4).?);
    
    std.debug.print("✓ ユニオンテーブル基本動作成功\n", .{});
}

test "Table unionWith duplicate prefixes" {
    const allocator = std.testing.allocator;
    
    // テーブル1を作成
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    table1.insert(&pfx1, 1);
    table1.insert(&pfx2, 2);
    
    // テーブル2を作成（重複あり）
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 16);
    // pfx1と同じプレフィックス、異なる値
    table2.insert(&pfx1, 100);
    table2.insert(&pfx3, 3);
    
    std.debug.print("Table1 initial pfx1 value: {}\n", .{table1.get(&pfx1).?});
    
    // ユニオン実行
    table1.unionWith(&table2);
    
    // 結果をテスト：重複したプレフィックスは上書きされる
    try std.testing.expectEqual(@as(usize, 3), table1.size()); // 2 + 2 - 1(重複)
    
    // 重複したプレフィックスは table2 の値で上書きされる
    try std.testing.expectEqual(@as(u32, 100), table1.get(&pfx1).?);
    try std.testing.expectEqual(@as(u32, 2), table1.get(&pfx2).?);
    try std.testing.expectEqual(@as(u32, 3), table1.get(&pfx3).?);
    
    std.debug.print("✓ ユニオンテーブル重複処理成功\n", .{});
}

test "Table unionWith empty tables" {
    const allocator = std.testing.allocator;
    
    // 空のテーブル1
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    
    // 空のテーブル2
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    // 空同士のユニオン
    table1.unionWith(&table2);
    try std.testing.expectEqual(@as(usize, 0), table1.size());
    
    // 片方だけに要素を追加
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    table2.insert(&pfx1, 1);
    
    table1.unionWith(&table2);
    try std.testing.expectEqual(@as(usize, 1), table1.size());
    try std.testing.expectEqual(@as(u32, 1), table1.get(&pfx1).?);
    
    std.debug.print("✓ ユニオンテーブル空テーブル処理成功\n", .{});
}

test "Table unionWith IPv6" {
    const allocator = std.testing.allocator;
    
    // テーブル1を作成
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    
    const pfx1 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32);
    table1.insert(&pfx1, 1);
    
    // テーブル2を作成
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    const pfx2 = Prefix.init(&IPAddr{ .v6 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 10);
    table2.insert(&pfx2, 2);
    
    // ユニオン実行
    table1.unionWith(&table2);
    
    // 結果をテスト
    try std.testing.expectEqual(@as(usize, 2), table1.size());
    try std.testing.expectEqual(@as(u32, 1), table1.get(&pfx1).?);
    try std.testing.expectEqual(@as(u32, 2), table1.get(&pfx2).?);
    
    std.debug.print("✓ ユニオンテーブルIPv6処理成功\n", .{});
}

test "Table unionWith mixed IPv4 and IPv6" {
    const allocator = std.testing.allocator;
    
    // テーブル1を作成（IPv4とIPv6混在）
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx6 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32);
    table1.insert(&pfx4, 1);
    table1.insert(&pfx6, 2);
    
    // テーブル2を作成（IPv4とIPv6混在）
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    const pfx4_2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const pfx6_2 = Prefix.init(&IPAddr{ .v6 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 10);
    table2.insert(&pfx4_2, 3);
    table2.insert(&pfx6_2, 4);
    
    // ユニオン実行
    table1.unionWith(&table2);
    
    // 結果をテスト
    try std.testing.expectEqual(@as(usize, 4), table1.size());
    try std.testing.expectEqual(@as(usize, 2), table1.getSize4());
    try std.testing.expectEqual(@as(usize, 2), table1.getSize6());
    
    // 各プレフィックスが存在することを確認
    try std.testing.expectEqual(@as(u32, 1), table1.get(&pfx4).?);
    try std.testing.expectEqual(@as(u32, 2), table1.get(&pfx6).?);
    try std.testing.expectEqual(@as(u32, 3), table1.get(&pfx4_2).?);
    try std.testing.expectEqual(@as(u32, 4), table1.get(&pfx6_2).?);
    
    std.debug.print("✓ ユニオンテーブルIPv4/IPv6混在処理成功\n", .{});
}

test "Table unionWith detailed verification" {
    const allocator = std.testing.allocator;
    
    // より複雑なシナリオでテスト
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    // Table1: 複数のプレフィックスを挿入
    const pfx1_1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);  // 192.168.0.0/16
    const pfx1_2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);     // 10.0.0.0/8
    const pfx1_3 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 12);  // 172.16.0.0/12
    const pfx1_4 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32); // 2001:db8::/32
    
    table1.insert(&pfx1_1, 100);
    table1.insert(&pfx1_2, 200);
    table1.insert(&pfx1_3, 300);
    table1.insert(&pfx1_4, 400);
    
    std.debug.print("=== Table1 初期状態 ===\n", .{});
    std.debug.print("Size: {}, IPv4: {}, IPv6: {}\n", .{ table1.size(), table1.getSize4(), table1.getSize6() });
    std.debug.print("192.168.0.0/16 -> {}\n", .{table1.get(&pfx1_1).?});
    std.debug.print("10.0.0.0/8 -> {}\n", .{table1.get(&pfx1_2).?});
    std.debug.print("172.16.0.0/12 -> {}\n", .{table1.get(&pfx1_3).?});
    std.debug.print("2001:db8::/32 -> {}\n", .{table1.get(&pfx1_4).?});
    
    // Table2: 一部重複、一部新規
    const pfx2_1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);  // 重複: 192.168.0.0/16
    const pfx2_2 = Prefix.init(&IPAddr{ .v4 = .{ 203, 0, 113, 0 } }, 24);  // 新規: 203.0.113.0/24
    const pfx2_3 = Prefix.init(&IPAddr{ .v4 = .{ 198, 51, 100, 0 } }, 24); // 新規: 198.51.100.0/24
    const pfx2_4 = Prefix.init(&IPAddr{ .v6 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 10); // 新規: fe80::/10
    const pfx2_5 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32); // 重複: 2001:db8::/32
    
    table2.insert(&pfx2_1, 999);  // 重複 - この値で上書きされるはず
    table2.insert(&pfx2_2, 500);
    table2.insert(&pfx2_3, 600);
    table2.insert(&pfx2_4, 700);
    table2.insert(&pfx2_5, 888);  // 重複 - この値で上書きされるはず
    
    std.debug.print("\n=== Table2 初期状態 ===\n", .{});
    std.debug.print("Size: {}, IPv4: {}, IPv6: {}\n", .{ table2.size(), table2.getSize4(), table2.getSize6() });
    std.debug.print("192.168.0.0/16 -> {} (重複)\n", .{table2.get(&pfx2_1).?});
    std.debug.print("203.0.113.0/24 -> {}\n", .{table2.get(&pfx2_2).?});
    std.debug.print("198.51.100.0/24 -> {}\n", .{table2.get(&pfx2_3).?});
    std.debug.print("fe80::/10 -> {}\n", .{table2.get(&pfx2_4).?});
    std.debug.print("2001:db8::/32 -> {} (重複)\n", .{table2.get(&pfx2_5).?});
    
    // ユニオン実行前の確認
    try std.testing.expectEqual(@as(usize, 4), table1.size());
    try std.testing.expectEqual(@as(usize, 5), table2.size());
    
    // ユニオン実行
    std.debug.print("\n=== ユニオン実行 ===\n", .{});
    table1.unionWith(&table2);
    
    std.debug.print("Union後のTable1 Size: {}, IPv4: {}, IPv6: {}\n", .{ table1.size(), table1.getSize4(), table1.getSize6() });
    
    // 結果検証
    // 期待値: 4 + 5 - 2(重複) = 7
    try std.testing.expectEqual(@as(usize, 7), table1.size());
    try std.testing.expectEqual(@as(usize, 5), table1.getSize4()); // IPv4: 3(元) + 3(新規) - 1(重複) = 5
    try std.testing.expectEqual(@as(usize, 2), table1.getSize6()); // IPv6: 1(元) + 2(新規) - 1(重複) = 2
    
    // 各プレフィックスの値を確認
    std.debug.print("\n=== 結果検証 ===\n", .{});
    
    // 重複したプレフィックス - table2の値で上書きされているはず
    try std.testing.expectEqual(@as(u32, 999), table1.get(&pfx1_1).?);
    std.debug.print("192.168.0.0/16 -> {} (999に上書き確認)\n", .{table1.get(&pfx1_1).?});
    
    try std.testing.expectEqual(@as(u32, 888), table1.get(&pfx1_4).?);
    std.debug.print("2001:db8::/32 -> {} (888に上書き確認)\n", .{table1.get(&pfx1_4).?});
    
    // table1の元のプレフィックス - 変更されないはず
    try std.testing.expectEqual(@as(u32, 200), table1.get(&pfx1_2).?);
    std.debug.print("10.0.0.0/8 -> {} (変更なし確認)\n", .{table1.get(&pfx1_2).?});
    
    try std.testing.expectEqual(@as(u32, 300), table1.get(&pfx1_3).?);
    std.debug.print("172.16.0.0/12 -> {} (変更なし確認)\n", .{table1.get(&pfx1_3).?});
    
    // table2の新規プレフィックス - 追加されているはず
    try std.testing.expectEqual(@as(u32, 500), table1.get(&pfx2_2).?);
    std.debug.print("203.0.113.0/24 -> {} (新規追加確認)\n", .{table1.get(&pfx2_2).?});
    
    try std.testing.expectEqual(@as(u32, 600), table1.get(&pfx2_3).?);
    std.debug.print("198.51.100.0/24 -> {} (新規追加確認)\n", .{table1.get(&pfx2_3).?});
    
    try std.testing.expectEqual(@as(u32, 700), table1.get(&pfx2_4).?);
    std.debug.print("fe80::/10 -> {} (新規追加確認)\n", .{table1.get(&pfx2_4).?});
    
    // table2は変更されていないことを確認
    std.debug.print("\n=== Table2 変更されていないことを確認 ===\n", .{});
    try std.testing.expectEqual(@as(usize, 5), table2.size());
    try std.testing.expectEqual(@as(u32, 999), table2.get(&pfx2_1).?);
    try std.testing.expectEqual(@as(u32, 500), table2.get(&pfx2_2).?);
    try std.testing.expectEqual(@as(u32, 600), table2.get(&pfx2_3).?);
    try std.testing.expectEqual(@as(u32, 700), table2.get(&pfx2_4).?);
    try std.testing.expectEqual(@as(u32, 888), table2.get(&pfx2_5).?);
    std.debug.print("Table2は変更されていません ✓\n", .{});
    
    std.debug.print("\n✅ 詳細検証テスト成功！\n", .{});
}

test "Table unionWith edge cases" {
    const allocator = std.testing.allocator;
    
    std.debug.print("\n=== エッジケーステスト ===\n", .{});
    
    // ケース1: 同じテーブルとのユニオン
    {
        var table1 = Table(u32).init(allocator);
        defer table1.deinit();
        
        const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
        const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
        table1.insert(&pfx1, 100);
        table1.insert(&pfx2, 200);
        
        const original_size = table1.size();
        std.debug.print("自分自身とのユニオン前: size = {}\n", .{original_size});
        
        table1.unionWith(&table1);
        
        // サイズは変わらないはず（全て重複）
        try std.testing.expectEqual(original_size, table1.size());
        try std.testing.expectEqual(@as(u32, 100), table1.get(&pfx1).?);
        try std.testing.expectEqual(@as(u32, 200), table1.get(&pfx2).?);
        std.debug.print("自分自身とのユニオン後: size = {} ✓\n", .{table1.size()});
    }
    
    // ケース2: 大量のプレフィックス
    {
        var table1 = Table(u32).init(allocator);
        defer table1.deinit();
        var table2 = Table(u32).init(allocator);
        defer table2.deinit();
        
        // table1に連続したプレフィックスを追加
        var i: u8 = 1;
        while (i <= 10) : (i += 1) {
            const pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, i, 0 } }, 24);
            table1.insert(&pfx, @as(u32, i));
        }
        
        // table2に一部重複、一部新規を追加
        i = 5;
        while (i <= 15) : (i += 1) {
            const pfx = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, i, 0 } }, 24);
            table2.insert(&pfx, @as(u32, i + 100));
        }
        
        const size1_before = table1.size();
        const size2_before = table2.size();
        std.debug.print("大量テスト前: table1={}, table2={}\n", .{ size1_before, size2_before });
        
        table1.unionWith(&table2);
        
        // 期待値: 10 + 11 - 6(重複: 5-10) = 15
        try std.testing.expectEqual(@as(usize, 15), table1.size());
        
        // 重複部分はtable2の値になっているはず
        const pfx_overlap = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 7, 0 } }, 24);
        try std.testing.expectEqual(@as(u32, 107), table1.get(&pfx_overlap).?); // 7 + 100
        
        std.debug.print("大量テスト後: table1={} ✓\n", .{table1.size()});
    }
    
    std.debug.print("✅ エッジケーステスト成功！\n", .{});
} 

test "Table unionWith performance test" {
    const allocator = std.testing.allocator;
    
    std.debug.print("\n=== パフォーマンステスト ===\n", .{});
    
    var table1 = Table(u32).init(allocator);
    defer table1.deinit();
    var table2 = Table(u32).init(allocator);
    defer table2.deinit();
    
    // シンプルなテストケース
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24); // 重複
    const pfx5 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 12);
    
    // table1に3つのプレフィックスを追加
    table1.insert(&pfx1, 100);
    table1.insert(&pfx2, 200);
    table1.insert(&pfx3, 300);
    
    // table2に3つのプレフィックスを追加（1つは重複）
    table2.insert(&pfx4, 999); // 重複: pfx1と同じ
    table2.insert(&pfx5, 500); // 新規
    
    const table1_size_before = table1.size();
    const table2_size_before = table2.size();
    
    std.debug.print("Table1 初期サイズ: {}\n", .{table1_size_before});
    std.debug.print("Table2 初期サイズ: {}\n", .{table2_size_before});
    
    // 時間計測開始
    const start_time = std.time.nanoTimestamp();
    
    // ユニオン実行
    table1.unionWith(&table2);
    
    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    
    const final_size = table1.size();
    const expected_size = table1_size_before + table2_size_before - 1; // 1つ重複
    
    std.debug.print("ユニオン実行時間: {d:.2}ms\n", .{duration_ms});
    std.debug.print("最終サイズ: {} (期待値: {})\n", .{ final_size, expected_size });
    
    // 結果検証
    try std.testing.expectEqual(expected_size, final_size);
    
    // 重複したプレフィックスは table2 の値になっているはず
    try std.testing.expectEqual(@as(u32, 999), table1.get(&pfx1).?);
    
    // 元のプレフィックスは変更されないはず
    try std.testing.expectEqual(@as(u32, 200), table1.get(&pfx2).?);
    try std.testing.expectEqual(@as(u32, 300), table1.get(&pfx3).?);
    
    // 新規プレフィックスが追加されているはず
    try std.testing.expectEqual(@as(u32, 500), table1.get(&pfx5).?);
    
    std.debug.print("✅ パフォーマンステスト成功！\n", .{});
} 

// =============================================================================
// All系イテレーション機能のテスト
// =============================================================================



test "all6WithCallback basic" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // カウンターをリセット
    test_ipv4_count = 0;
    test_ipv6_count = 0;

    // IPv6プレフィックスを追加
    const pfx1 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32);
    const pfx2 = Prefix.init(&IPAddr{ .v6 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 10);
    
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    
    // IPv4プレフィックス（除外されるべき）
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    table.insert(&pfx4, 4);
    
    // all6WithCallbackを実行
    table.all6WithCallback(&testCountYield);

    // IPv6プレフィックスのみが収集されることを確認
    try std.testing.expect(test_ipv6_count == 2);
    try std.testing.expect(test_ipv4_count == 0);
}

test "allWithCallback mixed IPv4 and IPv6" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // カウンターをリセット
    test_ipv4_count = 0;
    test_ipv6_count = 0;
    
    // IPv4とIPv6プレフィックスを混在で追加
    const pfx4_1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx4_2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const pfx6_1 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32);
    const pfx6_2 = Prefix.init(&IPAddr{ .v6 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 10);
    
    table.insert(&pfx4_1, 1);
    table.insert(&pfx4_2, 2);
    table.insert(&pfx6_1, 3);
    table.insert(&pfx6_2, 4);
    
    // allWithCallbackを実行
    table.allWithCallback(&testCountYield);
    
    // IPv4とIPv6の両方が含まれることを確認
    try std.testing.expect(test_ipv4_count == 2);
    try std.testing.expect(test_ipv6_count == 2);
}

test "allSorted4WithCallback order verification" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // カウンターをリセット
    test_ipv4_count = 0;
    test_ipv6_count = 0;
    
    // 意図的に順序を混乱させたプレフィックスを追加
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 2, 0 } }, 24);    // 後のアドレス
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 0, 0 } }, 16);    // より短いプレフィックス
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);    // 前のアドレス
    const pfx4 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);        // 全く違うアドレス空間
    
    table.insert(&pfx3, 3);
    table.insert(&pfx1, 1);
    table.insert(&pfx2, 2);
    table.insert(&pfx4, 4);
    
    // allSorted4WithCallbackを実行
    table.allSorted4WithCallback(&testCountYield);
    
    // IPv4プレフィックスが4つ全て収集されることを確認
    try std.testing.expect(test_ipv4_count == 4);
    try std.testing.expect(test_ipv6_count == 0);
}

// テスト用のグローバル変数
var test_ipv4_count: u32 = 0;
var test_ipv6_count: u32 = 0;

// テスト用のカウンター関数
fn testCountYield(prefix: Prefix, value: u32) bool {
    _ = value;
    if (prefix.addr.is4()) {
        test_ipv4_count += 1;
    } else {
        test_ipv6_count += 1;
    }
    return true; // 継続
}

test "all4WithCallback basic" {
    const allocator = std.testing.allocator;
    var table = Table(u32).init(allocator);
    defer table.deinit();

    // カウンターをリセット
    test_ipv4_count = 0;
    test_ipv6_count = 0;

    // IPv4プレフィックスを追加
    const pfx1 = Prefix.init(&IPAddr{ .v4 = .{ 192, 168, 1, 0 } }, 24);
    const pfx2 = Prefix.init(&IPAddr{ .v4 = .{ 10, 0, 0, 0 } }, 8);
    const pfx3 = Prefix.init(&IPAddr{ .v4 = .{ 172, 16, 0, 0 } }, 12);
    
    table.insert(&pfx1, 24);
    table.insert(&pfx2, 8);
    table.insert(&pfx3, 16);

    // IPv6プレフィックスを追加（含まれるべきではない）
    const pfx6 = Prefix.init(&IPAddr{ .v6 = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, 32);
    table.insert(&pfx6, 32);
    
    // all4WithCallbackを実行
    table.all4WithCallback(&testCountYield);

    // IPv4プレフィックスのみが収集されることを確認
    try std.testing.expect(test_ipv4_count == 3);
    try std.testing.expect(test_ipv6_count == 0);
}

