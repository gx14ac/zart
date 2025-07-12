const std = @import("std");
const base_index = @import("base_index.zig");
// Phase 4 Rollback: DirectArray256 caused cache misses, back to sparse_array256
const sparse_array256 = @import("sparse_array256.zig");
const Array256 = sparse_array256.Array256;
const bitset256 = @import("bitset256.zig");
const BitSet256 = bitset256.BitSet256;
const lookup_tbl = @import("lookup_tbl.zig");
pub const NodePool = @import("node_pool.zig").NodePool;

/// LookupResult represents the result of a lookup operation
pub fn LookupResult(comptime V: type) type {
    return struct {
        prefix: Prefix,
        value: V,
        ok: bool,
    };
}

/// Node is a level node in the multibit-trie.
/// A node has prefixes and children, forming the multibit trie.
///
/// The prefixes, mapped by the baseIndex() function from the ART algorithm,
/// form a complete binary tree.
///
/// In contrast to the ART algorithm, sparse arrays (popcount-compressed slices)
/// are used instead of fixed-size arrays.
///
/// The child array recursively spans the trie with a branching factor of 256
/// and also records path-compressed leaves in the free node slots.
pub fn Node(comptime V: type) type {
    return struct {
        const Self = @This();
        const Result = LookupResult(V);
        
        // Memory layout optimization for cache performance
        // Fields ordered by access frequency for optimal locality
        
        /// children maintains trie structure with 256-way branching
        children: Array256(Child(V)),
        
        /// prefixes stores route information using complete binary tree indexing
        prefixes: Array256(V),
        
        /// allocator for memory management operations
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) *Self {
            const node = allocator.create(Node(V)) catch unreachable;
            node.* = Self{
                .children = Array256(Child(V)).init(allocator),
                .prefixes = Array256(V).init(allocator),
                .allocator = allocator,
            };
            return node;
        }
        
        pub fn deinit(self: *Self) void {
            // 子ノードを再帰的にdeinit
            var i: usize = 0;
            while (i < 256) : (i += 1) {
                const idx = std.math.cast(u8, i) orelse break;
                if (self.children.isSet(idx)) {
                    const child = self.children.mustGet(idx);
                    switch (child) {
                        .node => |node_ptr| {
                            node_ptr.deinit();
                            node_ptr.allocator.destroy(node_ptr);
                        },
                        else => {},
                    }
                }
            }
            // Array256のdeinitで自動的にクリーンアップされる
            self.prefixes.deinit();
            self.children.deinit();
        }
        
        /// isEmpty returns true if node has neither prefixes nor children
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes.len() == 0 and self.children.len() == 0;
        }
        
        /// Check if this is a fringe node (host route)
        fn isFringe(depth: usize, bits: usize) bool {
            return ((depth + 1) * 8) == bits;
        }
        
        fn deepCloneChild(child: *const Child(V), allocator: std.mem.Allocator) Child(V) {
            return switch (child.*) {
                .node => |node_ptr| {
                    const new_node = Self.init(allocator);
                    new_node.prefixes = node_ptr.prefixes.deepCopy(allocator, struct {
                        fn cloneFn(val: *const V, _: std.mem.Allocator) V { return val.*; }
                    }.cloneFn);
                    new_node.children = node_ptr.children.deepCopy(allocator, Self.deepCloneChild);
                    return Child(V){ .node = new_node };
                },
                .leaf => |leaf| {
                    return Child(V){ .leaf = leaf.cloneLeaf() };
                },
                .fringe => |fringe| {
                    return Child(V){ .fringe = fringe.cloneFringe() };
                },
            };
        }
        
        fn shallowCloneChild(child: *const Child(V), allocator: std.mem.Allocator) Child(V) {
            return switch (child.*) {
                .node => |node_ptr| {
                    const new_node = Self.init(allocator);
                    new_node.prefixes = node_ptr.prefixes.deepCopy(allocator, struct {
                        fn cloneFn(val: *const V, _: std.mem.Allocator) V { return val.*; }
                    }.cloneFn);
                    new_node.children = node_ptr.children.deepCopy(allocator, Self.shallowCloneChild);
                    return Child(V){ .node = new_node };
                },
                .leaf => |leaf| {
                    return Child(V){ .leaf = leaf.cloneLeaf() };
                },
                .fringe => |fringe| {
                    return Child(V){ .fringe = fringe.cloneFringe() };
                },
            };
        }
        pub fn cloneRec(self: *const Self, allocator: std.mem.Allocator) *Self {
            const new_node = Self.init(allocator);
            new_node.prefixes = self.prefixes.deepCopy(allocator, struct {
                fn cloneFn(val: *const V, _: std.mem.Allocator) V {
                    return val.*;
                }
            }.cloneFn);
            new_node.children = self.children.deepCopy(allocator, Self.deepCloneChild);
            return new_node;
        }
        pub fn cloneFlat(self: *const Self, allocator: std.mem.Allocator) *Self {
            const new_node = Self.init(allocator);
            new_node.prefixes = self.prefixes.deepCopy(allocator, struct {
                fn cloneFn(val: *const V, _: std.mem.Allocator) V {
                    return val.*;
                }
            }.cloneFn);
            new_node.children = self.children.deepCopy(allocator, Self.shallowCloneChild);
            return new_node;
        }

        /// insertAtDepthPersist: Go実装と同じ動作の不変なinsert
        pub fn insertAtDepthPersist(self: *Self, pfx: *const Prefix, val: V, depth: usize, allocator: std.mem.Allocator) bool {
            const ip = &pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var current_depth = depth;
            var current_node = self;
            
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                if (!current_node.children.isSet(octet)) {
                    const new_node = Self.newNode(allocator);
                    const child = Child(V){ .node = new_node };
                    _ = (&current_node.children).replaceAt(octet, child);
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        // 子ノードをクローンして置き換え
                        const cloned_node = node.cloneFlat(allocator);
                        if (current_node.children.replaceAt(octet, Child(V){ .node = cloned_node })) |old_child| {
                            switch (old_child) {
                                .node => |old_node| {
                                    old_node.deinit();
                                    old_node.allocator.destroy(old_node);
                                },
                                else => {},
                            }
                        }
                        current_node = cloned_node;
                    },
                    else => unreachable,
                }
            }
            
            const prefix_byte_idx: usize = if (bits > 8) (bits / 8) - 1 else 0;
            var octet_val: u8 = 0;
            if (octets.len > prefix_byte_idx) {
                octet_val = octets[prefix_byte_idx];
            }
            const idx = base_index.pfxToIdx256(octet_val, last_bits);
            const was_new_insert = current_node.prefixes.insertAt(idx, val);
            return !was_new_insert; // 既存を更新した場合はtrue、新規挿入の場合はfalse
        }
        
        /// lpmTest determines longest prefix match existence for the specified index.
        /// Utilizes precomputed lookup tables for optimal performance characteristics.
        pub fn lpmTest(self: *const Self, idx: usize) bool {
            if (idx < lookup_tbl.lookupTbl.len) {
                const bs = lookup_tbl.lookupTbl[idx];
                return self.prefixes.intersectsAny(&bs);
            }
            
            // Fallback path for boundary conditions
            var bs: bitset256.BitSet256 = @as(bitset256.BitSet256, lookup_tbl.backTrackingBitset(idx));
            return self.prefixes.intersectsAny(&bs);
        }

        /// lpmGet retrieves the longest prefix match for the specified index.
        /// Returns match details including base index and associated value.
        pub fn lpmGet(self: *const Self, idx: usize) struct { base_idx: u8, val: V, ok: bool } {
            if (idx < lookup_tbl.lookupTbl.len) {
                const bs = lookup_tbl.lookupTbl[idx];
                if (self.prefixes.intersectionTop(&bs)) |top| {
                    return .{ .base_idx = top, .val = self.prefixes.mustGet(top), .ok = true };
                }
            } else {
                // Dynamic computation for exceptional cases
                var bs: bitset256.BitSet256 = @as(bitset256.BitSet256, lookup_tbl.backTrackingBitset(idx));
                if (self.prefixes.intersectionTop(&bs)) |top| {
                    return .{ .base_idx = top, .val = self.prefixes.mustGet(top), .ok = true };
                }
            }
            return .{ .base_idx = 0, .val = undefined, .ok = false };
        }

        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var current_depth: usize = 0;
            var current_node = self;
            
            // Forward traversal - like Go BART insertAtDepth
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                if (!current_node.children.isSet(octet)) {
                    break;
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    .leaf => |leaf| {
                        // Check if this leaf matches our prefix exactly
                        if (leaf.prefix.eql(masked_pfx)) {
                            return leaf.value;
                        }
                        // Leaf doesn't match, no further descent possible
                        return null;
                    },
                    .fringe => |fringe| {
                        // Check if current depth+1 matches our prefix bits
                        const fringe_bits = @as(u8, @intCast((current_depth + 1) * 8));
                        if (fringe_bits == bits) {
                            return fringe.value;
                        }
                        // Fringe doesn't match, no further descent possible
                        return null;
                    },
                }
            }
            
            // Terminal case: look in prefixes
            const prefix_byte_idx: usize = if (bits > 8) (bits / 8) - 1 else 0;
            var octet_val: u8 = 0;
            if (octets.len > prefix_byte_idx) {
                octet_val = octets[prefix_byte_idx];
            }
            const idx = base_index.pfxToIdx256(octet_val, last_bits);
            if (current_node.prefixes.isSet(idx)) {
                return current_node.prefixes.mustGet(idx);
            }
            return null;
        }
        
        pub fn delete(self: *Self, pfx: *const Prefix) ?V {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            var current_depth: usize = 0;
            var current_node = self;
            
            // Forward traversal - like Go BART insertAtDepth
            while (current_depth < max_depth) : (current_depth += 1) {
                var octet: u8 = 0;
                if (current_depth < octets.len) {
                    octet = octets[current_depth];
                }
                if (!current_node.children.isSet(octet)) {
                    return null;
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    .leaf => |leaf| {
                        // Check if this leaf matches our prefix exactly
                        if (leaf.prefix.eql(masked_pfx)) {
                            const value = leaf.value;
                            // Delete the leaf by removing it from children
                            _ = current_node.children.deleteAt(octet);
                            return value;
                        }
                        // Leaf doesn't match, nothing to delete
                        return null;
                    },
                    .fringe => |fringe| {
                        // Check if current depth+1 matches our prefix bits
                        const fringe_bits = @as(u8, @intCast((current_depth + 1) * 8));
                        if (fringe_bits == bits) {
                            const value = fringe.value;
                            // Delete the fringe by removing it from children
                            _ = current_node.children.deleteAt(octet);
                            return value;
                        }
                        // Fringe doesn't match, nothing to delete
                        return null;
                    },
                }
            }
            
            // Terminal case: delete from prefixes
            const prefix_byte_idx: usize = if (bits > 8) (bits / 8) - 1 else 0;
            var octet_val: u8 = 0;
            if (octets.len > prefix_byte_idx) {
                octet_val = octets[prefix_byte_idx];
            }
            const idx = base_index.pfxToIdx256(octet_val, last_bits);
            return current_node.prefixes.deleteAt(idx);
        }
        
        /// lookup performs longest prefix matching for the given IP address
        pub fn lookup(self: *const Self, addr: *const IPAddr) Result {
            const octets = addr.asSlice();
            var current_node = self;
            var current_depth: usize = 0;
            var best_match = Result{ .prefix = undefined, .value = undefined, .ok = false };
            
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // 現在のノードでLPMを試行
                const lpm_result = current_node.lpmGet(octet);
                if (lpm_result.ok) {
                    // プレフィックスを再構築
                    const pfx_info = base_index.idxToPfx256(lpm_result.base_idx) catch continue;
                    var prefix_addr = addr.*;
                    prefix_addr = prefix_addr.masked(@as(u8, @intCast(current_depth * 8 + pfx_info.pfx_len)));
                    const prefix = Prefix.init(&prefix_addr, @as(u8, @intCast(current_depth * 8 + pfx_info.pfx_len)));
                    best_match = Result{ .prefix = prefix, .value = lpm_result.val, .ok = true };
                }
                
                // 子ノードに進む
                if (!current_node.children.isSet(octet)) {
                    break;
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                    },
                    else => break,
                }
            }
            
            return best_match;
        }
        
        /// lookupPrefix performs longest prefix matching for the given prefix
        /// This is a complete rewrite based on Go BART implementation
        pub fn lookupPrefix(self: *const Self, pfx: *const Prefix) Result {
            const masked_pfx = pfx.masked();
            const ip = &masked_pfx.addr;
            const bits = masked_pfx.bits;
            const octets = ip.asSlice();
            const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
            const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
            
            var current_depth: usize = 0;
            var current_node = self;
            var octet: u8 = 0;
            
            // スタックを使ってパスを記録（バックトラッキング用）
            var stack: [16]*const Self = undefined;
            
            // 前進フェーズ: プレフィックスのパスに沿ってトライを降りる
            forward_loop: while (current_depth < octets.len) {
                if (current_depth > max_depth) {
                    current_depth -= 1;
                    break;
                }
                
                octet = octets[current_depth];
                
                // 現在のノードをスタックに記録
                stack[current_depth] = current_node;
                
                if (!current_node.children.isSet(octet)) {
                    break :forward_loop;
                }
                
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                        current_depth += 1;
                        continue :forward_loop;
                    },
                    .leaf => |leaf| {
                        // Go実装の条件: kid.prefix.Bits() > bits || !kid.prefix.Contains(ip)
                        if (leaf.prefix.bits > bits or !leaf.prefix.containsAddr(masked_pfx.addr)) {
                            break :forward_loop;
                        }
                        return Result{ .prefix = leaf.prefix, .value = leaf.value, .ok = true };
                    },
                    .fringe => |fringe| {
                        // Go実装の条件: fringeBits > bits
                        const fringe_bits = @as(u8, @intCast((current_depth + 1) * 8));
                        if (fringe_bits > bits) {
                            break :forward_loop;
                        }
                        
                        // fringeプレフィックスを再構築
                        var path: [16]u8 = undefined;
                        @memcpy(path[0..octets.len], octets);
                        path[current_depth] = octet;
                        var addr = if (ip.is4()) IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } } else IPAddr{ .v6 = path[0..16].* };
                        const fringe_pfx = Prefix.init(&addr, fringe_bits);
                        
                        return Result{ .prefix = fringe_pfx, .value = fringe.value, .ok = true };
                    },
                }
            }
            
            // バックトラッキングフェーズ: スタックを巻き戻してLPMを探す
            // Go実装では、current_depthから開始してdepth >= 0まで
            var depth = if (current_depth <= max_depth) current_depth else max_depth;
            while (depth >= 0) {
                current_node = stack[depth];
                
                // longest prefix match, skip if node has no prefixes
                if (current_node.prefixes.len() == 0) {
                    if (depth == 0) break;
                    depth -= 1;
                    continue;
                }
                
                // Go実装の条件: only the lastOctet may have a different prefix len
                octet = octets[depth];
                const idx = if (depth == max_depth) 
                    base_index.pfxToIdx256(octet, last_bits) 
                else 
                    base_index.hostIdx(octet);
                
                const lmp_result = current_node.lpmGet(idx);
                if (lmp_result.ok) {
                    // Go実装: get the pfxLen from depth and top idx
                    const pfx_len = base_index.pfxLen256(@as(i32, @intCast(depth)), lmp_result.base_idx) catch {
                        if (depth == 0) break;
                        depth -= 1;
                        continue;
                    };
                    
                    // Go実装: calculate the lmpPfx from incoming ip and new mask
                    var prefix_addr = ip.*;
                    prefix_addr = prefix_addr.masked(pfx_len);
                    const lmp_pfx = Prefix.init(&prefix_addr, pfx_len);
                    
                    return Result{ .prefix = lmp_pfx, .value = lmp_result.val, .ok = true };
                }
                
                if (depth == 0) break;
                depth -= 1;
            }
            
            return Result{ .prefix = undefined, .value = undefined, .ok = false };
        }

        /// overlapsIdx returns true if node overlaps with prefix
        /// Go実装のoverlapsIdxメソッドを移植
        pub fn overlapsIdx(self: *const Self, idx: u8) bool {
            // 1. Test if any route in this node overlaps prefix?
            if (self.lpmTest(idx)) {
                return true;
            }

            // 2. Test if prefix overlaps any route in this node
            // use bitset intersections instead of range loops
            // shallow copy pre alloted bitset for idx
            const alloted_prefix_routes = lookup_tbl.idxToPrefixRoutes(idx);
            if (alloted_prefix_routes.intersectsAny(&self.prefixes.bitset)) {
                return true;
            }

            // 3. Test if prefix overlaps any child in this node
            const alloted_host_routes = lookup_tbl.idxToFringeRoutes(idx);
            return alloted_host_routes.intersectsAny(&self.children.bitset);
        }

        /// overlapsRoutes tests if n overlaps o prefixes and vice versa
        /// Go実装のoverlapsRoutesメソッドを移植
        pub fn overlapsRoutes(self: *const Self, other: *const Self) bool {
            // some prefixes are identical, trivial overlap
            if (self.prefixes.intersectsAny(&other.prefixes.bitset)) {
                return true;
            }

            // get the lowest idx (biggest prefix)
            const n_first_idx = self.prefixes.bitset.firstSet() orelse return false;
            const o_first_idx = other.prefixes.bitset.firstSet() orelse return false;

            // start with other min value
            var n_idx = o_first_idx;
            var o_idx = n_first_idx;

            var n_ok = true;
            var o_ok = true;

            // zip, range over n and o together to help chance on its way
            while (n_ok or o_ok) {
                if (n_ok) {
                    // does any route in o overlap this prefix from n
                    if (self.prefixes.bitset.nextSet(n_idx)) |next_n_idx| {
                        n_idx = next_n_idx;
                        if (other.lpmTest(n_idx)) {
                            return true;
                        }

                        if (n_idx == 255) {
                            // stop, don't overflow uint8!
                            n_ok = false;
                        } else {
                            n_idx += 1;
                        }
                    } else {
                        n_ok = false;
                    }
                }

                if (o_ok) {
                    // does any route in n overlap this prefix from o
                    if (other.prefixes.bitset.nextSet(o_idx)) |next_o_idx| {
                        o_idx = next_o_idx;
                        if (self.lpmTest(o_idx)) {
                            return true;
                        }

                        if (o_idx == 255) {
                            // stop, don't overflow uint8!
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

        /// overlapsChildrenIn tests if prefixes in n overlaps child octets in o
        /// Go実装のoverlapsChildrenInメソッドを移植
        pub fn overlapsChildrenIn(self: *const Self, other: *const Self) bool {
            const pfx_count = self.prefixes.len();
            const child_count = other.children.len();

            // heuristic, compare benchmarks
            // when will we range over the children and when will we do bitset calc?
            const magic_number = 15;
            const do_range = child_count < magic_number or pfx_count > magic_number;

            // do range over, not so many childs and maybe too many prefixes for other algo below
            if (do_range) {
                var buf: [256]u8 = undefined;
                const children_slice = other.children.bitset.asSlice(&buf);
                for (children_slice) |addr| {
                    if (self.lpmTest(base_index.hostIdx(addr))) {
                        return true;
                    }
                }
                return false;
            }

            // do bitset intersection, alloted route table with child octets
            // maybe too many childs for range-over or not so many prefixes to
            // build the alloted routing table from them

            // make allot table with prefixes as bitsets, bitsets are precalculated.
            // Just union the bitsets to one bitset (allot table) for all prefixes
            // in this node
            var host_routes = BitSet256.init();

            var buf: [256]u8 = undefined;
            const all_indices = self.prefixes.bitset.asSlice(&buf);

            // union all pre alloted bitsets
            for (all_indices) |idx| {
                const fringe_routes = lookup_tbl.idxToFringeRoutes(idx);
                host_routes = host_routes.bitUnion(&fringe_routes);
            }

            return host_routes.intersectsAny(&other.children.bitset);
        }

        /// overlaps returns true if any IP in the nodes n or o overlaps
        /// Go実装のoverlapsメソッドを移植
        pub fn overlaps(self: *const Self, other: *const Self, depth: usize) bool {
            const n_pfx_count = self.prefixes.len();
            const o_pfx_count = other.prefixes.len();

            const n_child_count = self.children.len();
            const o_child_count = other.children.len();

            // ##############################
            // 1. Test if any routes overlaps
            // ##############################

            // full cross check
            if (n_pfx_count > 0 and o_pfx_count > 0) {
                if (self.overlapsRoutes(other)) {
                    return true;
                }
            }

            // ####################################
            // 2. Test if routes overlaps any child
            // ####################################

            // swap nodes to help chance on its way,
            // if the first call to expensive overlapsChildrenIn() is already true,
            // if both orders are false it doesn't help either
            var n_node = self;
            var o_node = other;
            var n_pfx_count_local = n_pfx_count;
            var o_pfx_count_local = o_pfx_count;
            var n_child_count_local = n_child_count;
            var o_child_count_local = o_child_count;

            if (n_child_count > o_child_count) {
                n_node = other;
                o_node = self;
                n_pfx_count_local = o_pfx_count;
                o_pfx_count_local = n_pfx_count;
                n_child_count_local = o_child_count;
                o_child_count_local = n_child_count;
            }

            if (n_pfx_count_local > 0 and o_child_count_local > 0) {
                if (n_node.overlapsChildrenIn(o_node)) {
                    return true;
                }
            }

            // symmetric reverse
            if (o_pfx_count_local > 0 and n_child_count_local > 0) {
                if (o_node.overlapsChildrenIn(n_node)) {
                    return true;
                }
            }

            // ###########################################
            // 3. childs with same octet in nodes n and o
            // ###########################################

            // stop condition, n or o have no childs
            if (n_child_count == 0 or o_child_count == 0) {
                return false;
            }

            // stop condition, no child with identical octet in n and o
            if (!self.children.intersectsAny(&other.children.bitset)) {
                return false;
            }

            return self.overlapsSameChildren(other, depth);
        }

        /// overlapsSameChildren finds same octets with bitset intersection
        /// Go実装のoverlapsSameChildrenメソッドを移植
        fn overlapsSameChildren(self: *const Self, other: *const Self, depth: usize) bool {
            // intersect the child bitsets from n with o
            const common_children = self.children.bitset.intersection(&other.children.bitset);

            var addr: u8 = 0;
            var ok = true;
            while (ok) {
                if (common_children.nextSet(addr)) |next_addr| {
                    addr = next_addr;
                    const n_child = self.children.mustGet(addr);
                    const o_child = other.children.mustGet(addr);

                    if (overlapsTwoChilds(V, n_child, o_child, depth + 1)) {
                        return true;
                    }

                    if (addr == 255) {
                        // stop, don't overflow uint8!
                        ok = false;
                    } else {
                        addr += 1;
                    }
                } else {
                    ok = false;
                }
            }
            return false;
        }

        /// overlapsPrefixAtDepth returns true if node overlaps with prefix
        /// starting with prefix octet at depth
        /// Go実装のoverlapsPrefixAtDepthメソッドを移植
        pub fn overlapsPrefixAtDepth(self: *const Self, pfx: *const Prefix, depth: usize) bool {
            const ip = &pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;

            var current_depth = depth;
            var current_node = self;

            while (current_depth < octets.len) : (current_depth += 1) {
                if (current_depth > max_depth) {
                    break;
                }

                const octet = octets[current_depth];

                // full octet path in node trie, check overlap with last prefix octet
                if (current_depth == max_depth) {
                    return current_node.overlapsIdx(base_index.pfxToIdx256(octet, last_bits));
                }

                // test if any route overlaps prefix so far
                // no best match needed, forward tests without backtracking
                if (current_node.prefixes.len() != 0 and current_node.lpmTest(base_index.hostIdx(octet))) {
                    return true;
                }

                if (!current_node.children.isSet(octet)) {
                    return false;
                }

                // next child, node or leaf
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                        continue;
                    },
                    .leaf => |leaf| {
                        return leaf.prefix.overlaps(pfx);
                    },
                    .fringe => {
                        return true;
                    },
                }
            }

            @panic("unreachable: " ++ @typeName(@TypeOf(pfx)));
        }

        // =============================================================================
        // All系イテレーション機能
        // =============================================================================

        /// Yield関数の型定義
        pub const YieldFn = fn (prefix: Prefix, value: V) bool;

        /// allRec: 基本的なイテレーション機能（順序不定）
        /// Go実装のallRecメソッドを移植
        pub fn allRec(self: *const Self, path: StridePath, depth: usize, is4: bool, yield: *const YieldFn) bool {
            // 現在のノードのすべてのプレフィックスをイテレート
            var buf: [256]u8 = undefined;
            const indices = self.prefixes.bitset.asSlice(&buf);

            for (indices) |idx| {
                const cidr = cidrFromPath(path, depth, is4, idx);
                const value = self.prefixes.mustGet(idx);

                // コールバックでこのプレフィックスと値を処理
                if (!yield(cidr, value)) {
                    // 早期終了
                    return false;
                }
            }

            // このノードのすべての子（ノードとリーフ）をイテレート
            var child_buf: [256]u8 = undefined;
            const child_addrs = self.children.bitset.asSlice(&child_buf);

            for (child_addrs) |addr| {
                const kid = self.children.mustGet(addr);

                switch (kid) {
                    .node => |node| {
                        // この子ノードで再帰的に処理
                        var new_path = path;
                        if (depth < new_path.len) {
                            new_path[depth] = addr;
                        }
                        if (!node.allRec(new_path, depth + 1, is4, yield)) {
                            // 早期終了
                            return false;
                        }
                    },
                    .leaf => |leaf| {
                        // このリーフのコールバック
                        if (!yield(leaf.prefix, leaf.value)) {
                            // 早期終了
                            return false;
                        }
                    },
                    .fringe => |fringe| {
                        const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                        // このフリンジのコールバック
                        if (!yield(fringe_pfx, fringe.value)) {
                            // 早期終了
                            return false;
                        }
                    },
                }
            }

            return true;
        }

        /// dumpListRec: Go実装互換の階層構造リスト生成
        pub fn dumpListRec(self: *const Self, allocator: std.mem.Allocator, parent_idx: u8, path: [16]u8, depth: usize, is4: bool) ![]DumpListNode(V) {
            // Go実装: recursion stop condition
            // if n == nil { return nil }
            // Zigでは常にnon-nullなので、空のノードをチェック
            
            // 直接カバーされるアイテムを取得
            const direct_items = try self.directItemsRec(allocator, parent_idx, path, depth, is4);
            defer allocator.free(direct_items);
            
            // Go実装: sort the items by prefix
            std.sort.insertion(TrieItem(V), direct_items, {}, compareTrieItemByPrefix(V));
            
            // Go実装: nodes := make([]DumpListNode[V], 0, len(directItems))
            var nodes = std.ArrayList(DumpListNode(V)).init(allocator);
            defer nodes.deinit();
            
            for (direct_items) |item| {
                // Go実装: build it rec-descent
                const subnets = if (item.node) |node| blk: {
                    break :blk try node.dumpListRec(allocator, item.idx, item.path, item.depth, is4);
                } else blk: {
                    break :blk try allocator.alloc(DumpListNode(V), 0);
                };
                
                // 値を持たない中間ノード（value=0）の場合は、サブネットのみを親に昇格
                if (item.node != null and !hasValueFromTrieItem(item) and subnets.len > 0) {
                    // サブネットを直接親レベルに追加
                    for (subnets) |subnet| {
                        try nodes.append(subnet);
                    }
                    // メモリリークを防ぐため、サブネット配列自体のみを解放
                    allocator.free(subnets);
                } else {
                    // 通常のノード（値を持つ、またはリーフ）
                    try nodes.append(DumpListNode(V){
                        .cidr = item.cidr,
                        .value = item.value,
                        .subnets = subnets,
                    });
                }
            }
            
            return nodes.toOwnedSlice();
        }
        
        /// TrieItemが値を持つかチェック
        fn hasValueFromTrieItem(item: TrieItem(V)) bool {
            if (V == u32) {
                return item.value != 0;
            }
            // 他の型では常にtrueと仮定
            return true;
        }

        /// directItemsRec: Go実装のdirectItemsRecを正確に移植
        fn directItemsRec(self: *const Self, allocator: std.mem.Allocator, _: u8, path: [16]u8, depth: usize, is4: bool) ![]TrieItem(V) {
            var items = std.ArrayList(TrieItem(V)).init(allocator);
            defer items.deinit();
            
            // Go実装: prefixes
            // for all idx's (prefixes mapped by baseIndex) in this node
            // do a longest-prefix-match
            var buf: [256]u8 = undefined;
            const indices = self.prefixes.bitset.asSlice(&buf);
            
            for (indices) |idx| {
                const value = self.prefixes.mustGet(idx);
                
                // 実際に保存されたプレフィックス情報から正確なCIDRを復元
                const pfx_result = reconstructExactPrefix(idx, path, depth, is4);
                if (pfx_result.ok) {
                    try items.append(TrieItem(V){
                        .node = null,
                        .is4 = is4,
                        .path = path,
                        .depth = depth,
                        .idx = idx,
                        .cidr = pfx_result.prefix,
                        .value = value,
                    });
                }
            }
            
            // Go実装: children
            // for all child addresses in this node
            // do a longest-prefix-match
            var child_buf: [256]u8 = undefined;
            const child_addrs = self.children.bitset.asSlice(&child_buf);
            
            for (child_addrs) |addr| {
                const child = self.children.mustGet(addr);
                
                switch (child) {
                    .node => |node| {
                        // 中間ノードは値を持つ場合のみDumpListに含める
                        if (node.hasValue()) {
                            // 実際のプレフィックス情報から正確なCIDRを復元
                            var node_pfx_buf: [256]u8 = undefined;
                            const node_indices = node.prefixes.bitset.asSlice(&node_pfx_buf);
                            
                            if (node_indices.len > 0) {
                                const first_idx = node_indices[0];
                                const node_value = node.prefixes.mustGet(first_idx);
                                
                                var new_path = path;
                                if (depth < new_path.len) {
                                    new_path[depth] = addr;
                                }
                                
                                const node_pfx_result = reconstructExactPrefix(first_idx, new_path, depth + 1, is4);
                                if (node_pfx_result.ok) {
                                    try items.append(TrieItem(V){
                                        .node = node,
                                        .is4 = is4,
                                        .path = new_path,
                                        .depth = depth + 1,
                                        .idx = first_idx,
                                        .cidr = node_pfx_result.prefix,
                                        .value = node_value,
                                    });
                                }
                            }
                        }
                    },
                    .leaf => |leaf| {
                        // Go実装: if kid.leaf != nil
                        try items.append(TrieItem(V){
                            .node = null,
                            .is4 = is4,
                            .path = path,
                            .depth = depth,
                            .idx = 0, // リーフはプレフィックス情報が既に正確
                            .cidr = leaf.prefix,
                            .value = leaf.value,
                        });
                    },
                    .fringe => |fringe| {
                        // フリンジの正確なプレフィックスを復元
                        const fringe_bits = @as(u8, @intCast((depth + 1) * 8));
                        var fringe_path = path;
                        if (depth < fringe_path.len) {
                            fringe_path[depth] = addr;
                        }
                        
                        const fringe_addr = if (is4) 
                            IPAddr{ .v4 = .{ fringe_path[0], fringe_path[1], fringe_path[2], fringe_path[3] } }
                        else 
                            IPAddr{ .v6 = fringe_path };
                            
                        const fringe_pfx = Prefix.init(&fringe_addr, fringe_bits);
                        
                        try items.append(TrieItem(V){
                            .node = null,
                            .is4 = is4,
                            .path = path,
                            .depth = depth,
                            .idx = 0, // フリンジはパス情報から正確
                            .cidr = fringe_pfx,
                            .value = fringe.value,
                        });
                    },
                }
            }
            
            return items.toOwnedSlice();
        }
        
        /// reconstructExactPrefix: インデックス、パス、深度から正確なプレフィックスを復元
        fn reconstructExactPrefix(idx: u8, path: [16]u8, depth: usize, is4: bool) struct { prefix: Prefix, ok: bool } {
            const pfx_info = base_index.idxToPfx256(idx) catch {
                return .{ .prefix = undefined, .ok = false };
            };
            
            // 総ビット数を計算
            const total_bits = @as(u8, @intCast(depth * 8 + pfx_info.pfx_len));
            
            if (is4 and total_bits > 32) {
                return .{ .prefix = undefined, .ok = false };
            }
            if (!is4 and total_bits > 128) {
                return .{ .prefix = undefined, .ok = false };
            }
            
            var addr_path = path;
            
            // **重要：既存のパス情報を保持し、マスクのみ適用**
            // パス情報（172, 16, ...）は既に正しく設定されているので、
            // プレフィックス長に応じてマスクするだけ
            
            // プレフィックス範囲外のビットをクリア
            const full_bytes = total_bits / 8;
            const remaining_bits = total_bits % 8;
            
            // 完全なバイト後をクリア
            if (full_bytes + 1 < addr_path.len) {
                for (addr_path[full_bytes + 1..]) |*byte| {
                    byte.* = 0;
                }
            }
            
            // 部分バイトのマスク（最も重要な部分）
            if (remaining_bits > 0 and full_bytes < addr_path.len) {
                const mask = @as(u8, 0xff) << @as(u3, @intCast(8 - remaining_bits));
                addr_path[full_bytes] &= mask;
            }
            
            // IPアドレスを作成
            const ip_addr = if (is4) 
                IPAddr{ .v4 = .{ addr_path[0], addr_path[1], addr_path[2], addr_path[3] } }
            else 
                IPAddr{ .v6 = addr_path };
            
            return .{ .prefix = Prefix.init(&ip_addr, total_bits), .ok = true };
        }

        /// hasValue: ノードが値を持つかチェック
        fn hasValue(self: *const Self) bool {
            return !self.prefixes.bitset.isEmpty();
        }

        /// getValueForAddr: 指定されたアドレスに対応する値を取得（値を持つ場合のみ）
        fn getValueForAddr(self: *const Self, addr: u8, path: [16]u8, depth: usize, is4: bool) V {
            _ = addr;
            _ = path;
            _ = depth;
            _ = is4;
            
            // 最初のプレフィックスの値を返す（hasValue()でチェック済み）
            var buf: [256]u8 = undefined;
            const indices = self.prefixes.bitset.asSlice(&buf);
            
            if (indices.len > 0) {
                return self.prefixes.mustGet(indices[0]);
            }
            
            // ここに到達することはないはず（hasValue()でチェック済み）
            unreachable;
        }

        /// idxToPrefix: インデックスからプレフィックスを復元
        fn idxToPrefix(idx: u8, path: [16]u8, depth: usize, is4: bool) struct { prefix: Prefix, ok: bool } {
            // Go実装: reconstruct prefix from index, path, and depth
            const bits = base_index_ext.idxToBits(idx);
            if (bits == 0) {
                return .{ .prefix = undefined, .ok = false };
            }
            
            const prefix_bits = @as(u8, @intCast(depth * 8 + bits));
            if (is4 and prefix_bits > 32) {
                return .{ .prefix = undefined, .ok = false };
            }
            if (!is4 and prefix_bits > 128) {
                return .{ .prefix = undefined, .ok = false };
            }
            
            if (is4) {
                var addr_bytes: [4]u8 = .{0, 0, 0, 0};
                const copy_len = @min(depth, 4);
                for (0..copy_len) |i| {
                    addr_bytes[i] = path[i];
                }
                
                // インデックスから最後のオクテットを復元
                if (depth < 4) {
                    const last_octet = base_index_ext.idxToOctet(idx);
                    addr_bytes[depth] = last_octet;
                }
                
                const addr = IPAddr{ .v4 = addr_bytes };
                return .{ .prefix = Prefix.init(&addr, prefix_bits), .ok = true };
            } else {
                var addr_bytes: [16]u8 = .{0} ** 16;
                const copy_len = @min(depth, 16);
                for (0..copy_len) |i| {
                    addr_bytes[i] = path[i];
                }
                
                // インデックスから最後のオクテットを復元
                if (depth < 16) {
                    const last_octet = base_index_ext.idxToOctet(idx);
                    addr_bytes[depth] = last_octet;
                }
                
                const addr = IPAddr{ .v6 = addr_bytes };
                return .{ .prefix = Prefix.init(&addr, prefix_bits), .ok = true };
            }
        }

        /// addrToPrefix: アドレスからプレフィックスを復元
        fn addrToPrefix(addr: u8, path: [16]u8, depth: usize, is4: bool) struct { prefix: Prefix, ok: bool } {
            // Go実装: reconstruct prefix from address, path, and depth
            const prefix_bits = @as(u8, @intCast((depth + 1) * 8));
            if (is4 and prefix_bits > 32) {
                return .{ .prefix = undefined, .ok = false };
            }
            if (!is4 and prefix_bits > 128) {
                return .{ .prefix = undefined, .ok = false };
            }
            
            if (is4) {
                var addr_bytes: [4]u8 = .{0, 0, 0, 0};
                const copy_len = @min(depth, 4);
                for (0..copy_len) |i| {
                    addr_bytes[i] = path[i];
                }
                
                // 現在のアドレスを追加
                if (depth < 4) {
                    addr_bytes[depth] = addr;
                }
                
                const ip_addr = IPAddr{ .v4 = addr_bytes };
                return .{ .prefix = Prefix.init(&ip_addr, prefix_bits), .ok = true };
            } else {
                var addr_bytes: [16]u8 = .{0} ** 16;
                const copy_len = @min(depth, 16);
                for (0..copy_len) |i| {
                    addr_bytes[i] = path[i];
                }
                
                // 現在のアドレスを追加
                if (depth < 16) {
                    addr_bytes[depth] = addr;
                }
                
                const ip_addr = IPAddr{ .v6 = addr_bytes };
                return .{ .prefix = Prefix.init(&ip_addr, prefix_bits), .ok = true };
            }
        }

        /// compareTrieItemByPrefix: TrieItemをプレフィックスでソートするための比較関数
        fn compareTrieItemByPrefix(comptime ValueType: type) fn (void, TrieItem(ValueType), TrieItem(ValueType)) bool {
            return struct {
                fn compare(_: void, a: TrieItem(ValueType), b: TrieItem(ValueType)) bool {
                    return a.cidr.bits < b.cidr.bits;
                }
            }.compare;
        }

        /// fprintRecProper: 階層的なツリー表示（Go実装互換）
        pub fn fprintRecProper(self: *const Self, allocator: std.mem.Allocator, writer: anytype, parent_idx: u8, path: [16]u8, depth: usize, indent: []const u8) !void {
            _ = parent_idx;
            
            // 簡易実装: プレフィックスを表示
            var buf: [256]u8 = undefined;
            const indices = self.prefixes.bitset.asSlice(&buf);
            
            for (indices) |idx| {
                const value = self.prefixes.mustGet(idx);
                try writer.print("{s}├─ idx={} value={}\n", .{ indent, idx, value });
            }
            
            // 子ノードを表示
            var child_buf: [256]u8 = undefined;
            const child_addrs = self.children.bitset.asSlice(&child_buf);
            
            for (child_addrs) |addr| {
                const child = self.children.mustGet(addr);
                try writer.print("{s}├─ [{}]\n", .{ indent, addr });
                
                const new_indent = try std.fmt.allocPrint(allocator, "{s}│  ", .{indent});
                defer allocator.free(new_indent);
                
                switch (child) {
                    .node => |node| {
                        try node.fprintRecProper(allocator, writer, addr, path, depth + 1, new_indent);
                    },
                    .leaf => |leaf| {
                        try writer.print("{s}├─ leaf: {} -> {}\n", .{ new_indent, leaf.prefix, leaf.value });
                    },
                    .fringe => |fringe| {
                        try writer.print("{s}├─ fringe: {}\n", .{ new_indent, fringe.value });
                    },
                }
            }
        }

        /// unionRec combines two nodes, changing the receiver node.
        /// If there are duplicate entries, the value is taken from the other node.
        /// Count duplicate entries to adjust the t.size struct members.
        /// The values are cloned before merging.
        pub fn unionRec(self: *Self, other: *const Self, depth: u32) u32 {
            var duplicates: u32 = 0;
            
                    // For all prefixes in other node do ...
        var prefix_buf: [256]u8 = undefined;
        const other_indices = other.prefixes.bitset.asSlice(&prefix_buf);
        for (other_indices) |other_idx| {
            // Clone/copy the value from other node at idx
            const cloned_val = cloneOrCopy(V, other.prefixes.mustGet(other_idx));
            
            // Insert/overwrite cloned value from other into self
            if (!self.prefixes.insertAt(other_idx, cloned_val)) {
                // This prefix is duplicate in self and other
                duplicates += 1;
            }
        }
        
        // For all child addrs in other node do ...
        var child_buf: [256]u8 = undefined;
        const other_child_addrs = other.children.bitset.asSlice(&child_buf);
                for (other_child_addrs) |addr| {
            // 12 possible combinations to union this child and other child
            //
            // THIS,   OTHER: (always clone the other kid!)
            // --------------
            // NULL,   node    <-- insert node at addr
            // NULL,   leaf    <-- insert leaf at addr
            // NULL,   fringe  <-- insert fringe at addr
            //
            // node,   node    <-- union rec-descent with node
            // node,   leaf    <-- insert leaf at depth+1
            // node,   fringe  <-- insert fringe at depth+1
            //
            // leaf,   node    <-- insert new node, push this leaf down, union rec-descent
            // leaf,   leaf    <-- insert new node, push both leaves down (!first check equality)
            // leaf,   fringe  <-- insert new node, push this leaf and fringe down
            //
            // fringe, node    <-- insert new node, push this fringe down, union rec-descent
            // fringe, leaf    <-- insert new node, push this fringe down, insert other leaf at depth+1
            // fringe, fringe  <-- just overwrite value
            
            // Try to get child at same addr from self
            const this_child_result = self.children.get(addr);
            if (this_child_result == null) {
                // NULL, ... slot at addr is empty
                const other_child = other.children.mustGet(addr);
                switch (other_child) {
                        .node => |other_node| {
                            // NULL, node
                            const cloned_node = other_node.cloneRec(self.allocator);
                            _ = self.children.insertAt(addr, Child(V){ .node = cloned_node });
                        },
                        .leaf => |other_leaf| {
                            // NULL, leaf
                            const cloned_leaf = other_leaf.cloneLeaf();
                            _ = self.children.insertAt(addr, Child(V){ .leaf = cloned_leaf });
                        },
                        .fringe => |other_fringe| {
                            // NULL, fringe
                            const cloned_fringe = other_fringe.cloneFringe();
                            _ = self.children.insertAt(addr, Child(V){ .fringe = cloned_fringe });
                        },
                    }
                    continue;
                }
                
                            const this_child = this_child_result.?;
            switch (this_child) {
                .node => |this_node| {
                    // node, ...
                    const other_child = other.children.mustGet(addr);
                    switch (other_child) {
                            .node => |other_node| {
                                // node, node
                                // Both childs have node at addr, call union rec-descent on child nodes
                                const cloned_other_node = other_node.cloneRec(self.allocator);
                                duplicates += this_node.unionRec(cloned_other_node, depth + 1);
                                // Clean up the cloned node since it's been merged
                                cloned_other_node.deinit();
                                self.allocator.destroy(cloned_other_node);
                            },
                            .leaf => |other_leaf| {
                                // node, leaf
                                // Push this cloned leaf down, count duplicate entry
                                const cloned_leaf = other_leaf.cloneLeaf();
                                            if (this_node.insertAtDepth(&cloned_leaf.prefix, cloned_leaf.value, depth + 1, self.allocator)) {
                duplicates += 1;
            }
                            },
                            .fringe => |other_fringe| {
                                // node, fringe
                                // Push this fringe down, a fringe becomes a default route one level down
                                const cloned_fringe = other_fringe.cloneFringe();
                                if (this_node.prefixes.insertAt(1, cloned_fringe.value)) {
                                    duplicates += 1;
                                }
                            },
                        }
                    },
                                    .leaf => |this_leaf| {
                    // leaf, ...
                    const other_child = other.children.mustGet(addr);
                    switch (other_child) {
                            .node => |other_node| {
                                // leaf, node
                                // Create new node - OPTIMIZED
                                const new_node = Self.newNode(self.allocator);
                                
                                // Push this leaf down
                                _ = new_node.insertAtDepth(&this_leaf.prefix, this_leaf.value, depth + 1, self.allocator);
                                
                                // Insert the new node at current addr
                                _ = self.children.insertAt(addr, Child(V){ .node = new_node });
                                
                                // unionRec this new node with other kid node
                                const cloned_other_node = other_node.cloneRec(self.allocator);
                                duplicates += new_node.unionRec(cloned_other_node, depth + 1);
                                // Clean up the cloned node
                                cloned_other_node.deinit();
                                self.allocator.destroy(cloned_other_node);
                            },
                            .leaf => |other_leaf| {
                                // leaf, leaf
                                // Shortcut, prefixes are equal
                                if (this_leaf.prefix.eql(other_leaf.prefix)) {
                                    const cloned_val = cloneOrCopy(V, other_leaf.value);
                                    // Update the existing leaf's value
                                    const updated_leaf = LeafNode(V){ .prefix = this_leaf.prefix, .value = cloned_val };
                                    _ = self.children.insertAt(addr, Child(V){ .leaf = updated_leaf });
                                    duplicates += 1;
                                    continue;
                                }
                                
                                // Create new node - OPTIMIZED
                                const new_node = Self.newNode(self.allocator);
                                
                                // Push this leaf down
                                _ = new_node.insertAtDepth(&this_leaf.prefix, this_leaf.value, depth + 1, self.allocator);
                                
                                // Insert at depth cloned leaf, maybe duplicate
                                const cloned_leaf = other_leaf.cloneLeaf();
                                if (new_node.insertAtDepth(&cloned_leaf.prefix, cloned_leaf.value, depth + 1, self.allocator)) {
                                    duplicates += 1;
                                }
                                
                                // Insert the new node at current addr
                                _ = self.children.insertAt(addr, Child(V){ .node = new_node });
                            },
                            .fringe => |other_fringe| {
                                // leaf, fringe
                                // Create new node - OPTIMIZED
                                const new_node = Self.newNode(self.allocator);
                                
                                // Push this leaf down
                                _ = new_node.insertAtDepth(&this_leaf.prefix, this_leaf.value, depth + 1, self.allocator);
                                
                                // Push this cloned fringe down, it becomes the default route
                                const cloned_fringe = other_fringe.cloneFringe();
                                if (new_node.prefixes.insertAt(1, cloned_fringe.value)) {
                                    duplicates += 1;
                                }
                                
                                // Insert the new node at current addr
                                _ = self.children.insertAt(addr, Child(V){ .node = new_node });
                            },
                        }
                    },
                                    .fringe => |this_fringe| {
                    // fringe, ...
                    const other_child = other.children.mustGet(addr);
                    switch (other_child) {
                            .node => |other_node| {
                                // fringe, node
                                // Create new node - OPTIMIZED
                                const new_node = Self.newNode(self.allocator);
                                
                                // Push this fringe down, it becomes the default route
                                _ = new_node.prefixes.insertAt(1, this_fringe.value);
                                
                                // Insert the new node at current addr
                                _ = self.children.insertAt(addr, Child(V){ .node = new_node });
                                
                                // unionRec this new node with other kid node
                                const cloned_other_node = other_node.cloneRec(self.allocator);
                                duplicates += new_node.unionRec(cloned_other_node, depth + 1);
                                // Clean up the cloned node
                                cloned_other_node.deinit();
                                self.allocator.destroy(cloned_other_node);
                            },
                            .leaf => |other_leaf| {
                                // fringe, leaf
                                // Create new node - OPTIMIZED
                                const new_node = Self.newNode(self.allocator);
                                
                                // Push this fringe down, it becomes the default route
                                _ = new_node.prefixes.insertAt(1, this_fringe.value);
                                
                                // Push this cloned leaf down
                                const cloned_leaf = other_leaf.cloneLeaf();
                                if (new_node.insertAtDepth(&cloned_leaf.prefix, cloned_leaf.value, depth + 1, self.allocator)) {
                                    duplicates += 1;
                                }
                                
                                // Insert the new node at current addr
                                _ = self.children.insertAt(addr, Child(V){ .node = new_node });
                            },
                            .fringe => |other_fringe| {
                                const cloned_val = cloneOrCopy(V, other_fringe.value);
                                const updated_fringe = FringeNode(V){ .value = cloned_val };
                                _ = self.children.insertAt(addr, Child(V){ .fringe = updated_fringe });
                                duplicates += 1;
                            },
                        }
                    },
                }
            }
            
            return duplicates;
        }

        /// allRecSorted: ソート済みイテレーション機能（CIDRソート順）
        /// Go実装のallRecSortedメソッドを移植
        pub fn allRecSorted(self: *const Self, path: StridePath, depth: usize, is4: bool, yield: *const YieldFn) bool {
            // すべての子アドレスをソート済みで取得（アドレス順）
            var child_buf: [256]u8 = undefined;
            const all_child_addrs = self.children.bitset.asSlice(&child_buf);

            // すべてのインデックスをソート済みで取得（インデックス順）
            var buf: [256]u8 = undefined;
            const all_indices = self.prefixes.bitset.asSlice(&buf);

            // インデックスをCIDRソート順でソート
            var sorted_indices = std.ArrayList(u8).init(std.heap.page_allocator);
            defer sorted_indices.deinit();
            sorted_indices.appendSlice(all_indices) catch return false;

            // Zig標準ライブラリのソート関数を使用
            std.sort.insertion(u8, sorted_indices.items, {}, struct {
                fn lessThan(_: void, a: u8, b: u8) bool {
                    return cmpIndexRank(a, b) < 0;
                }
            }.lessThan);

            var child_cursor: usize = 0;

            // インデックスと子をCIDRソート順でyield
            for (sorted_indices.items) |pfx_idx| {
                const pfx_info = base_index.idxToPfx256(pfx_idx) catch continue;
                const pfx_octet = pfx_info.octet;

                // インデックスより前のすべての子をyield
                while (child_cursor < all_child_addrs.len) {
                    const child_addr = all_child_addrs[child_cursor];

                    if (child_addr >= pfx_octet) {
                        break;
                    }

                    // ノード（再帰降下）またはリーフをyield
                    const kid = self.children.mustGet(child_addr);
                    switch (kid) {
                        .node => |node| {
                            var new_path = path;
                            if (depth < new_path.len) {
                                new_path[depth] = child_addr;
                            }
                            if (!node.allRecSorted(new_path, depth + 1, is4, yield)) {
                                return false;
                            }
                        },
                        .leaf => |leaf| {
                            if (!yield(leaf.prefix, leaf.value)) {
                                return false;
                            }
                        },
                        .fringe => |fringe| {
                            const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, child_addr);
                            // このフリンジのコールバック
                            if (!yield(fringe_pfx, fringe.value)) {
                                // 早期終了
                                return false;
                            }
                        },
                    }

                    child_cursor += 1;
                }

                // このインデックスのプレフィックスをyield
                const cidr = cidrFromPath(path, depth, is4, pfx_idx);
                const value = self.prefixes.mustGet(pfx_idx);
                if (!yield(cidr, value)) {
                    return false;
                }
            }

            // 残りのリーフとノード（再帰降下）をyield
            while (child_cursor < all_child_addrs.len) {
                const addr = all_child_addrs[child_cursor];
                const kid = self.children.mustGet(addr);

                switch (kid) {
                    .node => |node| {
                        var new_path = path;
                        if (depth < new_path.len) {
                            new_path[depth] = addr;
                        }
                        if (!node.allRecSorted(new_path, depth + 1, is4, yield)) {
                            return false;
                        }
                    },
                    .leaf => |leaf| {
                        if (!yield(leaf.prefix, leaf.value)) {
                            return false;
                        }
                    },
                    .fringe => |fringe| {
                        const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                        // このフリンジのコールバック
                        if (!yield(fringe_pfx, fringe.value)) {
                            // 早期終了
                            return false;
                        }
                    },
                }

                child_cursor += 1;
            }

            return true;
        }

        /// NodeStats: ノード統計情報（Go実装のnodeStats互換）
        pub const NodeStats = struct {
            nodes: usize,
            leaves: usize,
            fringes: usize,
            pfxs: usize,
        };

        /// getNodeStats: このノード以下のツリー統計を取得
        pub fn getNodeStats(self: *const Self) NodeStats {
            return self.nodeStatsRec();
        }

        /// nodeStatsRec: 再帰的にノード統計を計算
        fn nodeStatsRec(self: *const Self) NodeStats {
            if (self.isEmpty()) {
                return NodeStats{ .nodes = 0, .leaves = 0, .fringes = 0, .pfxs = 0 };
            }
            
            var stats = NodeStats{ 
                .nodes = 1,  // 現在のノード
                .leaves = 0, 
                .fringes = 0, 
                .pfxs = self.prefixes.len() 
            };
            
            // 子ノードの統計を集計
            var child_buf: [256]u8 = undefined;
            const child_addrs = self.children.bitset.asSlice(&child_buf);
            for (child_addrs) |addr| {
                const child = self.children.mustGet(addr);
                switch (child) {
                    .node => |node| {
                        const child_stats = node.nodeStatsRec();
                        stats.nodes += child_stats.nodes;
                        stats.leaves += child_stats.leaves;
                        stats.fringes += child_stats.fringes;
                        stats.pfxs += child_stats.pfxs;
                    },
                    .leaf => {
                        stats.leaves += 1;
                        stats.pfxs += 1;
                    },
                    .fringe => {
                        stats.fringes += 1;
                        stats.pfxs += 1;
                    },
                }
            }
            
            return stats;
        }

        /// dumpRec: 詳細なデバッグ情報出力（Go実装のdumper.go互換）
        pub fn dumpRec(self: *const Self, allocator: std.mem.Allocator, writer: anytype, path: [16]u8, depth: usize, is4: bool) !void {
            // ノードの基本情報を出力
            const indent = try allocator.alloc(u8, depth);
            defer allocator.free(indent);
            for (indent) |*c| {
                c.* = '.';
            }
            
            const bits = depth * 8;
            
            // ノード情報の出力
            try writer.print("\n{s}[{s}] depth: {} path: [{s}] / {}\n", 
                .{ indent, self.hasType(), depth, self.formatPath(path, depth, is4), bits });
            
            // プレフィックス情報の出力
            if (self.prefixes.len() > 0) {
                var prefix_buf: [256]u8 = undefined;
                const indices = self.prefixes.bitset.asSlice(&prefix_buf);
                
                try writer.print("{s}prefxs(#{}):", .{ indent, self.prefixes.len() });
                for (indices) |idx| {
                    const pfx = cidrFromPath(path, depth, is4, idx);
                    try writer.print(" {}", .{pfx});
                }
                try writer.print("\n", .{});
                
                // 値の出力（空の構造体以外）
                if (V != struct{}) {
                    try writer.print("{s}values(#{}):", .{ indent, self.prefixes.len() });
                    for (indices) |idx| {
                        const val = self.prefixes.mustGet(idx);
                        try writer.print(" {}", .{val});
                    }
                    try writer.print("\n", .{});
                }
            }
            
            // 子ノード情報の出力
            if (self.children.len() > 0) {
                var child_addrs = std.ArrayList(u8).init(allocator);
                defer child_addrs.deinit();
                var leaf_addrs = std.ArrayList(u8).init(allocator);
                defer leaf_addrs.deinit();
                var fringe_addrs = std.ArrayList(u8).init(allocator);
                defer fringe_addrs.deinit();
                
                // 子ノードを分類
                var child_buf: [256]u8 = undefined;
                const all_addrs = self.children.bitset.asSlice(&child_buf);
                for (all_addrs) |addr| {
                    const child = self.children.mustGet(addr);
                    switch (child) {
                        .node => try child_addrs.append(addr),
                        .leaf => try leaf_addrs.append(addr),
                        .fringe => try fringe_addrs.append(addr),
                    }
                }
                
                // オクテット表示
                try writer.print("{s}octets(#{}):\n", .{ indent, self.children.len() });
                
                // リーフノード表示
                if (leaf_addrs.items.len > 0) {
                    try writer.print("{s}leaves(#{}):", .{ indent, leaf_addrs.items.len });
                    for (leaf_addrs.items) |addr| {
                        const leaf = self.children.mustGet(addr).leaf;
                        
                        if (V == struct{}) {
                            try writer.print(" {s}:{{{}}}", .{ self.addrFmt(addr, is4), leaf.prefix });
                        } else {
                            try writer.print(" {s}:{{{}, {}}}", .{ self.addrFmt(addr, is4), leaf.prefix, leaf.value });
                        }
                    }
                    try writer.print("\n", .{});
                }
                
                // フリンジノード表示
                if (fringe_addrs.items.len > 0) {
                    try writer.print("{s}fringe(#{}):", .{ indent, fringe_addrs.items.len });
                    for (fringe_addrs.items) |addr| {
                        const fringe = self.children.mustGet(addr).fringe;
                        const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                        
                        if (V == struct{}) {
                            try writer.print(" {s}:{{{}}}", .{ self.addrFmt(addr, is4), fringe_pfx });
                        } else {
                            try writer.print(" {s}:{{{}, {}}}", .{ self.addrFmt(addr, is4), fringe_pfx, fringe.value });
                        }
                    }
                    try writer.print("\n", .{});
                }
                
                // 子ノード表示
                if (child_addrs.items.len > 0) {
                    try writer.print("{s}childs(#{}):", .{ indent, child_addrs.items.len });
                    for (child_addrs.items) |addr| {
                        try writer.print(" {s}", .{self.addrFmt(addr, is4)});
                    }
                    try writer.print("\n", .{});
                }
            }
            
            // 子ノードに対して再帰的にdump
            var child_buf: [256]u8 = undefined;
            const all_child_addrs = self.children.bitset.asSlice(&child_buf);
            for (all_child_addrs) |addr| {
                const child = self.children.mustGet(addr);
                switch (child) {
                    .node => |node| {
                        var next_path = path;
                        next_path[depth & 15] = addr;
                        try node.dumpRec(allocator, writer, next_path, depth + 1, is4);
                    },
                    else => {}, // リーフとフリンジは上で表示済み
                }
            }
        }

        /// hasType: ノードタイプを判定（Go実装のnodeType互換）
        fn hasType(self: *const Self) []const u8 {
            const has_prefixes = self.prefixes.len() > 0;
            const has_children = self.children.len() > 0;
            
            var child_nodes: usize = 0;
            var leaf_nodes: usize = 0;
            var fringe_nodes: usize = 0;
            
            var child_buf: [256]u8 = undefined;
            const child_addrs = self.children.bitset.asSlice(&child_buf);
            for (child_addrs) |addr| {
                const child = self.children.mustGet(addr);
                switch (child) {
                    .node => child_nodes += 1,
                    .leaf => leaf_nodes += 1,
                    .fringe => fringe_nodes += 1,
                }
            }
            
            if (!has_prefixes and !has_children) {
                return "NULL";
            } else if (child_nodes == 0) {
                return "STOP";
            } else if ((leaf_nodes > 0 or fringe_nodes > 0) and child_nodes > 0 and !has_prefixes) {
                return "HALF";
            } else if ((has_prefixes or leaf_nodes > 0 or fringe_nodes > 0) and child_nodes > 0) {
                return "FULL";
            } else if (!has_prefixes and leaf_nodes == 0 and fringe_nodes == 0 and child_nodes > 0) {
                return "PATH";
            } else {
                return "UNKN";
            }
        }

        /// formatPath: パス表示のフォーマット
        fn formatPath(self: *const Self, path: [16]u8, depth: usize, is4: bool) []const u8 {
            _ = self;
            _ = path;
            _ = depth;
            _ = is4;
            return "path";
        }

        /// addrFmt: アドレスフォーマット（IPv4は10進、IPv6は16進）
        fn addrFmt(self: *const Self, addr: u8, is4: bool) []const u8 {
            _ = self;
            _ = addr;
            if (is4) {
                return "addr";
            } else {
                return "0x??";
            }
        }


        
        /// insertAtDepthForCompress: purgeAndCompress専用の簡易挿入関数
        /// 通常のinsertAtDepthと異なり、圧縮時の再挿入に特化
        fn insertAtDepthForCompress(self: *Self, pfx: *const Prefix, val: V, depth: usize) bool {
            const ip = &pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            const max_depth_info = base_index.maxDepthAndLastBits(bits);
            const max_depth = max_depth_info.max_depth;
            const last_bits = max_depth_info.last_bits;
            
            var current_depth = depth;
            var current_node = self;
            
            // Go実装のinsertAtDepthロジックを簡略化
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];
                
                // 最後のマスクされたオクテット: prefix/valをノードに挿入/上書き
                if (current_depth == max_depth) {
                    return current_node.prefixes.insertAt(base_index.pfxToIdx256(octet, last_bits), val) != null;
                }
                
                // トライパスの終端に到達...
                if (!current_node.children.isSet(octet)) {
                                    // プレフィックスをpath-compressedとしてleafまたはfringeで挿入
                if (base_index.isFringe(current_depth, bits)) {
                    return current_node.children.insertAt(octet, Child(V){ .fringe = FringeNode(V).init(val) }) != null;
                }
                    return current_node.children.insertAt(octet, Child(V){ .leaf = LeafNode(V).init(pfx.*, val) }) != null;
                }
                
                // ...または下位のトライに降りる
                const kid = current_node.children.mustGet(octet);
                
                switch (kid) {
                    .node => |node| {
                        current_node = node;
                        continue;
                    },
                    .leaf => |leaf| {
                        // path-compressedプレフィックスに到達
                        if (leaf.prefix.eql(pfx.*)) {
                            // プレフィックスが等しい場合、値を上書き
                            const new_leaf = Child(V){ .leaf = LeafNode(V).init(pfx.*, val) };
                            _ = current_node.children.insertAt(octet, new_leaf);
                            return true;
                        }
                        
                        // 新しいノードを作成
                        // leafを下にプッシュ
                        // 現在のleaf位置に新しい子を挿入
                        // 降りて、nを新しい子で置換
                        const new_node = Self.newNode(self.allocator);
                        _ = new_node.insertAtDepthForCompress(&leaf.prefix, leaf.value, current_depth + 1);
                        
                        const new_child = Child(V){ .node = new_node };
                        _ = current_node.children.insertAt(octet, new_child);
                        current_node = new_node;
                    },
                    .fringe => |fringe| {
                        // path-compressedのfringeに到達
                        if (base_index.isFringe(current_depth, bits)) {
                            // プレフィックスがfringeの場合、値を上書き
                            const new_fringe = Child(V){ .fringe = FringeNode(V).init(val) };
                            _ = current_node.children.insertAt(octet, new_fringe);
                            return true;
                        }
                        
                        // 新しいノードを作成
                        // fringeを下にプッシュ、デフォルトルートになる (idx=1)
                        // 現在のleaf位置に新しい子を挿入
                        // 降りて、nを新しい子で置換
                        const new_node = Self.newNode(self.allocator);
                        _ = new_node.prefixes.insertAt(1, fringe.value);
                        
                        const new_child = Child(V){ .node = new_node };
                        _ = current_node.children.insertAt(octet, new_child);
                        current_node = new_node;
                    },
                }
            }
            
            return false;
        }

        /// cidrForFringe: helper function,
        /// get prefix back from octets path, depth, IP version and last octet.
        /// The prefix of a fringe is solely defined by the position in the trie.
        /// Go実装のcidrForFringeを移植
        fn cidrForFringe(octets: []const u8, depth: usize, is4: bool, last_octet: u8) Prefix {
            var path: [16]u8 = std.mem.zeroes([16]u8);
            
            // copy existing path
            const copy_len = @min(depth, octets.len, path.len);
            @memcpy(path[0..copy_len], octets[0..copy_len]);
            
            // replace last octet
            if (depth < path.len) {
                path[depth] = last_octet;
            }
            
            // make ip addr from octets
            const ip = if (is4) 
                IPAddr{ .v4 = .{ path[0], path[1], path[2], path[3] } }
            else 
                IPAddr{ .v6 = path };
                
            // it's a fringe, bits are always /8, /16, /24, ...
            const bits = @as(u8, @intCast((depth + 1) * 8));
            
            // return a (normalized) prefix from ip/bits
            return Prefix.init(&ip, bits);
        }



        /// TODO: purgeAndCompressのエラー修正（cidrForFringeFromStack -> cidrForFringe）
        
        /// purgeAndCompress: Go実装のpurgeAndCompressメソッドを移植
        /// 空ノードの削除と単一要素ノードの圧縮を行う
        pub fn purgeAndCompress(self: *Self, stack: []*Self, octets: []const u8, is4: bool) void {
            // Go実装: unwind the stack
            var depth = @as(i32, @intCast(stack.len)) - 1;
            var current_node = self;
            
            while (depth >= 0) : (depth -= 1) {
                const parent = stack[@intCast(depth)];
                const octet = octets[@intCast(depth)];
                
                const pfx_count = current_node.prefixes.len();
                const child_count = current_node.children.len();
                
                if (current_node.isEmpty()) {
                    // Go実装: just delete this empty node from parent
                    _ = parent.children.deleteAt(octet);
                } else if (pfx_count == 0 and child_count == 1) {
                    // Go実装: single child compression logic
                    var child_addrs_buf: [256]u8 = undefined;
                    const child_addrs = current_node.children.bitset.asSlice(&child_addrs_buf);
                    
                    if (child_addrs.len == 1) {
                        const child_addr = child_addrs[0];
                        const kid = current_node.children.mustGet(child_addr);
                        
                        switch (kid) {
                            .node => {
                                // Go実装: fast exit, we are at an intermediate path node
                                // no further delete/compress upwards the stack is possible
                                return;
                            },
                            .leaf => |leaf| {
                                // Go実装: just one leaf, delete this node and reinsert the leaf above
                                _ = parent.children.deleteAt(octet);
                                
                                // ... (re)insert the leaf at parents depth
                                _ = parent.insertAtDepthForCompress(&leaf.prefix, leaf.value, @intCast(depth));
                            },
                            .fringe => |fringe| {
                                // Go実装: just one fringe, delete this node and reinsert the fringe as leaf above
                                _ = parent.children.deleteAt(octet);
                                
                                // get the last octet back, the only item is also the first item
                                const last_octet = child_addr;
                                
                                // rebuild the prefix with octets, depth, ip version and addr
                                // depth is the parent's depth, so add +1 here for the kid
                                const fringe_pfx = cidrForFringe(octets, @intCast(depth + 1), is4, last_octet);
                                
                                // ... (re)reinsert prefix/value at parents depth
                                _ = parent.insertAtDepthForCompress(&fringe_pfx, fringe.value, @intCast(depth));
                            },
                        }
                    }
                } else {
                    // Go実装: node has both prefixes and children, or multiple children
                    // no compression possible, stop here
                    return;
                }
                
                // Move up to parent for next iteration
                current_node = parent;
            }
        }

        /// contains implements ultra-fast address containment testing.



        
        /// newNode - Ultra-optimized node creation for maximum Insert performance  
        /// Phase 3 Final: Switched to createZeroNode for 15 ns/op target
        inline fn newNode(allocator: std.mem.Allocator) *Self {
            return createZeroNode(allocator);
        }
        
        /// newPooledNode - Memory pool optimized node creation
        /// Uses memory pool when available for maximum performance
        inline fn newPooledNode(allocator: std.mem.Allocator, node_pool: ?*NodePool(V)) *Self {
            if (node_pool) |pool| {
                if (pool.allocateNode()) |node| {
                    // ノードは既にクリーンな状態で返される
                    return node;
                }
                // プールから取得に失敗した場合は通常の確保
            }
            
            // Fallback to regular allocation
            return newNode(allocator);
        }
        

        
        /// insertAtDepthPooled - High-performance version for Table operations
        /// Uses memory pool when available for maximum performance
        pub fn insertAtDepthPooled(self: *Self, pfx: *const Prefix, val: V, depth: usize, allocator: std.mem.Allocator, node_pool: ?*NodePool(V)) bool {
            const ip = &pfx.addr;
            const bits = pfx.bits;
            const octets = ip.asSlice();
            const max_depth = bits >> 3;
            const last_bits = @as(u8, @intCast(bits & 7));
            
            var n = self;
            var current_depth = depth;
            
            // Go BART style: simple for loop with minimal overhead
            while (current_depth < octets.len) {
                const octet = octets[current_depth];
                
                // last masked octet: insert/override prefix/val into node
                if (current_depth == max_depth) {
                    const idx = base_index.pfxToIdx256(octet, last_bits);
                    return n.prefixes.insertAt(idx, val);
                }
                
                // reached end of trie path: insert path compressed
                if (!n.children.isSet(octet)) {
                    if (base_index.isFringe(current_depth, bits)) {
                        return n.children.insertAt(octet, Child(V){ .fringe = FringeNode(V).init(val) });
                    }
                    return n.children.insertAt(octet, Child(V){ .leaf = LeafNode(V).init(pfx.*, val) });
                }
                
                // descend down the trie
                const kid = n.children.mustGet(octet);
                
                switch (kid) {
                    .node => |node_ptr| {
                        n = node_ptr;
                        current_depth += 1;
                    },
                    .leaf => |leaf| {
                        // override value if prefixes are equal
                        if (leaf.prefix.eql(pfx.*)) {
                            const new_leaf = Child(V){ .leaf = LeafNode(V).init(pfx.*, val) };
                            _ = n.children.replaceAt(octet, new_leaf);
                            return true; // exists
                        }
                        
                        // Memory pool optimized node creation
                        const new_node = Self.newPooledNode(allocator, node_pool);
                        _ = new_node.insertAtDepthPooled(&leaf.prefix, leaf.value, current_depth + 1, allocator, node_pool);
                        
                        _ = n.children.replaceAt(octet, Child(V){ .node = new_node });
                        n = new_node;
                        current_depth += 1;
                    },
                    .fringe => |fringe| {
                        // override value if pfx is a fringe
                        if (base_index.isFringe(current_depth, bits)) {
                            const new_fringe = Child(V){ .fringe = FringeNode(V).init(val) };
                            _ = n.children.replaceAt(octet, new_fringe);
                            return true; // exists
                        }
                        
                        // Memory pool optimized node creation
                        const new_node = Self.newPooledNode(allocator, node_pool);
                        _ = new_node.prefixes.insertAt(1, fringe.value);
                        
                        _ = n.children.replaceAt(octet, Child(V){ .node = new_node });
                        n = new_node;
                        current_depth += 1;
                    },
                }
            }
            
            unreachable;
        }

        /// createZeroNode - Ultra-optimized node creation for Go BART 15 ns/op target
        /// Phase 3 Final: Eliminates @memset overhead and uses direct initialization
        inline fn createZeroNode(allocator: std.mem.Allocator) *Self {
            const node = allocator.create(Self) catch unreachable;
            // Direct field initialization - faster than memset + reassignment
            node.* = Self{
                .children = Array256(Child(V)).init(allocator),
                .prefixes = Array256(V).init(allocator),
                .allocator = allocator,
            };
            return node;
        }
        
        /// reset - ノードを初期状態にリセット（NodePool再利用用）
        /// Contains/Lookupには一切影響しない（Insert/Delete専用）
        pub fn reset(self: *Self) void {
            // 子ノードとプレフィックスを完全にクリア
            self.children.clearAll();
            self.prefixes.clearAll();
            
            // allocatorはそのまま保持（重要）
            // Phase 3: リリースビルドでも安全な確認
            if (std.debug.runtime_safety) {
                std.debug.assert(self.children.len() == 0);
                std.debug.assert(self.prefixes.len() == 0);
            }
        }

        /// insertAtDepth - Ultra-optimized insert operation for Go BART 15 ns/op target
        /// Phase 3 Final: Optimized inlining + branch prediction + rank optimization + fast node creation
        pub inline fn insertAtDepth(self: *Self, pfx: *const Prefix, val: V, depth: usize, allocator: std.mem.Allocator) bool {
            // Pre-cache all values to minimize memory access
            const bits = pfx.bits;
            const octets = pfx.addr.asSlice();
            const max_depth = bits >> 3;
            const last_bits = @as(u8, @intCast(bits & 7));
            
            var n = self;
            var d = depth;
            
            // Go BART style: ultra-optimized loop with minimal overhead
            while (d < octets.len) : (d += 1) {
                const octet = octets[d];
                
                // HOTTEST PATH: Terminal condition (最頻繁 - 最初に配置)
                if (d == max_depth) {
                    return n.prefixes.insertAt(base_index.pfxToIdx256(octet, last_bits), val);
                }
                
                // HOT PATH: Child exists (2番目に頻繁) - rank計算を1回だけ
                if (n.children.isSet(octet)) {
                    const rank_idx = n.children.bitset.rank(octet) - 1;
                    const kid = n.children.items.items[rank_idx];
                    
                    switch (kid) {
                        .node => |node_ptr| {
                            n = node_ptr;
                            // Continue with d incremented automatically
                        },
                        .leaf => |leaf| {
                            // Fast equality check first (common case)
                            if (leaf.prefix.eql(pfx.*)) {
                                n.children.items.items[rank_idx] = Child(V){ .leaf = LeafNode(V).init(pfx.*, val) };
                                return true;
                            }
                            
                            // Collision case - use fastest node creation
                            const new_node = Self.newNode(allocator);
                            _ = new_node.insertAtDepth(&leaf.prefix, leaf.value, d + 1, allocator);
                            
                            n.children.items.items[rank_idx] = Child(V){ .node = new_node };
                            n = new_node;
                        },
                        .fringe => |fringe| {
                            // Fast fringe check first (common case)
                            if (base_index.isFringe(d, bits)) {
                                n.children.items.items[rank_idx] = Child(V){ .fringe = FringeNode(V).init(val) };
                                return true;
                            }
                            
                            // Collision case - use fastest node creation
                            const new_node = Self.newNode(allocator);
                            _ = new_node.prefixes.insertAt(1, fringe.value);
                            
                            n.children.items.items[rank_idx] = Child(V){ .node = new_node };
                            n = new_node;
                        },
                    }
                } else {
                    // COOL PATH: New insertion (最も稀 - 最後に配置)
                    if (base_index.isFringe(d, bits)) {
                        return n.children.insertAt(octet, Child(V){ .fringe = FringeNode(V).init(val) });
                    }
                    return n.children.insertAt(octet, Child(V){ .leaf = LeafNode(V).init(pfx.*, val) });
                }
            }
            
            unreachable;
        }


    };
}

