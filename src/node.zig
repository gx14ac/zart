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
        netip.Addr.fromIPv4(modified_path[0], modified_path[1], modified_path[2], modified_path[3])
    else
        netip.Addr.fromIPv6(modified_path);

    // calc bits with pathLen and pfxLen
    // Go BART: bits := depth<<3 + int(pfxLen)
    const bits = (depth * 8) + pfx_len;

    // return a normalized prefix from ip/bits
    return if (is4)
        netip.Prefix.fromIPv4(ip.octets[12], ip.octets[13], ip.octets[14], ip.octets[15], @intCast(bits))
    else
        netip.Prefix.fromIPv6(ip.octets, @intCast(bits));
}

/// Go BART: func cidrForFringe(octets []byte, depth int, is4 bool, lastOctet uint8) netip.Prefix
/// Helper function: get prefix back from octets path, depth, IP version and last octet.
/// The prefix of a fringe is solely defined by the position in the trie.
pub fn cidrForFringe(octets: []const u8, depth: u8, is4: bool, last_octet: u8) netip.Prefix {
    var path: stridePath = [_]u8{0} ** maxTreeDepth;
    
    // Go BART: copy(path[:], octets[:depth+1])
    const copy_len = @min(depth + 1, octets.len);
    @memcpy(path[0..copy_len], octets[0..copy_len]);

    // replace last octet
    // Go BART: path[depth] = lastOctet
    path[depth] = last_octet;

    // make ip addr from octets
    const ip = if (is4) 
        netip.Addr.fromIPv4(path[0], path[1], path[2], path[3])
    else
        netip.Addr.fromIPv6(path);

    // it's a fringe, bits are alway /8, /16, /24, ...
    // Go BART: bits := (depth + 1) << 3
    const bits = (depth + 1) * 8;

    // return a (normalized) prefix from ip/bits
    return if (is4) 
        netip.Prefix.fromIPv4(ip.octets[12], ip.octets[13], ip.octets[14], ip.octets[15], @intCast(bits))
    else
        netip.Prefix.fromIPv6(ip.octets, @intCast(bits));
}

// Go BART: type Cloner[V any] interface { Clone() V }
// Zig equivalent: Compile-time interface checking
/// Cloner trait checker - determines if type V implements clone() method
pub fn hasCloneMethod(comptime V: type) bool {
    const type_info = @typeInfo(V);
    return type_info == .@"struct" and @hasDecl(V, "clone");
}

/// Check if type V has correct clone signature: fn clone(self: V) V
pub fn hasCorrectCloneSignature(comptime V: type) bool {
    if (!hasCloneMethod(V)) return false;
    
    // For now, just check if clone method exists
    // More sophisticated signature checking can be added later
    return true;
}

/// Go BART: Cloner[V] interface equivalent
/// Use this to check if type V implements Cloner pattern
pub fn isCloner(comptime V: type) bool {
    return hasCorrectCloneSignature(V);
}

