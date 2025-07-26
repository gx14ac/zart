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
const Node = @import("node.zig").Node;
const isFringe = @import("node.zig").isFringe;
const netip = @import("netip.zig");
const base_index = @import("base_index.zig");

// Table is an IPv4 and IPv6 routing table with payload V.
// The zero value is ready to use.
//
// The Table is safe for concurrent readers but not for concurrent readers
// and/or writers. Either the update operations must be protected by an
// external lock mechanism or the various ...Persist functions must be used
// which return a modified routing table by leaving the original unchanged
//
// A Table must not be copied by value.
pub fn Table(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // the root nodes, implemented as popcount compressed multibit tries
        // Go BART: root4 node[V]
        // Go BART: root6 node[V]
        root4: Node(V),
        root6: Node(V),
        
        // the number of prefixes in the routing table
        // Go BART: size4 int
        // Go BART: size6 int
        size4_count: i32,
        size6_count: i32,
        
        allocator: std.mem.Allocator,

        /// Initialize a new Table
        /// Go BART equivalent: var table Table[V] (zero value ready to use)
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .root4 = Node(V).init(allocator),
                .root6 = Node(V).init(allocator),
                .size4_count = 0,
                .size6_count = 0,
                .allocator = allocator,
            };
        }

        /// Deinitialize the table and free memory
        /// Go BART doesn't need explicit cleanup, but Zig does
        pub fn deinit(self: *Self) void {
            self.root4.deinit();
            self.root6.deinit();
        }

        /// rootNodeByVersion, root node getter for ip version.
        /// Go BART: func (t *Table[V]) rootNodeByVersion(is4 bool) *node[V]
        fn rootNodeByVersion(self: *Self, is4: bool) *Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }

        /// rootNodeByVersionConst, const root node getter for ip version (read-only operations).
        fn rootNodeByVersionConst(self: *const Self, is4: bool) *const Node(V) {
            if (is4) {
                return &self.root4;
            }
            return &self.root6;
        }


        /// Size returns the prefix count.
        /// Go BART: func (t *Table[V]) Size() int
        pub fn size(self: *const Self) i32 {
            return self.size4_count + self.size6_count;
        }

        /// Size4 returns the IPv4 prefix count.
        /// Go BART: func (t *Table[V]) Size4() int
        pub fn size4(self: *const Self) i32 {
            return self.size4_count;
        }

        /// Size6 returns the IPv6 prefix count.
        /// Go BART: func (t *Table[V]) Size6() int
        pub fn size6(self: *const Self) i32 {
            return self.size6_count;
        }

        /// Get returns the value for the exact prefix match and true,
        /// or false if no exact match was found.
        /// Go BART: func (t *Table[V]) Get(pfx netip.Prefix) (val V, ok bool)
        pub fn get(self: *const Self, pfx: *const netip.Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }

            // canonicalize the prefix
            const canonical_pfx = pfx.masked();

            // values derived from pfx
            const ip = canonical_pfx.addr();
            const is4 = canonical_pfx.is4();
            const bits = canonical_pfx.bits();

            const n = self.rootNodeByVersionConst(is4);
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;
            const octets = ip.asSlice();

            var current_node = n;

            // find the trie node
            for (octets[0..@min(octets.len, max_depth + 1)], 0..) |octet, depth_idx| {
                const depth = @as(u8, @intCast(depth_idx));
                
                if (depth == max_depth) {
                    const result = current_node.prefixes.Get(base_index.pfxToIdx256(octet, last_bits));
                    return if (result.ok) result.value else null;
                }

                if (!current_node.children.Test(octet)) {
                    return null;
                }
                
                const kid = current_node.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        current_node = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .fringe => |fringe_ptr| {
                        // reached a path compressed fringe, stop traversing
                        if (isFringe(depth, bits)) {
                            return fringe_ptr.value;
                        }
                        return null;
                    },
                    
                    .leaf => |leaf_ptr| {
                        // reached a path compressed prefix, stop traversing
                        if (leaf_ptr.prefix.eql(&canonical_pfx)) {
                            return leaf_ptr.value;
                        }
                        return null;
                    },
                }
            }

            return null;
        }

        /// Contains does a route lookup for IP and returns true if any route matched.
        /// Contains does not return the value nor the prefix of the matching item,
        /// but as a test against a black- or whitelist it's often sufficient
        /// and even few nanoseconds faster than Lookup.
        /// Go BART: func (t *Table[V]) Contains(ip netip.Addr) bool
        pub fn contains(self: *const Self, ip: *const netip.Addr) bool {
            // if ip is invalid, Is4() returns false and AsSlice() returns nil
            if (!ip.isValid()) {
                return false;
            }

            const is4 = ip.is4();
            var n = self.rootNodeByVersionConst(is4);

            for (ip.asSlice()) |octet| {
                // for contains, any lpm match is good enough, no backtracking needed
                if (n.prefixes.len() != 0 and n.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }

                // stop traversing?
                if (!n.children.Test(octet)) {
                    return false;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .fringe => |_| {
                        // fringe is the default-route for all possible octets below
                        return true;
                    },
                    
                    .leaf => |leaf_ptr| {
                        return leaf_ptr.prefix.contains(ip);
                    },
                }
            }

            return false;
        }

        /// Lookup does a route lookup (longest prefix match) for IP and
        /// returns the associated value and true, or false if no route matched.
        /// Go BART: func (t *Table[V]) Lookup(ip netip.Addr) (val V, ok bool)
        pub fn lookup(self: *const Self, ip: *const netip.Addr) struct { value: V, ok: bool } {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!ip.isValid()) {
                return .{ .value = zero, .ok = false };
            }

            const is4 = ip.is4();
            const octets = ip.asSlice();

            var n = self.rootNodeByVersionConst(is4);

            // stack of the traversed nodes for fast backtracking, if needed
            const maxTreeDepth = @import("node.zig").maxTreeDepth;
            var stack: [maxTreeDepth]*const Node(V) = undefined;

            // run variable, used after for loop
            var depth: usize = 0;
            var octet: u8 = 0;

            // find leaf node
            for (octets, 0..) |current_octet, depth_idx| {
                depth = depth_idx & 0xf; // BCE, Lookup must be fast
                octet = current_octet;

                // push current node on stack for fast backtracking
                stack[depth] = n;

                // go down in tight loop to last octet
                if (!n.children.Test(octet)) {
                    // no more nodes below octet
                    break;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .fringe => |fringe_ptr| {
                        // fringe is the default-route for all possible nodes below
                        return .{ .value = fringe_ptr.value, .ok = true };
                    },
                    
                    .leaf => |leaf_ptr| {
                        if (leaf_ptr.prefix.contains(ip)) {
                            return .{ .value = leaf_ptr.value, .ok = true };
                        }
                        // reached a path compressed prefix, stop traversing
                        break;
                    },
                }
            }

            // start backtracking, unwind the stack, bounds check eliminated
            while (depth < maxTreeDepth) {
                const current_depth = depth & 0xf; // BCE
                
                if (current_depth >= octets.len) break;
                if (current_depth > maxTreeDepth) break;

                n = stack[current_depth];

                // longest prefix match, skip if node has no prefixes
                if (n.prefixes.len() != 0) {
                    const idx = base_index.hostIdx(octets[current_depth]);
                    // lpmGet(idx), manually inlined
                    const result = n.lpmGet(idx);
                    if (result.ok) {
                        return .{ .value = result.val, .ok = true };
                    }
                }

                if (depth == 0) break;
                depth -= 1;
            }

            return .{ .value = zero, .ok = false };
        }

        /// sizeUpdate, internal helper to update size counters
        /// Go BART: func (t *Table[V]) sizeUpdate(is4 bool, delta int)
        fn sizeUpdate(self: *Self, is4: bool, delta: i32) void {
            if (is4) {
                self.size4_count += delta;
            } else {
                self.size6_count += delta;
            }
        }

        /// Insert adds a pfx to the tree, with given val.
        /// If pfx is already present in the tree, its value is set to val.
        /// Go BART: func (t *Table[V]) Insert(pfx netip.Prefix, val V)
        pub fn insert(self: *Self, pfx: *const netip.Prefix, val: V) void {
            if (!pfx.isValid()) {
                return;
            }

            // canonicalize prefix
            const canonical_pfx = pfx.masked();

            const is4 = canonical_pfx.is4();
            const n = self.rootNodeByVersion(is4);

            const exists = n.insertAtDepth(canonical_pfx, val, 0, self.allocator) catch |err| {
                std.debug.panic("Insert failed: {}", .{err});
            };

            if (exists) {
                return;
            }

            // true insert, update size
            self.sizeUpdate(is4, 1);
        }

        /// Update or set the value at pfx with a callback function.
        /// The callback function is called with (value, ok) and returns a new value.
        /// If the pfx does not already exist, it is set with the new value.
        /// Go BART: func (t *Table[V]) Update(pfx netip.Prefix, cb func(val V, ok bool) V) (newVal V)
        pub fn update(self: *Self, pfx: *const netip.Prefix, comptime cb: fn(V, bool) V) V {
            var zero: V = undefined;
            @memset(std.mem.asBytes(&zero), 0);

            if (!pfx.isValid()) {
                return zero;
            }

            // canonicalize prefix
            const canonical_pfx = pfx.masked();

            // values derived from pfx
            const ip = canonical_pfx.addr();
            const is4 = canonical_pfx.is4();
            const bits = canonical_pfx.bits();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var n = self.rootNodeByVersion(is4);

            // find the proper trie node to update prefix
            for (octets[0..@min(octets.len, max_depth + 1)], 0..) |octet, depth_idx| {
                const depth = @as(u8, @intCast(depth_idx));
                
                // last octet from prefix, update/insert prefix into node
                if (depth == max_depth) {
                    const result = n.prefixes.updateAt(
                        base_index.pfxToIdx256(octet, last_bits),
                        cb
                    ) catch |err| {
                        std.debug.panic("Update failed: {}", .{err});
                    };
                    
                    if (!result.was_present) {
                        self.sizeUpdate(is4, 1);
                    }
                    return result.new_value;
                }

                // go down in tight loop to last octet
                if (!n.children.Test(octet)) {
                    // insert prefix path compressed
                    const new_val = cb(zero, false);
                    
                    if (isFringe(depth, bits)) {
                        const FringeType = @import("node.zig").FringeNode(V);
                        const fringe = self.allocator.create(FringeType) catch |err| {
                            std.debug.panic("Fringe creation failed: {}", .{err});
                        };
                        fringe.* = FringeType.init(new_val);
                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .fringe = fringe }) catch |err| {
                            std.debug.panic("Fringe insert failed: {}", .{err});
                        };
                    } else {
                        const LeafType = @import("node.zig").LeafNode(V);
                        const leaf = self.allocator.create(LeafType) catch |err| {
                            std.debug.panic("Leaf creation failed: {}", .{err});
                        };
                        leaf.* = LeafType.init(canonical_pfx, new_val);
                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .leaf = leaf }) catch |err| {
                            std.debug.panic("Leaf insert failed: {}", .{err});
                        };
                    }
                    
                    self.sizeUpdate(is4, 1);
                    return new_val;
                }
                
                const kid = n.children.mustGet(octet);

                // kid is node or leaf or fringe at octet
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        // update existing value if prefixes are equal
                        if (leaf_ptr.prefix.eql(&canonical_pfx)) {
                            leaf_ptr.value = cb(leaf_ptr.value, true);
                            return leaf_ptr.value;
                        }

                        // create new node
                        // push the leaf down
                        // insert new child at current leaf position (octet)
                        // descend down, replace n with new child
                        const new_node = self.allocator.create(Node(V)) catch |err| {
                            std.debug.panic("Node creation failed: {}", .{err});
                        };
                        new_node.* = Node(V).init(self.allocator);
                        
                        _ = new_node.insertAtDepth(leaf_ptr.prefix, leaf_ptr.value, depth + 1, self.allocator) catch |err| {
                            std.debug.panic("InsertAtDepth failed: {}", .{err});
                        };

                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .node = new_node }) catch |err| {
                            std.debug.panic("Node insert failed: {}", .{err});
                        };
                        n = new_node;
                    },
                    
                    .fringe => |fringe_ptr| {
                        // update existing value if prefix is fringe
                        if (isFringe(depth, bits)) {
                            fringe_ptr.value = cb(fringe_ptr.value, true);
                            return fringe_ptr.value;
                        }

                        // create new node
                        // push the fringe down, it becomes a default route (idx=1)
                        // insert new child at current leaf position (octet)
                        // descend down, replace n with new child
                        const new_node = self.allocator.create(Node(V)) catch |err| {
                            std.debug.panic("Node creation failed: {}", .{err});
                        };
                        new_node.* = Node(V).init(self.allocator);
                        
                        _ = new_node.prefixes.insertAt(1, fringe_ptr.value) catch |err| {
                            std.debug.panic("Prefix insert failed: {}", .{err});
                        };

                        _ = n.children.insertAt(octet, Node(V).ChildNode{ .node = new_node }) catch |err| {
                            std.debug.panic("Node insert failed: {}", .{err});
                        };
                        n = new_node;
                    },
                }
            }

            @panic("unreachable");
        }
    };
}

