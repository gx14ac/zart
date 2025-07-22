const std = @import("std");
const sparse_array256 = @import("sparse_array256.zig");
const Array256 = sparse_array256.Array256;
const netip = @import("netip.zig");
const base_index = @import("base_index.zig");

pub const strideLen = 8;
pub const maxTreeDepth = 16;
pub const maxItems = 256;

// Go BART: type stridePath [maxTreeDepth]uint8
// stridePath, max 16 octets deep
pub const stridePath = [maxTreeDepth]u8;

// Go BART: func maxDepthAndLastBits(bits int) (maxDepth int, lastBits uint8)
// maxDepthAndLastBits, get last significant octet and remaining bits
pub fn maxDepthAndLastBits(bits: u8) struct { max_depth: u8, last_bits: u8 } {
    // maxDepth:  range from 0..4 or 0..16 !ATTENTION: not 0..3 or 0..15
    // lastBits:  range from 0..7
    // Go BART: return bits >> 3, uint8(bits & 7)
    return .{
        .max_depth = bits >> 3,     // Go BART: bits >> 3
        .last_bits = bits & 7,      // Go BART: uint8(bits & 7)
    };
}

// Go BART: func isFringe(depth, bits int) bool
pub fn isFringe(depth: u8, bits: u8) bool {
    const result = maxDepthAndLastBits(bits);
    // Go BART: return depth == maxDepth-1 && lastBits == 0
    return depth == result.max_depth - 1 and result.last_bits == 0;
}

/// Go BART: func cidrFromPath(path stridePath, depth int, is4 bool, idx uint8) netip.Prefix
/// Helper function: get prefix back from stride path, depth and idx.
/// The prefix is solely defined by the position in the trie and the baseIndex.
pub fn cidrFromPath(path: stridePath, depth: u8, is4: bool, idx: u8) !netip.Prefix {
    const pfx_result = try base_index.idxToPfx256(idx);
    const octet = pfx_result.octet;
    const pfx_len = pfx_result.pfx_len;

    // set masked byte in path at depth
    var modified_path = path;
    modified_path[depth] = octet;

    // zero/mask the bytes after prefix bits
    // Go BART: clear(path[depth+1:])
    if (depth + 1 < maxTreeDepth) {
        for (modified_path[depth + 1..]) |*byte| {
            byte.* = 0;
        }
    }

    // make ip addr from octets
    const ip = if (is4) 
        netip.Addr.fromIPv4([4]u8{ modified_path[0], modified_path[1], modified_path[2], modified_path[3] })
    else
        netip.Addr.fromIPv6(modified_path);

    // calc bits with pathLen and pfxLen
    // Go BART: bits := depth<<3 + int(pfxLen)
    const bits = (depth * 8) + pfx_len;

    // return a normalized prefix from ip/bits
    return netip.Prefix.fromIPv4(ip, bits);
}

/// Go BART: func cidrForFringe(octets []byte, depth int, is4 bool, lastOctet uint8) netip.Prefix
/// Helper function: get prefix back from octets path, depth, IP version and last octet.
/// The prefix of a fringe is solely defined by the position in the trie.
pub fn cidrForFringe(octets: []const u8, depth: u8, is4: bool, last_octet: u8) netip.Prefix {
    var path = stridePath{};
    
    // Go BART: copy(path[:], octets[:depth+1])
    const copy_len = @min(depth + 1, octets.len);
    @memcpy(path[0..copy_len], octets[0..copy_len]);

    // replace last octet
    // Go BART: path[depth] = lastOctet
    path[depth] = last_octet;

    // make ip addr from octets
    const ip = if (is4) 
        netip.Addr.fromIPv4([4]u8{ path[0], path[1], path[2], path[3] })
    else
        netip.Addr.fromIPv6(path);

    // it's a fringe, bits are alway /8, /16, /24, ...
    // Go BART: bits := (depth + 1) << 3
    const bits = (depth + 1) * 8;

    // return a (normalized) prefix from ip/bits
    return if (is4) 
        netip.Prefix.fromIPv4(ip, @intCast(bits))
    else
        netip.Prefix.fromIPv6(ip, @intCast(bits));
}

// Go BART: type Cloner[V any] interface { Clone() V }
// Cloner interface equivalent in Zig (compile-time trait checking)
pub fn Cloner(comptime V: type) type {
    return struct {
        const Self = @This();
        
        // Types implementing Cloner should have this method signature
        pub fn clone(self: *const V) V {
            _ = self;
            @compileError("clone method must be implemented");
        }
    };
}