// Go BART: func cloneOrCopy[V any](val V) V
/// Enhanced cloneOrCopy with strict Cloner interface checking
pub fn cloneOrCopy(comptime V: type, val: V) V {
    // Use comptime check to avoid runtime errors
    if (comptime isCloner(V)) {
        // Go BART: cloner.Clone() - Type V implements Cloner interface
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

        node_id: u32,
        prefixes: Array256(V),
        children: Array256(ChildNode),
        allocator: std.mem.Allocator,
        rc: u32 = 1,

        pub const ChildNode = union(enum) {
            node: *Self,
            leaf: *LeafNodeType,
            fringe: *FringeNodeType,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            const GlobalState = struct {
                var next_id: u32 = 1;
            };

            const id = GlobalState.next_id;
            GlobalState.next_id += 1;

            return Self{
                .node_id = id,
                .prefixes = Array256(V).init(allocator),
                .children = Array256(ChildNode).init(allocator),
                .allocator = allocator,
                .rc = 1,
            };
        }

        pub fn incRef(self: *Self) void {
            self.rc += 1;
        }

        /// Decrement refcount of a child node. Frees if rc reaches 0.
        pub fn decRefChild(child: ChildNode, allocator: std.mem.Allocator) void {
            switch (child) {
                .node => |node_ptr| {
                    node_ptr.rc -= 1;
                    if (node_ptr.rc == 0) {
                        node_ptr.deinit();
                        allocator.destroy(node_ptr);
                    }
                },
                .leaf => |leaf_ptr| {
                    leaf_ptr.rc -= 1;
                    if (leaf_ptr.rc == 0) {
                        allocator.destroy(leaf_ptr);
                    }
                },
                .fringe => |fringe_ptr| {
                    fringe_ptr.rc -= 1;
                    if (fringe_ptr.rc == 0) {
                        allocator.destroy(fringe_ptr);
                    }
                },
            }
        }

        /// Increment refcount of a child node (used by cloneFlat for shared children).
        fn incRefChild(child: ChildNode) void {
            switch (child) {
                .node => |node_ptr| node_ptr.rc += 1,
                .leaf => |leaf_ptr| leaf_ptr.rc += 1,
                .fringe => |fringe_ptr| fringe_ptr.rc += 1,
            }
        }

        /// Release all owned resources. Decrements children refcounts.
        pub fn deinit(self: *Self) void {
            if (self.children.len() > 0) {
                const items = self.children.Items();
                for (items) |child| {
                    decRefChild(child, self.allocator);
                }
            }
            self.prefixes.deinit();
            self.children.deinit();
        }

        /// Go BART: func (n *node[V]) isEmpty() bool
        /// isEmpty returns true if node has neither prefixes nor children
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes.len() == 0 and self.children.len() == 0;
        }

        /// Go BART: func (n *node[V]) cloneFlat() *node[V]
        /// cloneFlat copies the node and clone the values in prefixes and path compressed leaves
        /// if V implements Cloner. Used in the various ...Persist functions.
        /// cloneFlat: shallow clone of a node. Copies sparse arrays but shares
        /// child pointers (incrementing their refcounts). O(children_count).
        pub fn cloneFlat(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const cloned = try allocator.create(Self);

            if (self.isEmpty()) {
                cloned.* = Self.init(allocator);
                return cloned;
            }

            // Copy sparse arrays inline (avoid intermediate heap allocation)
            const Array256V = @import("sparse_array256.zig").Array256(V);
            const Array256C = @import("sparse_array256.zig").Array256(ChildNode);

            var new_prefixes: Array256V = undefined;
            if (self.prefixes.len() > 0) {
                const src_items = self.prefixes.Items();
                const copied_items = try allocator.alloc(V, src_items.len);
                @memcpy(copied_items, src_items);
                new_prefixes = .{
                    .bitset = self.prefixes.bitset,
                    .items = copied_items,
                    .capacity = src_items.len,
                    .allocator = allocator,
                };
            } else {
                new_prefixes = Array256V.init(allocator);
            }

            var new_children: Array256C = undefined;
            if (self.children.len() > 0) {
                const src_items = self.children.Items();
                const copied_items = try allocator.alloc(ChildNode, src_items.len);
                @memcpy(copied_items, src_items);
                new_children = .{
                    .bitset = self.children.bitset,
                    .items = copied_items,
                    .capacity = src_items.len,
                    .allocator = allocator,
                };
            } else {
                new_children = Array256C.init(allocator);
            }

            cloned.* = Self{
                .prefixes = new_prefixes,
                .children = new_children,
                .allocator = allocator,
                .node_id = self.node_id,
                .rc = 1,
            };

            // Increment refcount on all shared children
            if (cloned.children.len() > 0) {
                for (cloned.children.Items()) |child| {
                    incRefChild(child);
                }
            }

            // Clone values if V implements Cloner
            const type_info = @typeInfo(V);
            if (type_info == .int or type_info == .float or type_info == .bool) {
                return cloned;
            }
            if (type_info != .@"struct" or !@hasDecl(V, "clone")) {
                return cloned;
            }

            const items = cloned.prefixes.Items();
            for (items, 0..) |_, i| {
                items[i] = cloneOrCopy(V, items[i]);
            }

            return cloned;
        }

        /// Go BART: func (n *node[V]) cloneRec() *node[V]
        /// cloneRec, clones the node recursive.
        /// Returns a deep clone of this node and all its children.
        pub fn cloneRec(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const c = try allocator.create(Self);
            
            if (self.isEmpty()) {
                c.* = Self.init(allocator);
                return c;
            }

            c.* = Self.init(allocator);

            if (try self.prefixes.copy(allocator)) |prefixes_copy| {
                c.prefixes.deinit();
                c.prefixes = prefixes_copy.*;
                allocator.destroy(prefixes_copy);
                
                const type_info = @typeInfo(V);
                if (type_info == .@"struct" and @hasDecl(V, "clone")) {
                    const items = c.prefixes.Items();
                    for (items) |*item| {
                        item.* = cloneOrCopy(V, item.*);
                    }
                }
            }

            // Manual deep copy of children to ensure proper memory management
            if (self.children.len() > 0) {
                // Get the indices where children are set
                for (0..256) |bit_idx| {
                    if (self.children.Test(@intCast(bit_idx))) {
                        const child_item = self.children.mustGet(@intCast(bit_idx));
                        
                        switch (child_item) {
                            .node => |kid_node| {
                                const cloned_node = try kid_node.cloneRec(allocator);
                                _ = try c.children.insertAt(@intCast(bit_idx), Self.ChildNode{ .node = cloned_node });
                            },
                            .leaf => |kid_leaf| {
                                const cloned_leaf = try kid_leaf.cloneLeaf(allocator);
                                _ = try c.children.insertAt(@intCast(bit_idx), Self.ChildNode{ .leaf = cloned_leaf });
                            },
                            .fringe => |kid_fringe| {
                                const cloned_fringe = try kid_fringe.cloneFringe(allocator);
                                _ = try c.children.insertAt(@intCast(bit_idx), Self.ChildNode{ .fringe = cloned_fringe });
                            },
                        }
                    }
                }
            }

            return c;
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

                const existing_child = current_node.children.mustGet(octet);

                // Go BART: switch kid := kid.(type)
                switch (existing_child) {
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

                        // Clean up the old leaf after using its data
                        allocator.destroy(leaf_ptr);

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

                        // Clean up the old fringe after using its data
                        allocator.destroy(fringe_ptr);

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
                        // For persist version, clone the node before descending
                        const cloned_node = try node_ptr.cloneFlat(allocator);
                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = cloned_node });
                        // The old shared pointer is no longer in our tree; drop our reference
                        decRefChild(Self.ChildNode{ .node = node_ptr }, allocator);
                        current_node = cloned_node;
                        continue;
                    },
                    
                    .leaf => |leaf_ptr| {
                        // reached a path compressed prefix
                        if (leaf_ptr.prefix.eql(&pfx)) {
                            // Clone the leaf and update value
                            const cloned_leaf = try leaf_ptr.cloneLeaf(allocator);
                            cloned_leaf.value = val;
                            _ = try current_node.children.insertAt(octet, Self.ChildNode{ .leaf = cloned_leaf });
                            decRefChild(Self.ChildNode{ .leaf = leaf_ptr }, allocator);
                            return true;
                        }

                        // push the leaf down into a new node
                        const new_node = try allocator.create(Self);
                        new_node.* = Self.init(allocator);
                        _ = try new_node.insertAtDepthPersist(leaf_ptr.prefix, leaf_ptr.value, current_depth + 1, allocator);

                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = new_node });
                        decRefChild(Self.ChildNode{ .leaf = leaf_ptr }, allocator);
                        current_node = new_node;
                    },

                    .fringe => |fringe_ptr| {
                        // reached a path compressed fringe
                        if (isFringe(current_depth, bits)) {
                            // Clone the fringe and update value
                            const cloned_fringe = try fringe_ptr.cloneFringe(allocator);
                            cloned_fringe.value = val;
                            _ = try current_node.children.insertAt(octet, Self.ChildNode{ .fringe = cloned_fringe });
                            decRefChild(Self.ChildNode{ .fringe = fringe_ptr }, allocator);
                            return true;
                        }

                        // push the fringe down into a new node
                        const new_node = try allocator.create(Self);
                        new_node.* = Self.init(allocator);
                        _ = try new_node.prefixes.insertAt(1, fringe_ptr.value);

                        _ = try current_node.children.insertAt(octet, Self.ChildNode{ .node = new_node });
                        decRefChild(Self.ChildNode{ .fringe = fringe_ptr }, allocator);
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
                    const deleted = parent.children.deleteAt(octet);
                    if (deleted.ok) {
                        decRefChild(deleted.value, allocator);
                    }
                    
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
                            const saved_prefix = leaf_ptr.prefix;
                            const saved_value = leaf_ptr.value;

                            const deleted = parent.children.deleteAt(octet);
                            if (deleted.ok) {
                                decRefChild(deleted.value, allocator);
                            }

                            _ = try parent.insertAtDepth(saved_prefix, saved_value, depth_u8, allocator);
                        },

                        .fringe => |fringe_ptr| {
                            const saved_value = fringe_ptr.value;
                            const first_set_result = current_node.children.firstSet();

                            const deleted = parent.children.deleteAt(octet);
                            if (deleted.ok) {
                                decRefChild(deleted.value, allocator);
                            }

                            if (first_set_result.ok) {
                                const last_octet = first_set_result.value;
                                const fringe_pfx = cidrForFringe(octets, depth_u8 + 1, is4, last_octet);
                                _ = try parent.insertAtDepth(fringe_pfx, saved_value, depth_u8, allocator);
                            }
                        },
                    }
                    
                } else if (pfx_count == 1 and child_count == 0) {
                    // Go BART: case pfxCount == 1 && childCount == 0
                    // just one prefix, delete this node and reinsert the idx as leaf above

                    const first_set_result = current_node.prefixes.firstSet();
                    const saved_idx = if (first_set_result.ok) first_set_result.value else 0;
                    const saved_val = if (first_set_result.ok) current_node.prefixes.Items()[0] else undefined;
                    const has_prefix = first_set_result.ok;

                    const deleted = parent.children.deleteAt(octet);
                    if (deleted.ok) {
                        decRefChild(deleted.value, allocator);
                    }

                    if (has_prefix) {
                        // ... and octet path
                        // Go BART: path := stridePath{}; copy(path[:], octets)
                        var path: stridePath = [_]u8{0} ** maxTreeDepth;
                        const copy_len = @min(octets.len, maxTreeDepth);
                        @memcpy(path[0..copy_len], octets[0..copy_len]);

                        // depth is the parent's depth, so add +1 here for the kid
                        // Go BART: pfx := cidrFromPath(path, depth+1, is4, idx)
                        const pfx = try cidrFromPath(path, depth_u8 + 1, is4, @intCast(saved_idx));

                        // ... (re)insert prefix/value at parents depth
                        _ = try parent.insertAtDepth(pfx, saved_val, depth_u8, allocator);
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

        /// Go BART: func (n *node[V]) allRec(path stridePath, depth int, is4 bool, yield func(netip.Prefix, V) bool) bool
        /// allRec recursively walks through all prefixes in the trie and calls yield function for each
        /// Returns false if yield function returns false (early exit), true otherwise
        pub fn allRec(
            self: *const Self,
            path: *stridePath,
            depth: u8,
            is4: bool,
            yield_fn: fn (netip.Prefix, V) bool
        ) bool {
            // Go BART: for _, idx := range n.prefixes.AsSlice(&[256]uint8{})
            var prefix_buf: [256]u8 = undefined;
            const prefix_slice = self.prefixes.AsSlice(&prefix_buf);
            for (prefix_slice) |idx| {
                // Go BART: cidr := cidrFromPath(path, depth, is4, idx)
                const cidr = cidrFromPath(path.*, depth, is4, idx) catch {
                    // If cidrFromPath fails, skip this prefix
                    continue;
                };
                
                // Go BART: if !yield(cidr, n.prefixes.MustGet(idx))
                const value = self.prefixes.mustGet(idx);
                if (!yield_fn(cidr, value)) {
                    // Go BART: return false // early exit
                    return false;
                }
            }

            // Go BART: for i, addr := range n.children.AsSlice(&[256]uint8{})
            var children_buf: [256]u8 = undefined;
            const children_slice = self.children.AsSlice(&children_buf);
            for (children_slice, 0..) |addr, i| {
                const child_item = self.children.Items()[i];
                
                // Go BART: switch kid := n.children.Items[i].(type)
                switch (child_item) {
                    .node => |kid_node| {
                        // Go BART: case *node[V]: path[depth] = addr
                        path[depth] = addr;
                        // Go BART: if !kid.allRec(path, depth+1, is4, yield)
                        if (!kid_node.allRec(path, depth + 1, is4, yield_fn)) {
                            // Go BART: return false // early exit
                            return false;
                        }
                    },
                    .leaf => |kid_leaf| {
                        // Go BART: case *leafNode[V]: if !yield(kid.prefix, kid.value)
                        if (!yield_fn(kid_leaf.prefix, kid_leaf.value)) {
                            // Go BART: return false // early exit
                            return false;
                        }
                    },
                    .fringe => |kid_fringe| {
                        // Go BART: case *fringeNode[V]: fringePfx := cidrForFringe(path[:], depth, is4, addr)
                        const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                        // Go BART: if !yield(fringePfx, kid.value)
                        if (!yield_fn(fringe_pfx, kid_fringe.value)) {
                            // Go BART: return false // early exit
                            return false;
                        }
                    },
                }
            }

            // Go BART: return true
            return true;
        }

        /// Go BART: func (n *node[V]) eachLookupPrefix(octets []byte, depth int, is4 bool, pfxIdx uint, yield func(netip.Prefix, V) bool) (ok bool)
        /// eachLookupPrefix does an all prefix match in the 8-bit (stride) routing table
        /// at this depth and calls yield() for any matching CIDR.
        pub fn eachLookupPrefix(
            self: *const Self,
            octets: []const u8,
            depth: u8,
            is4: bool,
            pfx_idx: u32,
            yield_fn: fn (netip.Prefix, V) bool
        ) bool {
            // Go BART: path needed below more than once in loop
            var path: stridePath = [_]u8{0} ** maxTreeDepth;
            // Go BART: copy(path[:], octets)
            const copy_len = @min(octets.len, maxTreeDepth);
            @memcpy(path[0..copy_len], octets[0..copy_len]);
            
            // Go BART: fast forward, it's a /8 route, too big for bitset256
            var idx = pfx_idx;
            if (pfx_idx > 255) {
                idx >>= 1;
            }
            var idx_u8 = @as(u8, @intCast(idx)); // now it fits into uint8
            
            // Go BART: for ; idx > 0; idx >>= 1
            while (idx_u8 > 0) : (idx_u8 >>= 1) {
                if (self.prefixes.Test(idx_u8)) {
                    const val = self.prefixes.mustGet(idx_u8);
                    const cidr = cidrFromPath(path, depth, is4, idx_u8) catch {
                        continue; // Skip on error
                    };
                    
                    if (!yield_fn(cidr, val)) {
                        return false;
                    }
                }
            }
            
            return true;
        }

        /// Go BART: func (n *node[V]) eachSubnet(octets []byte, depth int, is4 bool, pfxIdx uint8, yield func(netip.Prefix, V) bool) bool
        /// eachSubnet calls yield() for any covered CIDR by parent prefix in natural CIDR sort order.
        pub fn eachSubnet(
            self: *const Self,
            octets: []const u8,
            depth: u8,
            is4: bool,
            pfx_idx: u8,
            yield_fn: fn (netip.Prefix, V) bool
        ) bool {
            // Go BART: octets as array, needed below more than once
            var path: stridePath = [_]u8{0} ** maxTreeDepth;
            // Go BART: copy(path[:], octets)
            const copy_len = @min(octets.len, maxTreeDepth);
            @memcpy(path[0..copy_len], octets[0..copy_len]);
            
            // Go BART: pfxFirstAddr, pfxLastAddr := art.IdxToRange256(pfxIdx)
            const pfx_range = base_index.idxToRange256(pfx_idx) catch {
                return true; // On error, return early
            };
            const pfx_first_addr = pfx_range.first;
            const pfx_last_addr = pfx_range.last;
            
            // Go BART: allCoveredIndices := make([]uint8, 0, maxItems)
            var all_covered_indices: std.ArrayList(u8) = .empty;
            defer all_covered_indices.deinit(std.heap.page_allocator);
            
            // Go BART: for _, idx := range n.prefixes.AsSlice(&[256]uint8{})
            var prefix_buf: [256]u8 = undefined;
            const prefix_slice = self.prefixes.AsSlice(&prefix_buf);
            
            for (prefix_slice) |idx| {
                // Go BART: thisFirstAddr, thisLastAddr := art.IdxToRange256(idx)
                const this_range = base_index.idxToRange256(idx) catch {
                    continue; // Skip on error
                };
                const this_first_addr = this_range.first;
                const this_last_addr = this_range.last;
                
                // Go BART: if thisFirstAddr >= pfxFirstAddr && thisLastAddr <= pfxLastAddr
                if (this_first_addr >= pfx_first_addr and this_last_addr <= pfx_last_addr) {
                    all_covered_indices.append(std.heap.page_allocator, idx) catch continue;
                }
            }

            // Go BART: sort indices in CIDR sort order
            // Go BART: slices.SortFunc(allCoveredIndices, cmpIndexRank)
            std.sort.pdq(u8, all_covered_indices.items, {}, cmpIndexRank);

            // Go BART: 2. collect all covered child addrs by prefix
            var all_covered_child_addrs: std.ArrayList(u8) = .empty;
            defer all_covered_child_addrs.deinit(std.heap.page_allocator);

            // Go BART: for _, addr := range n.children.AsSlice(&[256]uint8{})
            var children_buf: [256]u8 = undefined;
            const children_slice = self.children.AsSlice(&children_buf);

            for (children_slice) |addr| {
                // Go BART: if addr >= pfxFirstAddr && addr <= pfxLastAddr
                if (addr >= pfx_first_addr and addr <= pfx_last_addr) {
                    all_covered_child_addrs.append(std.heap.page_allocator, addr) catch continue;
                }
            }
            
            // Go BART: 3. yield covered indices, pathcomp prefixes and childs in CIDR sort order
            var addr_cursor: usize = 0;
            
            // Go BART: yield indices and childs in CIDR sort order
            for (all_covered_indices.items) |pfx_idx_item| {
                // Go BART: pfxOctet, _ := art.IdxToPfx256(pfxIdx)
                const pfx_result = base_index.idxToPfx256(pfx_idx_item) catch {
                    continue; // Skip on error
                };
                const pfx_octet = pfx_result.octet;
                
                // Go BART: yield all childs before idx
                while (addr_cursor < all_covered_child_addrs.items.len) {
                    const addr = all_covered_child_addrs.items[addr_cursor];
                    // Go BART: if addr >= pfxOctet { break }
                    if (addr >= pfx_octet) {
                        break;
                    }
                    
                    // Go BART: yield the node or leaf?
                    const child_result = self.children.Get(addr);
                    if (child_result.ok) {
                        switch (child_result.value) {
                            .node => |kid_node| {
                                // Go BART: case *node[V]: path[depth] = addr
                                path[depth] = addr;
                                // Go BART: if !kid.allRecSorted(path, depth+1, is4, yield)
                                if (!kid_node.allRecSorted(&path, depth + 1, is4, yield_fn)) {
                                    return false;
                                }
                            },
                            .leaf => |kid_leaf| {
                                // Go BART: case *leafNode[V]: if !yield(kid.prefix, kid.value)
                                if (!yield_fn(kid_leaf.prefix, kid_leaf.value)) {
                                    return false;
                                }
                            },
                            .fringe => |kid_fringe| {
                                // Go BART: case *fringeNode[V]: fringePfx := cidrForFringe(path[:], depth, is4, addr)
                                const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                                // Go BART: if !yield(fringePfx, kid.value)
                                if (!yield_fn(fringe_pfx, kid_fringe.value)) {
                                    return false;
                                }
                            },
                        }
                    }
                    
                    addr_cursor += 1;
                }
                
                // Go BART: yield the prefix for this idx
                const cidr = cidrFromPath(path, depth, is4, pfx_idx_item) catch {
                    continue; // Skip on error
                };
                // Go BART: n.prefixes.Items[i] not possible after sorting allIndices
                const value = self.prefixes.mustGet(pfx_idx_item);
                if (!yield_fn(cidr, value)) {
                    return false;
                }
            }
            
            // Go BART: yield the rest of leaves and nodes (rec-descent)
            while (addr_cursor < all_covered_child_addrs.items.len) {
                const addr = all_covered_child_addrs.items[addr_cursor];
                
                // Go BART: yield the node or leaf?
                const child_result = self.children.Get(addr);
                if (child_result.ok) {
                    switch (child_result.value) {
                        .node => |kid_node| {
                            // Go BART: case *node[V]: path[depth] = addr
                            path[depth] = addr;
                            // Go BART: if !kid.allRecSorted(path, depth+1, is4, yield)
                            if (!kid_node.allRecSorted(&path, depth + 1, is4, yield_fn)) {
                                return false;
                            }
                        },
                        .leaf => |kid_leaf| {
                            // Go BART: case *leafNode[V]: if !yield(kid.prefix, kid.value)
                            if (!yield_fn(kid_leaf.prefix, kid_leaf.value)) {
                                return false;
                            }
                        },
                        .fringe => |kid_fringe| {
                            // Go BART: case *fringeNode[V]: fringePfx := cidrForFringe(path[:], depth, is4, addr)
                            const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                            // Go BART: if !yield(fringePfx, kid.value)
                            if (!yield_fn(fringe_pfx, kid_fringe.value)) {
                                return false;
                            }
                        },
                    }
                }
                
                addr_cursor += 1;
            }
            
            return true;
        }

        /// Go BART: func cmpIndexRank(aIdx, bIdx uint8) int
        /// Sort indexes in prefix sort order.
        /// Returns comparison result for sorting (negative if a < b, 0 if equal, positive if a > b)
        fn cmpIndexRank(context: void, a_idx: u8, b_idx: u8) bool {
            _ = context;
            
            // Go BART: aOctet, aBits := art.IdxToPfx256(aIdx)
            const a_result = base_index.idxToPfx256(a_idx) catch {
                return false; // On error, treat as equal
            };
            const a_octet = a_result.octet;
            const a_bits = a_result.pfx_len;
            
            // Go BART: bOctet, bBits := art.IdxToPfx256(bIdx)
            const b_result = base_index.idxToPfx256(b_idx) catch {
                return false; // On error, treat as equal
            };
            const b_octet = b_result.octet;
            const b_bits = b_result.pfx_len;
            
            // Go BART: cmp the prefixes, first by address and then by bits
            if (a_octet == b_octet) {
                // Go BART: if aBits <= bBits { return -1 }
                return a_bits < b_bits; // shorter prefix first
            }
            
            // Go BART: if aOctet < bOctet { return -1 }
            return a_octet < b_octet;
        }

        /// Go BART: func (n *node[V]) allRecSorted(path stridePath, depth int, is4 bool, yield func(netip.Prefix, V) bool) bool
        /// allRecSorted recursively walks through all prefixes in the trie and calls yield function for each
        /// in CIDR sort order (by address first, then by prefix length)
        /// Returns false if yield function returns false (early exit), true otherwise
        pub fn allRecSorted(
            self: *const Self,
            path: *stridePath,
            depth: u8,
            is4: bool,
            yield_fn: fn (netip.Prefix, V) bool
        ) bool {
            // Go BART: get slice of all child octets, sorted by addr
            var children_buf: [256]u8 = undefined;
            const all_child_addrs = self.children.AsSlice(&children_buf);
            
            // Go BART: get slice of all indexes, sorted by idx
            var prefix_buf: [256]u8 = undefined;
            const all_indices_slice = self.prefixes.AsSlice(&prefix_buf);
            
            // Create a copy for sorting (Go BART: allIndices := n.prefixes.AsSlice(...))
            var indices_for_sorting: std.ArrayList(u8) = .empty;
            defer indices_for_sorting.deinit(std.heap.page_allocator);

            for (all_indices_slice) |idx| {
                indices_for_sorting.append(std.heap.page_allocator, idx) catch return false;
            }
            
            // Go BART: sort indices in CIDR sort order
            // Go BART: slices.SortFunc(allIndices, cmpIndexRank)
            std.sort.pdq(u8, indices_for_sorting.items, {}, cmpIndexRank);
            
            var child_cursor: usize = 0;
            
            // Go BART: yield indices and childs in CIDR sort order
            for (indices_for_sorting.items) |pfx_idx| {
                // Go BART: pfxOctet, _ := art.IdxToPfx256(pfxIdx)
                const pfx_result = base_index.idxToPfx256(pfx_idx) catch {
                    continue; // Skip on error
                };
                const pfx_octet = pfx_result.octet;
                
                // Go BART: yield all childs before idx
                while (child_cursor < all_child_addrs.len) {
                    const child_addr = all_child_addrs[child_cursor];
                    
                    // Go BART: if childAddr >= pfxOctet { break }
                    if (child_addr >= pfx_octet) {
                        break;
                    }
                    
                    // Go BART: yield the node (rec-descent) or leaf
                    const child_item = self.children.Items()[child_cursor];
                    switch (child_item) {
                        .node => |kid_node| {
                            // Go BART: case *node[V]: path[depth] = childAddr
                            path[depth] = child_addr;
                            // Go BART: if !kid.allRecSorted(path, depth+1, is4, yield)
                            if (!kid_node.allRecSorted(path, depth + 1, is4, yield_fn)) {
                                return false;
                            }
                        },
                        .leaf => |kid_leaf| {
                            // Go BART: case *leafNode[V]: if !yield(kid.prefix, kid.value)
                            if (!yield_fn(kid_leaf.prefix, kid_leaf.value)) {
                                return false;
                            }
                        },
                        .fringe => |kid_fringe| {
                            // Go BART: case *fringeNode[V]: fringePfx := cidrForFringe(path[:], depth, is4, childAddr)
                            const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, child_addr);
                            // Go BART: if !yield(fringePfx, kid.value)
                            if (!yield_fn(fringe_pfx, kid_fringe.value)) {
                                return false;
                            }
                        },
                    }
                    
                    child_cursor += 1;
                }
                
                // Go BART: yield the prefix for this idx
                // Go BART: cidr := cidrFromPath(path, depth, is4, pfxIdx)
                const cidr = cidrFromPath(path.*, depth, is4, pfx_idx) catch {
                    continue; // Skip on error
                };
                
                // Go BART: if !yield(cidr, n.prefixes.MustGet(pfxIdx))
                const value = self.prefixes.mustGet(pfx_idx);
                if (!yield_fn(cidr, value)) {
                    return false;
                }
            }
            
            // Go BART: yield the rest of leaves and nodes (rec-descent)
            while (child_cursor < all_child_addrs.len) {
                const addr = all_child_addrs[child_cursor];
                const child_item = self.children.Items()[child_cursor];
                
                switch (child_item) {
                    .node => |kid_node| {
                        // Go BART: case *node[V]: path[depth] = addr
                        path[depth] = addr;
                        // Go BART: if !kid.allRecSorted(path, depth+1, is4, yield)
                        if (!kid_node.allRecSorted(path, depth + 1, is4, yield_fn)) {
                            return false;
                        }
                    },
                    .leaf => |kid_leaf| {
                        // Go BART: case *leafNode[V]: if !yield(kid.prefix, kid.value)
                        if (!yield_fn(kid_leaf.prefix, kid_leaf.value)) {
                            return false;
                        }
                    },
                    .fringe => |kid_fringe| {
                        // Go BART: case *fringeNode[V]: fringePfx := cidrForFringe(path[:], depth, is4, addr)
                        const fringe_pfx = cidrForFringe(path[0..depth], depth, is4, addr);
                        // Go BART: if !yield(fringePfx, kid.value)
                        if (!yield_fn(fringe_pfx, kid_fringe.value)) {
                            return false;
                        }
                    },
                }
                
                child_cursor += 1;
            }
            
            // Go BART: return true
            return true;
        }

        /// Go BART: func (n *node[V]) unionRec(o *node[V], depth int) (duplicates int)
        /// unionRec merges another node into this node recursively.
        /// The values are cloned before merging.
        pub fn unionRec(self: *Self, other: *const Self, depth: u8) !u32 {
            var duplicates: u32 = 0;

            // for all prefixes in other node do ...
            var buf: [256]u8 = undefined;
            const other_prefix_indices = other.prefixes.AsSlice(&buf);
            for (other.prefixes.Items(), 0..) |other_val, i| {
                const other_idx = other_prefix_indices[i];
                
                // clone/copy the value from other node at idx
                const cloned_val = cloneOrCopy(V, other_val);

                // insert/overwrite cloned value from other into self
                if (try self.prefixes.insertAt(other_idx, cloned_val)) {
                    // this prefix is duplicate in self and other
                    duplicates += 1;
                }
            }

            // for all child addrs in other node do ...
            var child_buf: [256]u8 = undefined;
            const other_child_indices = other.children.AsSlice(&child_buf);
            for (other.children.Items(), 0..) |other_child, i| {
                const addr = other_child_indices[i];

                // try to get child at same addr from self
                const this_child_result = self.children.Get(addr);
                if (!this_child_result.ok) { 
                    // NULL, ... slot at addr is empty
                    switch (other_child) {
                        .node => |other_node| { // NULL, node
                            const cloned_node = try other_node.cloneRec(self.allocator);
                            _ = try self.children.insertAt(addr, Self.ChildNode{ .node = cloned_node });
                            continue;
                        },
                        .leaf => |other_leaf| { // NULL, leaf
                            const cloned_leaf = try other_leaf.cloneLeaf(self.allocator);
                            _ = try self.children.insertAt(addr, Self.ChildNode{ .leaf = cloned_leaf });
                            continue;
                        },
                        .fringe => |other_fringe| { // NULL, fringe
                            const cloned_fringe = try other_fringe.cloneFringe(self.allocator);
                            _ = try self.children.insertAt(addr, Self.ChildNode{ .fringe = cloned_fringe });
                            continue;
                        },
                    }
                }

                // Process the combinations when both slots have children
                const this_child = this_child_result.value;
                // TODO: Implement the 9 combinations processing
                // For now, handle the simple case
                switch (this_child) {
                    .node => |this_node| {
                        switch (other_child) {
                            .node => |other_node| { // node, node
                                duplicates += try this_node.unionRec(other_node, depth + 1);
                            },
                            .leaf => |other_leaf| { // node, leaf
                                if (try this_node.insertAtDepth(other_leaf.prefix, cloneOrCopy(V, other_leaf.value), depth + 1, self.allocator)) {
                                    duplicates += 1;
                                }
                            },
                            .fringe => |other_fringe| { // node, fringe
                                if (try this_node.prefixes.insertAt(1, cloneOrCopy(V, other_fringe.value))) {
                                    duplicates += 1;
                                }
                            },
                        }
                    },
                    .leaf => |this_leaf| { // leaf, ...
                        switch (other_child) {
                            .node => |other_node| { // leaf, node
                                // create new node
                                const nc = try self.allocator.create(Self);
                                nc.* = Self.init(self.allocator);

                                // push this leaf down
                                _ = try nc.insertAtDepth(this_leaf.prefix, this_leaf.value, depth + 1, self.allocator);

                                // free the old leaf before overwriting
                                self.allocator.destroy(this_leaf);

                                // insert the new node at current addr (overwrites old leaf slot)
                                _ = try self.children.insertAt(addr, Self.ChildNode{ .node = nc });

                                // unionRec this new node with other kid node (other is read-only, no clone needed)
                                duplicates += try nc.unionRec(other_node, depth + 1);
                            },
                            .leaf => |other_leaf| { // leaf, leaf
                                // shortcut, prefixes are equal
                                if (this_leaf.prefix.eql(&other_leaf.prefix)) {
                                    this_leaf.value = cloneOrCopy(V, other_leaf.value);
                                    duplicates += 1;
                                    continue;
                                }

                                // create new node
                                const nc = try self.allocator.create(Self);
                                nc.* = Self.init(self.allocator);

                                // push this leaf down
                                _ = try nc.insertAtDepth(this_leaf.prefix, this_leaf.value, depth + 1, self.allocator);

                                // insert at depth other leaf value, maybe duplicate
                                if (try nc.insertAtDepth(other_leaf.prefix, cloneOrCopy(V, other_leaf.value), depth + 1, self.allocator)) {
                                    duplicates += 1;
                                }

                                // free the old leaf before overwriting
                                self.allocator.destroy(this_leaf);

                                // insert the new node at current addr (overwrites old leaf slot)
                                _ = try self.children.insertAt(addr, Self.ChildNode{ .node = nc });
                            },
                            .fringe => |other_fringe| { // leaf, fringe
                                // create new node
                                const nc = try self.allocator.create(Self);
                                nc.* = Self.init(self.allocator);

                                // push this leaf down
                                _ = try nc.insertAtDepth(this_leaf.prefix, this_leaf.value, depth + 1, self.allocator);

                                // push fringe down, it becomes the default route
                                if (try nc.prefixes.insertAt(1, cloneOrCopy(V, other_fringe.value))) {
                                    duplicates += 1;
                                }

                                // free the old leaf before overwriting
                                self.allocator.destroy(this_leaf);

                                // insert the new node at current addr (overwrites old leaf slot)
                                _ = try self.children.insertAt(addr, Self.ChildNode{ .node = nc });
                            },
                        }
                    },
                    .fringe => |this_fringe| { // fringe, ...
                        switch (other_child) {
                            .node => |other_node| { // fringe, node
                                // create new node
                                const nc = try self.allocator.create(Self);
                                nc.* = Self.init(self.allocator);

                                // push this fringe down, it becomes the default route
                                if (try nc.prefixes.insertAt(1, this_fringe.value)) {
                                    // This shouldn't be a duplicate, but follow Go BART logic
                                }

                                // free the old fringe before overwriting
                                self.allocator.destroy(this_fringe);

                                // insert the new node at current addr (overwrites old fringe slot)
                                _ = try self.children.insertAt(addr, Self.ChildNode{ .node = nc });

                                // unionRec this new node with other kid node (other is read-only, no clone needed)
                                duplicates += try nc.unionRec(other_node, depth + 1);
                            },
                            .leaf => |other_leaf| { // fringe, leaf
                                // create new node
                                const nc = try self.allocator.create(Self);
                                nc.* = Self.init(self.allocator);

                                // push this fringe down, it becomes the default route
                                if (try nc.prefixes.insertAt(1, this_fringe.value)) {
                                    // This shouldn't be a duplicate, but follow Go BART logic
                                }

                                // push other leaf value down
                                if (try nc.insertAtDepth(other_leaf.prefix, cloneOrCopy(V, other_leaf.value), depth + 1, self.allocator)) {
                                    duplicates += 1;
                                }

                                // free the old fringe before overwriting
                                self.allocator.destroy(this_fringe);

                                // insert the new node at current addr (overwrites old fringe slot)
                                _ = try self.children.insertAt(addr, Self.ChildNode{ .node = nc });
                            },
                            .fringe => |other_fringe| { // fringe, fringe
                                this_fringe.value = cloneOrCopy(V, other_fringe.value);
                                duplicates += 1;
                            },
                        }
                    },
                }
            }

            return duplicates;
        }

        /// overlapsPrefixAtDepth returns true if node overlaps with prefix
        /// starting with prefix octet at depth.
        /// Needed for path compressed prefix some level down in the node trie.
        /// Go BART: func (n *node[V]) overlapsPrefixAtDepth(pfx netip.Prefix, depth int) bool
        pub fn overlapsPrefixAtDepth(self: *const Self, pfx: netip.Prefix, depth: u8) bool {
            const ip = pfx.addr();
            const bits = pfx.bits();
            const octets = ip.asSlice();
            const depth_result = maxDepthAndLastBits(bits);
            const max_depth = depth_result.max_depth;
            const last_bits = depth_result.last_bits;

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

                if (!current_node.children.Test(octet)) {
                    return false;
                }

                // next child, node or leaf
                const kid = current_node.children.mustGet(octet);
                switch (kid) {
                    .node => |node_ptr| {
                        current_node = node_ptr;
                        continue;
                    },
                    
                    .leaf => |leaf_ptr| {
                        return leaf_ptr.prefix.overlaps(&pfx);
                    },
                    
                    .fringe => |_| {
                        return true;
                    },
                }
            }

            // Should not reach here with valid prefix
            return false;
        }

        /// overlapsIdx returns true if node overlaps with prefix.
        /// Go BART: func (n *node[V]) overlapsIdx(idx uint8) bool
        pub fn overlapsIdx(self: *const Self, idx: u8) bool {
            // 1. Test if any route in this node overlaps prefix?
            if (self.lpmTest(idx)) {
                return true;
            }

            // 2. Test if prefix overlaps any route in this node
            // use bitset intersections instead of range loops
            // shallow copy pre allocated bitset for idx
            const lookup_prefix = @import("lookup_prefix_routes.zig");
            const alloted_prefix_routes = lookup_prefix.idxToPrefixRoutes(idx);
            if (alloted_prefix_routes.intersectsAny(&self.prefixes.bitset)) {
                return true;
            }

            // 3. Test if prefix overlaps any child in this node
            const lookup_fringe = @import("lookup_fringe_routes.zig");
            const alloted_host_routes = lookup_fringe.idxToFringeRoutes(idx);
            return alloted_host_routes.intersectsAny(&self.children.bitset);
        }

        /// overlaps returns true if any IP in the nodes self or other overlaps.
        /// Simplified implementation for now.
        /// Go BART: func (n *node[V]) overlaps(o *node[V], depth int) bool
        pub fn overlaps(self: *const Self, other: *const Self, depth: u8) bool {
            _ = depth; // unused for now
            
            // 1. Test if any routes overlaps (simple bitset intersection)
            if (self.prefixes.len() > 0 and other.prefixes.len() > 0) {
                if (self.prefixes.bitset.intersectsAny(&other.prefixes.bitset)) {
                    return true;
                }
            }

            // 2. Test if nodes have children with same octets (simplified check)
            if (self.children.len() > 0 and other.children.len() > 0) {
                if (self.children.bitset.intersectsAny(&other.children.bitset)) {
                    // Could recursively check child overlaps, but for now return true
                    return true;
                }
            }

            return false;
        }

        /// Helper function to clone a child node (ChildNode union)
        /// Go BART equivalent: clone functionality
        fn cloneChild(child: ChildNode, allocator: std.mem.Allocator) !ChildNode {
            switch (child) {
                .node => |node_ptr| {
                    return Self.ChildNode{ .node = try node_ptr.cloneRec(allocator) };
                },
                .leaf => |leaf_ptr| {
                    return Self.ChildNode{ .leaf = try leaf_ptr.cloneLeaf(allocator) };
                },
                .fringe => |fringe_ptr| {
                    return Self.ChildNode{ .fringe = try fringe_ptr.cloneFringe(allocator) };
                },
            }
        }
    };
}

