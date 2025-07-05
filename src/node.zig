const std = @import("std");
const base_index = @import("base_index.zig");
const sparse_array256 = @import("sparse_array256.zig");
const Array256 = sparse_array256.Array256;
const bitset256 = @import("bitset256.zig");
const BitSet256 = bitset256.BitSet256;
const lookup_tbl = @import("lookup_tbl.zig");

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
        
        /// prefixes contains the routes, indexed as a complete binary tree with payload V
        /// with the help of the baseIndex mapping function from the ART algorithm.
        prefixes: Array256(V),
        
        /// children, recursively spans the trie with a branching factor of 256.
        children: Array256(Child(V)),
        
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) *Self {
            const node = allocator.create(Node(V)) catch unreachable;
            node.* = Self{
                .prefixes = Array256(V).init(allocator),
                .children = Array256(Child(V)).init(allocator),
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
        
        /// insertAtDepth insert a prefix/val into a node tree at depth.
        /// n must not be nil, prefix must be valid and already in canonical form.
        pub fn insertAtDepth(self: *Self, pfx: *const Prefix, val: V, depth: usize, allocator: std.mem.Allocator) bool {
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
                    const new_node = Node(V).init(allocator);
                    const child = Child(V){ .node = new_node };
                    _ = (&current_node.children).insertAt(octet, child);
                }
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node| {
                        current_node = node;
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
            const inserted = current_node.prefixes.insertAt(idx, val);
            return inserted;
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
                    const new_node = Node(V).init(allocator);
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
        
        /// lpmTest tests if there is a longest prefix match for idx
        pub fn lpmTest(self: *const Self, idx: usize) bool {
            var bs: bitset256.BitSet256 = @as(bitset256.BitSet256, lookup_tbl.backTrackingBitset(idx));
            return self.prefixes.intersectsAny(&bs);
        }

        /// lpmGet returns the longest prefix match for idx
        pub fn lpmGet(self: *const Self, idx: usize) struct { base_idx: u8, val: V, ok: bool } {
            var bs: bitset256.BitSet256 = @as(bitset256.BitSet256, lookup_tbl.backTrackingBitset(idx));
            if (self.prefixes.intersectionTop(&bs)) |top| {
                return .{ .base_idx = top, .val = self.prefixes.mustGet(top), .ok = true };
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
                    else => return null,
                }
            }
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
                    else => return null,
                }
            }
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
                                // Create new node
                                const new_node = Node(V).init(self.allocator);
                                
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
                                
                                // Create new node
                                const new_node = Node(V).init(self.allocator);
                                
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
                                // Create new node
                                const new_node = Node(V).init(self.allocator);
                                
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
                                // Create new node
                                const new_node = Node(V).init(self.allocator);
                                
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
                                // Create new node
                                const new_node = Node(V).init(self.allocator);
                                
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
pub fn isFringe(depth: usize, bits: u8) bool {
    const max_depth = base_index.maxDepthAndLastBits(bits).max_depth;
    const last_bits = base_index.maxDepthAndLastBits(bits).last_bits;
    return depth == max_depth - 1 and last_bits == 0;
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

    /// Format function for std.debug.print
    pub fn format(self: Prefix, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Prefix{{addr={s}, bits={}}}", .{self.addr, self.bits});
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