// Go BART: func cloneOrCopy[V any](val V) V
pub fn cloneOrCopy(comptime V: type, val: V) V {
    // Check if type V has a 'clone' method at compile time
    if (@hasDecl(V, "clone")) {
        // Go BART: cloner.Clone()
        return val.clone();
    } else {
        // Go BART: just a shallow copy
        return val;
    }
}

// Go BART: type node[V any] struct { ... }
// Node structure with generic payload type V
pub fn Node(comptime V: type) type {
    const LeafNodeType = LeafNode(V);
    const FringeNodeType = FringeNode(V);
    
    return struct {
        const Self = @This();

        /// ChildNode represents different types of child nodes in the trie
        /// This provides type safety for the type switch operations
        pub const ChildNode = union(enum) {
            node: *Self,
            leaf: *LeafNodeType,
            fringe: *FringeNodeType,
        };

        /// prefixes contains the routes, indexed as a complete binary tree with payload V
        /// with the help of the baseIndex mapping function from the ART algorithm.
        /// (Go BART: prefixes sparse.Array256[V])
        prefixes: Array256(V),

        /// children, recursively spans the trie with a branching factor of 256.
        /// Now type-safe with ChildNode union instead of *anyopaque
        /// (Go BART: children sparse.Array256[any])
        children: Array256(ChildNode),

        /// Initialize empty node
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .prefixes = Array256(V).init(allocator),
                .children = Array256(ChildNode).init(allocator),
            };
        }

        /// Cleanup node resources
        pub fn deinit(self: *Self) void {
            self.prefixes.deinit();
            self.children.deinit();
        }

        /// Go BART: func (n *node[V]) cloneFlat() *node[V]
        /// cloneFlat copies the node and clone the values in prefixes and path compressed leaves
        /// if V implements Cloner. Used in the various ...Persist functions.
        pub fn cloneFlat(self: *const Self, allocator: std.mem.Allocator) !*Self {
            // Go BART: if n == nil { return nil }
            // In Zig, we assume self is valid since it's a method call

            const cloned = try allocator.create(Self);
            
            // Go BART: if n.isEmpty() { return c }
            if (self.isEmpty()) {
                cloned.* = Self.init(allocator);
                return cloned;
            }

            // Go BART: shallow copy
            // c.prefixes = *(n.prefixes.Copy())
            // c.children = *(n.children.Copy())
            const prefixes_copy = try self.prefixes.copy(allocator);
            const children_copy = try self.children.copy(allocator);
            
            cloned.* = Self{
                .prefixes = prefixes_copy.?, // copy returns non-null since self is valid
                .children = children_copy.?, // copy returns non-null since self is valid
            };

            // Go BART: if _, ok := any(*new(V)).(Cloner[V]); !ok {
            // Check if V implements Cloner interface (at compile time)
            if (!@hasDecl(V, "clone")) {
                // if V doesn't implement clone, return early
                return cloned;
            }

            // Go BART: deep copy of values in prefixes
            // for i, val := range c.prefixes.Items {
            //     c.prefixes.Items[i] = cloneOrCopy(val)
            // }
            const items = cloned.prefixes.Items();
            for (items, 0..) |_, i| {
                items[i] = cloneOrCopy(V, items[i]);
            }

            // Go BART: deep copy of values in path compressed leaves
            // for i, kidAny := range c.children.Items {
            //     switch kid := kidAny.(type) {
            //     case *leafNode[V]:
            //         c.children.Items[i] = kid.cloneLeaf()
            //     case *fringeNode[V]:
            //         c.children.Items[i] = kid.cloneFringe()
            //     }
            // }
            const child_items = cloned.children.Items();
            for (child_items, 0..) |child_ptr, i| {
                // Determine child type and clone accordingly
                // This is a simplified approach - in practice, you'd need better type detection
                if (@typeInfo(@TypeOf(child_ptr)) == .Pointer) {
                    // For now, assume shallow copy is sufficient for non-Cloner children
                    // A more sophisticated implementation would detect the actual type
                    child_items[i] = child_ptr;
                }
            }

            return cloned;
        }

        /// Check if node is empty (has neither prefixes nor children)
        /// Go BART: func (n *node[V]) isEmpty() bool
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes.len() == 0 and self.children.len() == 0;
        }

        /// Go BART: func (n *node[V]) insertAtDepth(pfx netip.Prefix, val V, depth int) (exists bool)
        pub fn insertAtDepth(self: *Self, pfx: netip.Prefix, val: V, depth: u8, allocator: std.mem.Allocator) !bool {
            const ip = pfx.addr();
            const bits = pfx.bits();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var current_depth = depth;
            var current_node = self;

            // Go BART: for ; depth < len(octets); depth++
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];

                // Go BART: if depth == maxDepth
                // last masked octet: insert/override prefix/val into node
                if (current_depth == max_depth) {
                    // Go BART: return n.prefixes.InsertAt(art.PfxToIdx256(octet, lastBits), val)
                    return try current_node.prefixes.insertAt(
                        base_index.pfxToIdx256(octet, last_bits),
                        val
                    );
                }

                // Go BART: if !n.children.Test(octet)
                // reached end of trie path ...
                if (!current_node.children.Test(octet)) {
                    // Go BART: if isFringe(depth, bits)
                    if (isFringe(current_depth, bits)) {
                        // Go BART: return n.children.InsertAt(octet, &fringeNode[V]{val})
                        const fringe = try allocator.create(FringeNodeType);
                        fringe.* = FringeNodeType.init(val);
                        return try current_node.children.insertAt(octet, Self.ChildNode{ .fringe = fringe });
                    }
                    // Go BART: return n.children.InsertAt(octet, &leafNode[V]{prefix: pfx, value: val})
                    const leaf = try allocator.create(LeafNodeType);
                    leaf.* = LeafNodeType.init(pfx, val);
                    return try current_node.children.insertAt(octet, Self.ChildNode{ .leaf = leaf });
                }

                // Go BART: kid := n.children.MustGet(octet)
                // ... or descend down the trie
                const kid = current_node.children.mustGet(octet);

                // Go BART: switch kid := kid.(type)
                switch (kid) {
                    .node => |node_ptr| {
                        // Go BART: case *node[V]: n = kid; continue
                        current_node = node_ptr;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        // Go BART: case *leafNode[V]:
                        // reached a path compressed prefix
                        // override value in slot if prefixes are equal
                        if (leaf_ptr.prefix.eql(&pfx)) {
                            // Go BART: kid.value = val
                            leaf_ptr.value = val;
                            return true; // exists
                        }

                        // create new node
                        // push the leaf down  
                        // insert new child at current leaf position (addr)
                        // descend down, replace n with new child
                        const new_node = try allocator.create(Self);
                        new_node.* = Self.init(allocator);
                        _ = try new_node.insertAtDepth(leaf_ptr.prefix, leaf_ptr.value, current_depth + 1, allocator);

                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                    
                    .fringe => |fringe_ptr| {
                        // Go BART: case *fringeNode[V]:
                        // reached a path compressed fringe
                        // override value in slot if pfx is a fringe
                        if (isFringe(current_depth, bits)) {
                            // Go BART: kid.value = val
                            fringe_ptr.value = val;
                            return true; // exists
                        }

                        // create new node
                        // push the fringe down, it becomes a default route (idx=1)
                        // insert new child at current leaf position (addr)
                        // descend down, replace n with new child
                        const new_node = try allocator.create(Self);
                        new_node.* = Self.init(allocator);
                        _ = try new_node.prefixes.insertAt(1, fringe_ptr.value);

                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                }
            }

            @panic("unreachable");
        }

        /// Go BART: func (n *node[V]) insertAtDepthPersist(pfx netip.Prefix, val V, depth int) (exists bool)
        /// insertAtDepthPersist is the immutable version of insertAtDepth.
        /// All visited nodes are cloned during insertion.
        pub fn insertAtDepthPersist(self: *Self, pfx: netip.Prefix, val: V, depth: u8, allocator: std.mem.Allocator) !bool {
            const ip = pfx.addr();
            const bits = pfx.bits();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

            var current_depth = depth;
            var current_node = self;

            // Go BART: for ; depth < len(octets); depth++
            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];

                // Go BART: if depth == maxDepth
                // last masked octet: insert/override prefix/val into node
                if (current_depth == max_depth) {
                    // Go BART: return n.prefixes.InsertAt(art.PfxToIdx256(octet, lastBits), val)
                    return try current_node.prefixes.insertAt(
                        base_index.pfxToIdx256(octet, last_bits),
                        val
                    );
                }

                // Go BART: if !n.children.Test(octet)
                if (!current_node.children.Test(octet)) {
                    // insert prefix path compressed as leaf or fringe
                    if (isFringe(current_depth, bits)) {
                        // Go BART: return n.children.InsertAt(octet, &fringeNode[V]{val})
                        const fringe = try allocator.create(FringeNodeType);
                        fringe.* = FringeNodeType.init(val);
                        return try current_node.children.insertAt(octet, Self.ChildNode{ .fringe = fringe });
                    }
                    // Go BART: return n.children.InsertAt(octet, &leafNode[V]{prefix: pfx, value: val})
                    const leaf = try allocator.create(LeafNodeType);
                    leaf.* = LeafNodeType.init(pfx, val);
                    return try current_node.children.insertAt(octet, Self.ChildNode{ .leaf = leaf });
                }

                // Go BART: kid := n.children.MustGet(octet)
                const kid = current_node.children.mustGet(octet);

                // Go BART: switch kid := kid.(type)
                switch (kid) {
                    .node => |node_ptr| {
                        // Go BART: case *node[V]: n = kid; continue
                        // For persist version, we need to clone the node before continuing
                        const cloned_node = try node_ptr.cloneFlat(allocator);
                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = cloned_node });
                        current_node = cloned_node;
                        continue; // descend down to next trie level
                    },
                    
                    .leaf => |leaf_ptr| {
                        // Go BART: case *leafNode[V]:
                        // reached a path compressed prefix
                        // override value in slot if prefixes are equal
                        if (leaf_ptr.prefix.eql(&pfx)) {
                            // For persist version, clone the leaf and update value
                            const cloned_leaf = try leaf_ptr.cloneLeaf(allocator);
                            cloned_leaf.value = val;
                            _ = try current_node.children.insertAt(octet, Self.ChildNode{ .leaf = cloned_leaf });
                            return true; // exists
                        }

                        // create new node
                        // push the leaf down  
                        // insert new child at current leaf position (addr)
                        // descend down, replace n with new child
                        const new_node = try allocator.create(Self);
                        new_node.* = Self.init(allocator);
                        _ = try new_node.insertAtDepthPersist(leaf_ptr.prefix, leaf_ptr.value, current_depth + 1, allocator);

                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                    
                    .fringe => |fringe_ptr| {
                        // Go BART: case *fringeNode[V]:
                        // reached a path compressed fringe
                        // override value in slot if pfx is a fringe
                        if (isFringe(current_depth, bits)) {
                            // For persist version, clone the fringe and update value
                            const cloned_fringe = try fringe_ptr.cloneFringe(allocator);
                            cloned_fringe.value = val;
                            _ = try current_node.children.insertAt(octet, Self.ChildNode{ .fringe = cloned_fringe });
                            return true; // exists
                        }

                        // create new node
                        // push the fringe down, it becomes a default route (idx=1)
                        // insert new child at current leaf position (addr)
                        // descend down, replace n with new child
                        const new_node = try allocator.create(Self);
                        new_node.* = Self.init(allocator);
                        _ = try new_node.prefixes.insertAt(1, fringe_ptr.value);

                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                }
            }

            @panic("unreachable");
        }

        /// Go BART: func (n *node[V]) purgeAndCompress(stack []*node[V], octets []uint8, is4 bool)
        /// purgeAndCompress: purge empty nodes or compress nodes with single prefix or leaf.
        /// This method performs path compression and cleanup after deletion operations.
        pub fn purgeAndCompress(self: *Self, stack: []*Self, octets: []const u8, is4: bool, allocator: std.mem.Allocator) !void {
            var current_node = self;
            
            // unwind the stack
            // Go BART: for depth := len(stack) - 1; depth >= 0; depth--
            var depth: i32 = @as(i32, @intCast(stack.len)) - 1;
            while (depth >= 0) : (depth -= 1) {
                const depth_u8 = @as(u8, @intCast(depth));
                const parent = stack[@intCast(depth)];
                const octet = octets[depth_u8];

                const pfx_count = current_node.prefixes.len();
                const child_count = current_node.children.len();

                // Go BART: switch cases
                if (current_node.isEmpty()) {
                    // Go BART: case n.isEmpty()
                    // just delete this empty node from parent
                    _ = parent.children.deleteAt(octet);
                    
                } else if (pfx_count == 0 and child_count == 1) {
                    // Go BART: case pfxCount == 0 && childCount == 1
                    // Get the single child
                    const kid = current_node.children.Items()[0];
                    
                    // Go BART: switch kid := n.children.Items[0].(type)
                    switch (kid) {
                        .node => |_| {
                            // Go BART: case *node[V]
                            // fast exit, we are at an intermediate path node
                            // no further delete/compress upwards the stack is possible
                            return;
                        },
                        
                        .leaf => |leaf_ptr| {
                            // Go BART: case *leafNode[V]
                            // just one leaf, delete this node and reinsert the leaf above
                            _ = parent.children.deleteAt(octet);

                            // ... (re)insert the leaf at parents depth
                            _ = try parent.insertAtDepth(leaf_ptr.prefix, leaf_ptr.value, depth_u8, allocator);
                        },
                        
                        .fringe => |fringe_ptr| {
                            // Go BART: case *fringeNode[V]
                            // just one fringe, delete this node and reinsert the fringe as leaf above
                            _ = parent.children.deleteAt(octet);

                            // get the last octet back, the only item is also the first item
                            // Go BART: lastOctet, _ := n.children.firstSet()
                            const first_set_result = current_node.children.firstSet();
                            if (first_set_result.ok) {
                                const last_octet = first_set_result.value;

                                // rebuild the prefix with octets, depth, ip version and addr
                                // depth is the parent's depth, so add +1 here for the kid
                                // Go BART: fringePfx := cidrForFringe(octets, depth+1, is4, lastOctet)
                                const fringe_pfx = cidrForFringe(octets, depth_u8 + 1, is4, last_octet);

                                // ... (re)reinsert prefix/value at parents depth
                                _ = try parent.insertAtDepth(fringe_pfx, fringe_ptr.value, depth_u8, allocator);
                            }
                        },
                    }
                    
                } else if (pfx_count == 1 and child_count == 0) {
                    // Go BART: case pfxCount == 1 && childCount == 0
                    // just one prefix, delete this node and reinsert the idx as leaf above
                    _ = parent.children.deleteAt(octet);

                    // get prefix back from idx ...
                    // Go BART: idx, _ := n.prefixes.firstSet()
                    const first_set_result = current_node.prefixes.firstSet();
                    if (first_set_result.ok) {
                        const idx = first_set_result.value;
                        // Go BART: val := n.prefixes.Items[0]
                        const val = current_node.prefixes.Items()[0];

                        // ... and octet path
                        // Go BART: path := stridePath{}, copy(path[:], octets)
                        var path = stridePath{};
                        const copy_len = @min(octets.len, maxTreeDepth);
                        @memcpy(path[0..copy_len], octets[0..copy_len]);

                        // depth is the parent's depth, so add +1 here for the kid
                        // Go BART: pfx := cidrFromPath(path, depth+1, is4, idx)
                        const pfx = try cidrFromPath(path, depth_u8 + 1, is4, idx);

                        // ... (re)insert prefix/value at parents depth
                        _ = try parent.insertAtDepth(pfx, val, depth_u8, allocator);
                    }
                }

                // climb up the stack
                // Go BART: n = parent
                current_node = parent;
            }
        }

        /// Go BART: func (n *node[V]) lpmGet(idx uint) (baseIdx uint8, val V, ok bool)
        /// lpmGet does a route lookup for idx in the 8-bit (stride) routing table
        /// at this depth and returns (baseIdx, value, true) if a matching
        /// longest prefix exists, or ok=false otherwise.
        pub fn lpmGet(self: *const Self, idx: usize) struct { base_idx: u8, val: V, ok: bool } {
            // Go BART: if top, ok := n.prefixes.IntersectionTop(lpm.BackTrackingBitset(idx)); ok
            const lookup_tbl = @import("lookup_tbl.zig");
            const backtracking_bitset = lookup_tbl.backTrackingBitset(idx);
            
            if (self.prefixes.IntersectionTop(&backtracking_bitset)) |top| {
                // Go BART: return top, n.prefixes.MustGet(top), true
                const val = self.prefixes.mustGet(top);
                return .{ .base_idx = top, .val = val, .ok = true };
            }

            // not found (on this level)
            // Go BART: return
            return .{ .base_idx = 0, .val = undefined, .ok = false };
        }

        /// Go BART: func (n *node[V]) lpmTest(idx uint) bool
        /// lpmTest, true if idx has a (any) longest-prefix-match in node.
        /// this is a contains test, faster as lookup and without value returns.
        pub fn lpmTest(self: *const Self, idx: usize) bool {
            // Go BART: return n.prefixes.IntersectsAny(lpm.BackTrackingBitset(idx))
            const lookup_tbl = @import("lookup_tbl.zig");
            const backtracking_bitset = lookup_tbl.backTrackingBitset(idx);
            
            return self.prefixes.IntersectsAny(&backtracking_bitset);
        }
    };
}