// Go BART: type leafNode[V any] struct { prefix netip.Prefix; value V }
// leafNode is a prefix with value, used as a path compressed child.
pub fn LeafNode(comptime V: type) type {
    return struct {
        const Self = @This();

        prefix: netip.Prefix,
        value: V,
        rc: u32 = 1,

        pub fn init(prefix: netip.Prefix, value: V) Self {
            return Self{
                .prefix = prefix,
                .value = value,
                .rc = 1,
            };
        }

        pub fn incRef(self: *Self) void {
            self.rc += 1;
        }

        pub fn decRef(self: *Self, allocator: std.mem.Allocator) void {
            self.rc -= 1;
            if (self.rc == 0) {
                allocator.destroy(self);
            }
        }

        pub fn cloneLeaf(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const cloned = try allocator.create(Self);
            cloned.* = Self{
                .prefix = self.prefix,
                .value = cloneOrCopy(V, self.value),
                .rc = 1,
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

        value: V,
        rc: u32 = 1,

        pub fn init(value: V) Self {
            return Self{
                .value = value,
                .rc = 1,
            };
        }

        pub fn incRef(self: *Self) void {
            self.rc += 1;
        }

        pub fn decRef(self: *Self, allocator: std.mem.Allocator) void {
            self.rc -= 1;
            if (self.rc == 0) {
                allocator.destroy(self);
            }
        }

        pub fn cloneFringe(self: *const Self, allocator: std.mem.Allocator) !*Self {
            const cloned = try allocator.create(Self);
            cloned.* = Self{
                .value = cloneOrCopy(V, self.value),
                .rc = 1,
            };
            return cloned;
        }
    };
}

// Tests for Node implementations
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

test "cloneRec Go BART compatibility" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create original node with simple structure
    var original = TestNode.init(testing.allocator);
    defer original.deinit();
    
    // Add some prefixes only
    _ = try original.prefixes.insertAt(1, 100);
    _ = try original.prefixes.insertAt(5, 500);
    
    // Clone the structure
    const cloned = try original.cloneRec(testing.allocator);
    defer {
        cloned.deinit();
        testing.allocator.destroy(cloned);
    }
    
    // Verify structure was cloned correctly
    try testing.expectEqual(original.prefixes.len(), cloned.prefixes.len());
    try testing.expectEqual(original.children.len(), cloned.children.len());
    
    // Verify prefixes were cloned
    const orig_result1 = original.prefixes.Get(1);
    const clone_result1 = cloned.prefixes.Get(1);
    try testing.expect(orig_result1.ok and clone_result1.ok);
    try testing.expectEqual(orig_result1.value, clone_result1.value);
    
    const orig_result5 = original.prefixes.Get(5);
    const clone_result5 = cloned.prefixes.Get(5);
    try testing.expect(orig_result5.ok and clone_result5.ok);
    try testing.expectEqual(orig_result5.value, clone_result5.value);
    
    // Verify independence: modifying original shouldn't affect clone
    _ = try original.prefixes.insertAt(7, 700);
    const orig_result7 = original.prefixes.Get(7);
    const clone_result7 = cloned.prefixes.Get(7);
    try testing.expect(orig_result7.ok and !clone_result7.ok);
}

test "allRec Go BART compatibility" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with simple structure
    var root = TestNode.init(testing.allocator);
    defer root.deinit();
    
    // Add some prefixes to root
    _ = try root.prefixes.insertAt(1, 100);   // index 1, value 100
    _ = try root.prefixes.insertAt(5, 500);   // index 5, value 500
    
    // Simple yield function for testing
    const SimpleYield = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            // For test simplification, just return true to continue
            _ = prefix;
            _ = value;
            return true;
        }
    };
    
    // Initialize path array
    var path: stridePath = [_]u8{0} ** maxTreeDepth;
    
    // Call allRec with IPv4 flag
    const result = root.allRec(&path, 0, true, SimpleYield.yieldFn);
    
    // Verify the result
    try testing.expect(result); // Should complete successfully
}