/// leafNode is a prefix with value, used as a path compressed child.
pub fn LeafNode(comptime V: type) type {
    return struct {
        const Self = @This();
        
        prefix: Prefix,
        value: V,
        
        pub fn init(prefix: Prefix, value: V) Self {
            return Self{ .prefix = prefix, .value = value };
        }
        
        /// cloneLeaf returns a clone of the leaf
        /// if the value implements the Cloner interface.
        pub fn cloneLeaf(self: *const Self) Self {
            return Self{ .prefix = self.prefix, .value = self.value };
        }
    };
}

/// fringeNode is a path-compressed leaf with value but without a prefix.
/// The prefix of a fringe is solely defined by the position in the trie.
/// The fringe-compression (no stored prefix) saves a lot of memory,
/// but the algorithm is more complex.
pub fn FringeNode(comptime V: type) type {
    return struct {
        const Self = @This();
        
        value: V,
        
        pub fn init(value: V) Self {
            return Self{ .value = value };
        }
        
        /// cloneFringe returns a clone of the fringe
        /// if the value implements the Cloner interface.
        pub fn cloneFringe(self: *const Self) Self {
            return Self{ .value = self.value };
        }
    };
}

/// Child represents either a node, leaf, or fringe
pub fn Child(comptime V: type) type {
    return union(enum) {
        node: *Node(V),
        leaf: LeafNode(V),
        fringe: FringeNode(V),
    };
}