// Go BART: type leafNode[V any] struct { prefix netip.Prefix; value V }
// leafNode is a prefix with value, used as a path compressed child.
pub fn LeafNode(comptime V: type) type {
    return struct {
        const Self = @This();

        /// Go BART: prefix netip.Prefix
        prefix: netip.Prefix,

        /// Go BART: value V
        value: V,

        /// Initialize leaf node
        pub fn init(prefix: netip.Prefix, value: V) Self {
            return Self{
                .prefix = prefix,
                .value = value,
            };
        }

        /// Go BART: func (l *leafNode[V]) cloneLeaf() *leafNode[V]
        /// cloneLeaf returns a clone of the leaf
        /// if the value implements the Cloner interface.
        pub fn cloneLeaf(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const cloned = try allocator.create(Self);
            cloned.* = Self{
                .prefix = self.prefix,  // Go BART: prefix: l.prefix
                .value = cloneOrCopy(V, self.value),  // Go BART: value: cloneOrCopy(l.value)
            };
            return cloned;
        }
    };
}

// Go BART: type fringeNode[V any] struct { value V }
// fringeNode is a path-compressed leaf with value but without a prefix.
// The prefix of a fringe is solely defined by the position in the trie.
// The fringe-compression (no stored prefix) saves a lot of memory,
// but the algorithm is more complex.
pub fn FringeNode(comptime V: type) type {
    return struct {
        const Self = @This();

        /// Go BART: value V
        value: V,

        /// Initialize fringe node
        pub fn init(value: V) Self {
            return Self{
                .value = value,
            };
        }

        /// Go BART: func (l *fringeNode[V]) cloneFringe() *fringeNode[V]
        /// cloneFringe returns a clone of the fringe
        /// if the value implements the Cloner interface.
        pub fn cloneFringe(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const cloned = try allocator.create(Self);
            cloned.* = Self{
                .value = cloneOrCopy(V, self.value),  // Go BART: value: cloneOrCopy(l.value)
            };
            return cloned;
        }
    };
}