test "allRec early exit" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with multiple prefixes
    var root = TestNode.init(testing.allocator);
    defer root.deinit();
    
    // Add multiple prefixes
    _ = try root.prefixes.insertAt(1, 100);
    _ = try root.prefixes.insertAt(5, 500);
    _ = try root.prefixes.insertAt(10, 1000);
    
    // Test early exit - return false after first item
    const EarlyExit = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return false; // Always exit early
        }
    };
    
    var path: stridePath = [_]u8{0} ** maxTreeDepth;
    
    // Call allRec - should exit early
    const result = root.allRec(&path, 0, true, EarlyExit.yieldFn);
    
    // Verify early exit behavior
    try testing.expect(!result); // Should return false due to early exit
}

test "allRecSorted basic functionality" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with multiple prefixes
    var root = TestNode.init(testing.allocator);
    defer root.deinit();
    
    // Add some prefixes
    _ = try root.prefixes.insertAt(128, 1000); 
    _ = try root.prefixes.insertAt(64, 500);   
    _ = try root.prefixes.insertAt(32, 200);   
    
    // Simple yield function that just returns true (testing no crash)
    const SimpleYield = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return true; // continue iteration
        }
    };
    
    var path: stridePath = [_]u8{0} ** maxTreeDepth;
    
    // Call allRecSorted - should complete without error
    const result = root.allRecSorted(&path, 0, true, SimpleYield.yieldFn);
    
    // Verify the result
    try testing.expect(result); // Should complete successfully
}