/// maxDepthAndLastBits, get last significant octet and remaining bits
/// for a given netip.Prefix.
///
/// ATTENTION: Split the IP prefixes at 8bit borders, count from 0.
///
/// /0, /7, /15, /23, ...
///
/// BitPos: [0-7],[8-15],[16-23],[24-31],[32]
/// BitPos: [0-7],[8-15],[16-23],[24-31],[32-39],[40-47],[48-55],[56-63],...,[120-127],[128]
///
/// 0.0.0.0/0          => maxDepth:  0, lastBits: 0 (default route)
/// 0.0.0.0/7          => maxDepth:  0, lastBits: 7
/// 0.0.0.0/8          => maxDepth:  1, lastBits: 0 (possible fringe)
/// 10.0.0.0/8         => maxDepth:  1, lastBits: 0 (possible fringe)
/// 10.0.0.0/22        => maxDepth:  2, lastBits: 6
/// 10.0.0.0/29        => maxDepth:  3, lastBits: 5
/// 10.0.0.0/32        => maxDepth:  4, lastBits: 0 (possible fringe)
///
/// ::/0               => maxDepth:  0, lastBits: 0 (default route)
/// ::1/128            => maxDepth: 16, lastBits: 0 (possible fringe)
/// 2001:db8::/42      => maxDepth:  5, lastBits: 2
/// 2001:db8::/56      => maxDepth:  7, lastBits: 0 (possible fringe)
///
/// /32 and /128 are special, they never form a new node, they are always inserted
/// as path-compressed leaf.
///
/// Go BART: func maxDepthAndLastBits(bits int) (maxDepth int, lastBits uint8)
fn maxDepthAndLastBits(bits: u8) struct { max_depth: u8, last_bits: u8 } {
    // maxDepth:  range from 0..4 or 0..16 !ATTENTION: not 0..3 or 0..15
    // lastBits:  range from 0..7
    // Go BART: return bits >> 3, uint8(bits & 7)
    return .{
        .max_depth = bits >> 3,
        .last_bits = bits & 7,
    };
}