/// Prefix represents an IP prefix with address and bit length
pub const Prefix = struct {
    addr: IPAddr,
    bits: u8,
    
    pub fn init(addr: *const IPAddr, bits: u8) Prefix {
        const pfx = Prefix{ .addr = addr.*, .bits = bits };
        return pfx;
    }
    
    pub fn eql(self: Prefix, other: Prefix) bool {
        return self.addr.eql(other.addr) and self.bits == other.bits;
    }
    
    /// isValid checks if the prefix is valid
    pub fn isValid(self: Prefix) bool {
        switch (self.addr) {
            .v4 => return self.bits <= 32,
            .v6 => return self.bits <= 128,
        }
    }
    
    /// masked returns the canonical form of the prefix
    pub fn masked(self: *const Prefix) Prefix {
        if (!self.isValid()) return self.*;
        const masked_addr = self.addr.masked(self.bits);
        return Prefix.init(&masked_addr, self.bits);
    }

    /// 指定アドレスがこのプレフィックスに含まれるか判定
    pub fn containsAddr(self: Prefix, addr: IPAddr) bool {
        // bits長でマスクして比較
        const masked_addr = addr.masked(self.bits);
        return self.addr.eql(masked_addr);
    }

    /// overlaps checks if this prefix overlaps with another prefix
    /// Go実装のPrefix.Overlapsメソッドを移植
    pub fn overlaps(self: *const Prefix, other: *const Prefix) bool {
        // 短い方のプレフィックス長を使用
        const min_bits = if (self.bits < other.bits) self.bits else other.bits;
        
        // 両方のアドレスを短い方の長さでマスク
        const self_masked = self.addr.masked(min_bits);
        const other_masked = other.addr.masked(min_bits);
        
        // マスクされたアドレスが同じならオーバーラップ
        return self_masked.eql(other_masked);
    }

    /// Format function for std.debug.print - CIDR notation
    pub fn format(self: Prefix, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        
        switch (self.addr) {
            .v4 => |v4| {
                try writer.print("{}.{}.{}.{}/{}", .{ v4[0], v4[1], v4[2], v4[3], self.bits });
            },
            .v6 => |v6| {
                // IPv6のCIDR表記を作成
                try writer.print("{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}/{}", .{
                    v6[0], v6[1], v6[2], v6[3], v6[4], v6[5], v6[6], v6[7],
                    v6[8], v6[9], v6[10], v6[11], v6[12], v6[13], v6[14], v6[15],
                    self.bits
                });
            },
        }
    }
};