test "allRecSorted early exit" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with multiple prefixes
    var root = TestNode.init(testing.allocator);
    defer root.deinit();
    
    // Add multiple prefixes
    _ = try root.prefixes.insertAt(1, 100);
    _ = try root.prefixes.insertAt(64, 500);
    _ = try root.prefixes.insertAt(128, 1000);
    
    // Test early exit - return false immediately
    const EarlyExit = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return false; // Always exit early
        }
    };
    
    var path: stridePath = [_]u8{0} ** maxTreeDepth;
    
    // Call allRecSorted - should exit early
    const result = root.allRecSorted(&path, 0, true, EarlyExit.yieldFn);
    
    // Verify early exit behavior
    try testing.expect(!result); // Should return false due to early exit
}

test "unionRec basic functionality" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create two test nodes for union
    var node1 = TestNode.init(testing.allocator);
    defer node1.deinit();
    var node2 = TestNode.init(testing.allocator);
    defer node2.deinit();
    
    // Add some prefixes to node1
    _ = try node1.prefixes.insertAt(1, 100);
    _ = try node1.prefixes.insertAt(64, 640);
    
    // Add some prefixes to node2 (some overlapping)
    _ = try node2.prefixes.insertAt(1, 111);  // duplicate - should count
    _ = try node2.prefixes.insertAt(128, 1280); // new prefix
    
    // Perform union
    const duplicates = try node1.unionRec(&node2, 0);
    
    // Verify results
    try testing.expectEqual(@as(u32, 1), duplicates); // One duplicate (index 1)
    
    // Verify node1 now has all prefixes
    try testing.expectEqual(@as(usize, 3), node1.prefixes.len());
    
    // Check specific values
    const result1 = node1.prefixes.Get(1);
    const result64 = node1.prefixes.Get(64);
    const result128 = node1.prefixes.Get(128);
    
    try testing.expect(result1.ok and result64.ok and result128.ok);
    try testing.expectEqual(@as(i32, 111), result1.value); // Should be overwritten
    try testing.expectEqual(@as(i32, 640), result64.value); // Original value
    try testing.expectEqual(@as(i32, 1280), result128.value); // New value from node2
}