// 基本的なテスト
const testing = std.testing;

test "Table basic structure" {
    const allocator = testing.allocator;
    
    // Table[i32]のインスタンス作成
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // 初期状態の確認 - フィールド直接アクセス
    try testing.expectEqual(@as(i32, 0), table.size4_count);
    try testing.expectEqual(@as(i32, 0), table.size6_count);
    
    // 初期状態の確認 - Go BART互換メソッド
    try testing.expectEqual(@as(i32, 0), table.size());
    try testing.expectEqual(@as(i32, 0), table.size4());
    try testing.expectEqual(@as(i32, 0), table.size6());
}

test "Table with different types" {
    const allocator = testing.allocator;
    
    // 異なる型でのTable作成をテスト
    var int_table = Table(i32).init(allocator);
    defer int_table.deinit();
    
    var str_table = Table([]const u8).init(allocator);
    defer str_table.deinit();
    
    var void_table = Table(void).init(allocator);
    defer void_table.deinit();
    
    // すべて正常に作成できることを確認
    try testing.expect(true);
}

test "Table rootNodeByVersion" {
    const allocator = testing.allocator;
    var table = Table(i32).init(allocator);
    defer table.deinit();
    
    // IPv4ルートノードの取得をテスト
    const ipv4_root = table.rootNodeByVersion(true);
    try testing.expect(ipv4_root == &table.root4);
    
    // IPv6ルートノードの取得をテスト  
    const ipv6_root = table.rootNodeByVersion(false);
    try testing.expect(ipv6_root == &table.root6);
}