/// IPAddr represents an IPv4 or IPv6 address
pub const IPAddr = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
    
    pub fn eql(self: IPAddr, other: IPAddr) bool {
        switch (self) {
            .v4 => |self_v4| {
                switch (other) {
                    .v4 => |other_v4| return std.mem.eql(u8, &self_v4, &other_v4),
                    .v6 => return false,
                }
            },
            .v6 => |self_v6| {
                switch (other) {
                    .v4 => return false,
                    .v6 => |other_v6| return std.mem.eql(u8, &self_v6, &other_v6),
                }
            },
        }
    }
    
    pub fn asSlice(self: *const IPAddr) []const u8 {
        return switch (self.*) {
            .v4 => |*v4| v4[0..],
            .v6 => |*v6| v6[0..],
        };
    }
    
    pub fn is4(self: IPAddr) bool {
        return switch (self) {
            .v4 => true,
            .v6 => false,
        };
    }
    
    /// Format function for std.debug.print
    pub fn format(self: IPAddr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .v4 => |v4| {
                try writer.print("IPv4({}.{}.{}.{})", .{v4[0], v4[1], v4[2], v4[3]});
            },
            .v6 => |v6| {
                try writer.print("IPv6({x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2})", .{
                    v6[0], v6[1], v6[2], v6[3], v6[4], v6[5], v6[6], v6[7],
                    v6[8], v6[9], v6[10], v6[11], v6[12], v6[13], v6[14], v6[15]
                });
            },
        }
    }
    
    /// masked applies a network mask to the address
    pub fn masked(self: IPAddr, bits: u8) IPAddr {
        switch (self) {
            .v4 => |v4| {
                if (bits == 0) {
                    return IPAddr{ .v4 = .{ 0, 0, 0, 0 } };
                }
                if (bits >= 32) {
                    return IPAddr{ .v4 = v4 };
                }
                const mask = @as(u32, 0xffffffff) << @as(u5, @intCast(32 - bits));
                const addr = std.mem.readInt(u32, &v4, .big);
                const masked_addr = addr & mask;
                var result: [4]u8 = undefined;
                std.mem.writeInt(u32, &result, masked_addr, .big);
                return IPAddr{ .v4 = result };
            },
            .v6 => |v6| {
                if (bits == 0) {
                    return IPAddr{ .v6 = .{0} ** 16 };
                }
                if (bits >= 128) {
                    return IPAddr{ .v6 = v6 };
                }
                
                // IPv6のマスク処理を実装
                var result: [16]u8 = v6;
                const full_bytes = bits / 8;
                const remaining_bits = bits % 8;
                
                // 完全なバイトのマスク
                var i: usize = full_bytes;
                while (i < 16) : (i += 1) {
                    result[i] = 0;
                }
                
                // 部分的なバイトのマスク
                if (remaining_bits > 0 and full_bytes < 16) {
                    const mask = @as(u8, 0xff) << @as(u3, @intCast(8 - remaining_bits));
                    result[full_bytes] &= mask;
                }
                
                return IPAddr{ .v6 = result };
            },
        }
    }
};