test "unionRec with empty nodes" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Test union with empty node
    var node1 = TestNode.init(testing.allocator);
    defer node1.deinit();
    var empty_node = TestNode.init(testing.allocator);
    defer empty_node.deinit();
    
    // Add some prefixes to node1
    _ = try node1.prefixes.insertAt(1, 100);
    _ = try node1.prefixes.insertAt(64, 640);
    
    // Union with empty node
    const duplicates = try node1.unionRec(&empty_node, 0);
    
    // Should have no duplicates and no changes
    try testing.expectEqual(@as(u32, 0), duplicates);
    try testing.expectEqual(@as(usize, 2), node1.prefixes.len());
    
    // Union empty node with filled node
    const duplicates2 = try empty_node.unionRec(&node1, 0);
    
    // Should have no duplicates but empty_node should now have all prefixes
    try testing.expectEqual(@as(u32, 0), duplicates2);
    try testing.expectEqual(@as(usize, 2), empty_node.prefixes.len());
}

test "unionRec fringe-fringe case" {
    const TestV = i32;
    const TestNode = Node(TestV);
    const TestFringeNode = FringeNode(TestV);
    
    // Create two nodes with fringe children at same address
    var node1 = TestNode.init(testing.allocator);
    defer {
        // deinit() will handle all children cleanup automatically
        node1.deinit();
    }
    
    var node2 = TestNode.init(testing.allocator);
    defer {
        // deinit() will handle all children cleanup automatically
        node2.deinit();
    }
    
    // Create fringe nodes
    const fringe1 = try testing.allocator.create(TestFringeNode);
    fringe1.* = TestFringeNode{ .value = 1000 };
    _ = try node1.children.insertAt(10, TestNode.ChildNode{ .fringe = fringe1 });
    
    const fringe2 = try testing.allocator.create(TestFringeNode);
    fringe2.* = TestFringeNode{ .value = 2000 };
    _ = try node2.children.insertAt(10, TestNode.ChildNode{ .fringe = fringe2 });
    
    // Perform union - should handle fringe, fringe case
    const duplicates = try node1.unionRec(&node2, 0);
    
    // Should count as one duplicate
    try testing.expectEqual(@as(u32, 1), duplicates);
    
    // Check that fringe value was overwritten
    const child_result = node1.children.Get(10);
    try testing.expect(child_result.ok);
    
    switch (child_result.value) {
        .fringe => |fringe_node| {
            try testing.expectEqual(@as(i32, 2000), fringe_node.value);
        },
        else => try testing.expect(false),
    }
}