test "maxDepthAndLastBits function" {
    // Go BART コメントの例をテスト - パッケージレベル関数として
    
    // IPv4 examples:
    // 0.0.0.0/0          => maxDepth:  0, lastBits: 0 (default route)
    var result = maxDepthAndLastBits(0);
    try testing.expectEqual(@as(u8, 0), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // 0.0.0.0/7          => maxDepth:  0, lastBits: 7
    result = maxDepthAndLastBits(7);
    try testing.expectEqual(@as(u8, 0), result.max_depth);
    try testing.expectEqual(@as(u8, 7), result.last_bits);
    
    // 0.0.0.0/8          => maxDepth:  1, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(8);
    try testing.expectEqual(@as(u8, 1), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // 10.0.0.0/22        => maxDepth:  2, lastBits: 6
    result = maxDepthAndLastBits(22);
    try testing.expectEqual(@as(u8, 2), result.max_depth);
    try testing.expectEqual(@as(u8, 6), result.last_bits);
    
    // 10.0.0.0/29        => maxDepth:  3, lastBits: 5
    result = maxDepthAndLastBits(29);
    try testing.expectEqual(@as(u8, 3), result.max_depth);
    try testing.expectEqual(@as(u8, 5), result.last_bits);
    
    // 10.0.0.0/32        => maxDepth:  4, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(32);
    try testing.expectEqual(@as(u8, 4), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // IPv6 examples:
    // ::/0               => maxDepth:  0, lastBits: 0 (default route)
    result = maxDepthAndLastBits(0);
    try testing.expectEqual(@as(u8, 0), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // 2001:db8::/42      => maxDepth:  5, lastBits: 2
    result = maxDepthAndLastBits(42);
    try testing.expectEqual(@as(u8, 5), result.max_depth);
    try testing.expectEqual(@as(u8, 2), result.last_bits);
    
    // 2001:db8::/56      => maxDepth:  7, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(56);
    try testing.expectEqual(@as(u8, 7), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
    
    // ::1/128            => maxDepth: 16, lastBits: 0 (possible fringe)
    result = maxDepthAndLastBits(128);
    try testing.expectEqual(@as(u8, 16), result.max_depth);
    try testing.expectEqual(@as(u8, 0), result.last_bits);
}