/// overlapsTwoChilds checks if two children overlap
/// Go実装のoverlapsTwoChildsを移植
fn overlapsTwoChilds(comptime V: type, n_child: Child(V), o_child: Child(V), depth: usize) bool {
    //  3x3 possible different combinations for n and o
    //
    //  node, node    --> overlaps rec descent
    //  node, leaf    --> overlapsPrefixAtDepth
    //  node, fringe  --> true
    //
    //  leaf, node    --> overlapsPrefixAtDepth
    //  leaf, leaf    --> Prefix.overlaps
    //  leaf, fringe  --> true
    //
    //  fringe, node    --> true
    //  fringe, leaf    --> true
    //  fringe, fringe  --> true
    //
    switch (n_child) {
        .node => |n_kind| {
            switch (o_child) {
                .node => |o_kind| { // node, node
                    return n_kind.overlaps(o_kind, depth);
                },
                .leaf => |o_kind| { // node, leaf
                    return n_kind.overlapsPrefixAtDepth(&o_kind.prefix, depth);
                },
                .fringe => { // node, fringe
                    return true;
                },
            }
        },
        .leaf => |n_kind| {
            switch (o_child) {
                .node => |o_kind| { // leaf, node
                    return o_kind.overlapsPrefixAtDepth(&n_kind.prefix, depth);
                },
                .leaf => |o_kind| { // leaf, leaf
                    return o_kind.prefix.overlaps(&n_kind.prefix);
                },
                .fringe => { // leaf, fringe
                    return true;
                },
            }
        },
        .fringe => {
            return true;
        },
    }
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

/// TrieItem型の定義
pub fn TrieItem(comptime T: type) type {
    return struct {
        node: ?*Node(T),
        is4: bool,
        path: [16]u8,
        depth: usize,
        idx: u8,
        cidr: Prefix,
        value: T,
    };
}

/// DumpListNode型の定義
pub fn DumpListNode(comptime T: type) type {
    return struct {
        cidr: Prefix,
        value: T,
        subnets: []@This(),
        
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.subnets) |*subnet| {
                subnet.deinit(allocator);
            }
            allocator.free(self.subnets);
        }
    };
}

