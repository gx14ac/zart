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

        /// prefixes contains the routes, indexed as a complete binary tree with payload V
        /// with the help of the baseIndex mapping function from the ART algorithm.
        /// (Go BART: prefixes sparse.Array256[V])
        prefixes: Array256(V),

        /// children, recursively spans the trie with a branching factor of 256.
        /// [any] is a *node, with path compression a *leaf or *fringe
        /// (Go BART: children sparse.Array256[any])
        children: Array256(*anyopaque),

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

        /// Helper function is no longer needed - using tagged union ChildNode instead

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
                        return try current_node.children.insertAt(octet, ChildNode{ .fringe = fringe });
                    }
                    // Go BART: return n.children.InsertAt(octet, &leafNode[V]{prefix: pfx, value: val})
                    const leaf = try allocator.create(LeafNodeType);
                    leaf.* = LeafNodeType.init(pfx, val);
                    return try current_node.children.insertAt(octet, ChildNode{ .leaf = leaf });
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

                        _ = try current_node.children.insertAt(octet, ChildNode{ .node = new_node });
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

                        _ = try current_node.children.insertAt(octet, ChildNode{ .node = new_node });
                        current_node = new_node;
                    },
                }
            }
            }

            @panic("unreachable");
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