test "unionRec complex children combinations" {
    const TestV = i32;
    const TestNode = Node(TestV);
    const TestLeafNode = LeafNode(TestV);
    
    // Create nodes with leaf children for NULL, leaf case
    var node1 = TestNode.init(testing.allocator);
    defer {
        // deinit() will handle all children cleanup automatically
        node1.deinit();
    }
    
    var node2 = TestNode.init(testing.allocator);
    defer {
        // deinit() will handle all children cleanup automatically
        node2.deinit();
    }
    
    // node1 is empty at address 20, node2 has leaf at address 20
    const leaf2 = try testing.allocator.create(TestLeafNode);
    leaf2.* = TestLeafNode{
        .prefix = netip.Prefix.fromIPv4(192, 168, 1, 0, 24),
        .value = 5000,
    };
    _ = try node2.children.insertAt(20, TestNode.ChildNode{ .leaf = leaf2 });
    
    // Perform union - should handle NULL, leaf case
    const duplicates = try node1.unionRec(&node2, 0);
    
    // Should have no duplicates (NULL, leaf case)
    try testing.expectEqual(@as(u32, 0), duplicates);
    
    // Check that leaf was copied to node1
    const child_result = node1.children.Get(20);
    try testing.expect(child_result.ok);
    
    switch (child_result.value) {
        .leaf => |leaf_node| {
            try testing.expectEqual(@as(i32, 5000), leaf_node.value);
        },
        else => try testing.expect(false),
    }
}