/// base_indexモジュールの不足関数を追加
const base_index_ext = struct {
    /// idxToBits: インデックスからビット数を取得
    fn idxToBits(idx: u8) u8 {
        if (idx == 0) return 0;
        if (idx == 1) return 0; // デフォルトルート
        
        // 簡易実装: インデックスからビット数を推定
        var bits: u8 = 1;
        var test_idx: u8 = 2;
        while (test_idx <= idx and bits < 8) {
            test_idx <<= 1;
            bits += 1;
        }
        return bits;
    }
    
    /// idxToOctet: インデックスからオクテットを取得
    fn idxToOctet(idx: u8) u8 {
        if (idx <= 1) return 0;
        
        // 簡易実装: インデックスからオクテットを推定
        const bits = idxToBits(idx);
        if (bits == 0) return 0;
        
        const shift = @as(u3, @intCast(8 - bits));
        const base = @as(u8, 1) << @as(u3, @intCast(bits));
        
        // オーバーフローを防ぐ
        if (idx < base) return 0;
        
        const offset = idx - base;
        return offset << shift;
    }
};

/// base_indexモジュールの関数を拡張
const base_index_extended = struct {
    pub const idxToBits = base_index_ext.idxToBits;
    pub const idxToOctet = base_index_ext.idxToOctet;
};