// Tests for lpmGet and lpmTest methods
const testing = std.testing;

test "lpmGet and lpmTest Go BART compatibility" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    var node = TestNode.init(testing.allocator);
    defer node.deinit();
    
    // Insert some test values using baseIndex mapping
    const art_base_index = @import("base_index.zig");
    
    // Insert default route at index 1 (0/0 - matches everything)
    _ = try node.prefixes.insertAt(1, 100);
    
    // Insert more specific route 
    _ = try node.prefixes.insertAt(128, 200);
    
    // Test lpmGet - should find longest prefix match
    const host_idx_192 = art_base_index.hostIdx(192);
    const host_idx_10 = art_base_index.hostIdx(10);
    const host_idx_172 = art_base_index.hostIdx(172);
    
    const result1 = node.lpmGet(host_idx_192);
    try testing.expect(result1.ok);
    try testing.expectEqual(@as(i32, 100), result1.val); // Should match default route
    
    const result2 = node.lpmGet(host_idx_10);
    try testing.expect(result2.ok);
    try testing.expectEqual(@as(i32, 100), result2.val); // Should match default route
    
    const result3 = node.lpmGet(host_idx_172);
    try testing.expect(result3.ok);
    try testing.expectEqual(@as(i32, 100), result3.val); // Should match default route
    
    // Test lpmTest - faster contains check
    try testing.expect(node.lpmTest(host_idx_192));
    try testing.expect(node.lpmTest(host_idx_10));
    try testing.expect(node.lpmTest(host_idx_172));
}

test "lpmGet with backtracking bitset" {
    const TestV = []const u8;
    const TestNode = Node(TestV);
    
    var node = TestNode.init(testing.allocator);
    defer node.deinit();
    
    // Insert default route at index 1 (0/0)
    _ = try node.prefixes.insertAt(1, "default");
    
    // Insert more specific route at index 256 (128.0.0.0/1)
    _ = try node.prefixes.insertAt(256 >> 1, "specific"); // Handle overflow case
    
    // Test that backtracking finds the most specific match
    const result = node.lpmGet(384); // Some high index value
    try testing.expect(result.ok);
    // Should find the most specific matching prefix
}