test "eachLookupPrefix basic functionality" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with multiple prefixes
    var node = TestNode.init(testing.allocator);
    defer node.deinit();
    
    // Add some prefixes with different indices
    _ = try node.prefixes.insertAt(1, 100);   // Default route
    _ = try node.prefixes.insertAt(128, 1280); // More specific route
    _ = try node.prefixes.insertAt(192, 1920); // Even more specific
    
    // Test path
    const octets = [_]u8{192, 168, 1, 0};
    
    // Simple yield function for testing
    const SimpleYield = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return true; // continue iteration
        }
    };
    
    // Call eachLookupPrefix - should find matching prefixes
    const result = node.eachLookupPrefix(&octets, 0, true, 192, SimpleYield.yieldFn);
    
    // Should complete successfully
    try testing.expect(result);
}

test "eachLookupPrefix early exit" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with multiple prefixes
    var node = TestNode.init(testing.allocator);
    defer node.deinit();
    
    // Add multiple prefixes
    _ = try node.prefixes.insertAt(1, 100);
    _ = try node.prefixes.insertAt(128, 1280);
    _ = try node.prefixes.insertAt(192, 1920);
    
    // Test early exit - return false immediately
    const EarlyExit = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return false; // Always exit early
        }
    };
    
    const octets = [_]u8{192, 168, 1, 0};
    
    // Call eachLookupPrefix - should exit early
    const result = node.eachLookupPrefix(&octets, 0, true, 192, EarlyExit.yieldFn);
    
    // Should return false due to early exit
    try testing.expect(!result);
}

test "eachSubnet basic functionality" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with multiple prefixes
    var node = TestNode.init(testing.allocator);
    defer node.deinit();
    
    // Add some prefixes that will be covered by a parent prefix
    _ = try node.prefixes.insertAt(64, 640);   // 128.0.0.0/2 
    _ = try node.prefixes.insertAt(128, 1280); // 192.0.0.0/1
    _ = try node.prefixes.insertAt(192, 1920); // 192.0.0.0/2
    
    // Test path
    const octets = [_]u8{192, 0, 0, 0};
    
    // Simple yield function for testing
    const SimpleYield = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return true; // continue iteration
        }
    };
    
    // Call eachSubnet with parent prefix index that covers some of the added prefixes
    const result = node.eachSubnet(&octets, 0, true, 32, SimpleYield.yieldFn); // Index for a broad prefix
    
    // Should complete successfully
    try testing.expect(result);
}

test "eachSubnet early exit" {
    const TestV = i32;
    const TestNode = Node(TestV);
    
    // Create test node with prefixes
    var node = TestNode.init(testing.allocator);
    defer node.deinit();
    
    // Add some prefixes
    _ = try node.prefixes.insertAt(64, 640);
    _ = try node.prefixes.insertAt(128, 1280);
    
    // Test early exit - return false immediately
    const EarlyExit = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return false; // Always exit early
        }
    };
    
    const octets = [_]u8{128, 0, 0, 0};
    
    // Call eachSubnet - should exit early
    const result = node.eachSubnet(&octets, 0, true, 32, EarlyExit.yieldFn);
    
    // Should return false due to early exit
    try testing.expect(!result);
}

test "eachSubnet with complex children" {
    const TestV = i32;
    const TestNode = Node(TestV);
    const TestLeafNode = LeafNode(TestV);
    
    // Create test node with children for more complex testing
    var node = TestNode.init(testing.allocator);
    defer {
        // deinit() will handle all children cleanup automatically
        node.deinit();
    }
    
    // Add some prefixes
    _ = try node.prefixes.insertAt(128, 1280);
    
    // Add a leaf child within the range
    const leaf = try testing.allocator.create(TestLeafNode);
    leaf.* = TestLeafNode{
        .prefix = netip.Prefix.fromIPv4(192, 168, 1, 0, 24),
        .value = 5000,
    };
    _ = try node.children.insertAt(192, TestNode.ChildNode{ .leaf = leaf });
    
    // Simple yield function for testing
    const SimpleYield = struct {
        fn yieldFn(prefix: netip.Prefix, value: i32) bool {
            _ = prefix;
            _ = value;
            return true; // continue iteration
        }
    };
    
    const octets = [_]u8{128, 0, 0, 0};
    
    // Call eachSubnet - should handle both prefixes and children
    const result = node.eachSubnet(&octets, 0, true, 32, SimpleYield.yieldFn);
    
    // Should complete successfully
    try testing.expect(result);
}