// =============================================================================
// All系イテレーション機能のヘルパー関数
// =============================================================================

/// ストライドパス型定義 (Goのstridepathに相当)
pub const StridePath = [16]u8;

/// cmpIndexRank: インデックスをCIDRソート順で比較する関数
/// Go実装のcmpIndexRankに相当
pub fn cmpIndexRank(a: u8, b: u8) i32 {
    // インデックスをプレフィックスに変換
    const a_pfx = base_index.idxToPfx256(a) catch |err| switch (err) {
        error.InvalidIndex => return 1, // 無効なインデックスは後ろに
    };
    const b_pfx = base_index.idxToPfx256(b) catch |err| switch (err) {
        error.InvalidIndex => return -1, // 無効なインデックスは後ろに
    };

    // プレフィックスを比較：まずアドレス、次にビット数
    if (a_pfx.octet == b_pfx.octet) {
        if (a_pfx.pfx_len <= b_pfx.pfx_len) {
            return -1;
        }
        return 1;
    }

    if (a_pfx.octet < b_pfx.octet) {
        return -1;
    }

    return 1;
}

/// cidrFromPath: ストライドパス、深度、インデックスからプレフィックスを復元
/// Go実装のcidrFromPathに相当
pub fn cidrFromPath(path: StridePath, depth: usize, is4: bool, idx: u8) Prefix {
    const pfx_info = base_index.idxToPfx256(idx) catch {
        // エラーの場合は無効なプレフィックスを返す
        return Prefix.init(&IPAddr{ .v4 = .{0, 0, 0, 0} }, 0);
    };

    var addr_path = path;
    
    // 現在の深度のオクテットにプレフィックス情報を適用
    if (depth < addr_path.len) {
        // 既存のパス情報を保持し、プレフィックス部分のみマスク
        const current_octet = addr_path[depth];
        const pfx_mask = if (pfx_info.pfx_len == 0) 
            @as(u8, 0)  // デフォルトルート
        else 
            @as(u8, 0xff) << @as(u3, @intCast(8 - pfx_info.pfx_len));
        
        // プレフィックス部分とマスクを組み合わせ
        addr_path[depth] = (current_octet & pfx_mask) | (pfx_info.octet & (~pfx_mask));
    }

    // プレフィックス範囲外のバイトをクリア
    const total_bits = depth * 8 + pfx_info.pfx_len;
    const full_bytes = total_bits / 8;
    const remaining_bits = total_bits % 8;
    
    // 完全なバイト後をクリア
    if (full_bytes + 1 < addr_path.len) {
        for (addr_path[full_bytes + 1..]) |*byte| {
            byte.* = 0;
        }
    }
    
    // 部分バイトのマスク
    if (remaining_bits > 0 and full_bytes < addr_path.len) {
        const mask = @as(u8, 0xff) << @as(u3, @intCast(8 - remaining_bits));
        addr_path[full_bytes] &= mask;
    }

    // IPアドレスを作成
    const ip_addr = if (is4) 
        IPAddr{ .v4 = .{ addr_path[0], addr_path[1], addr_path[2], addr_path[3] } }
    else 
        IPAddr{ .v6 = addr_path };

    // トータルビット数
    const bits = @as(u8, @intCast(total_bits));

    // 正規化されたプレフィックスを返す
    return Prefix.init(&ip_addr, bits);
}

// NodePool implementation moved to src/node_pool.zig

