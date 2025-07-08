const std = @import("std");
const netip = @import("node.zig"); // 既存のIPAddr/Prefix実装
const art = @import("art_base_index.zig");
const SparseArray256 = @import("art_sparse_array256.zig").SparseArray256;

/// Maximum tree depth for IPv6 (16 bytes)
const maxTreeDepth = 16;

/// Stride length (8-bit = 1 byte)
const strideLen = 8;

/// Path through the trie, max 16 octets deep
pub const StridePath = [maxTreeDepth]u8;

/// ART Node structure - the core of the Adaptive Radix Tree
/// Based on Go BART's node implementation
pub fn Node(comptime V: type) type {
    return struct {
        const Self = @This();

        /// Prefixes indexed as a complete binary tree using ART baseIndex
        prefixes: SparseArray256(V),

        /// Children: recursively spans the trie with branching factor 256
        /// Can be *Node, *LeafNode, or *FringeNode (using tagged union for path compression)
        children: SparseArray256(ChildNode(V)),

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const node = try allocator.create(Self);
            node.* = .{
                .prefixes = SparseArray256(V).init(allocator),
                .children = SparseArray256(ChildNode(V)).init(allocator),
                .allocator = allocator,
            };
            return node;
        }

        pub fn deinit(self: *Self) void {
            // First deinit all children recursively
            var iter = self.children.iterator();
            while (iter.next()) |item| {
                switch (item.value) {
                    .node => |child_node| child_node.deinit(),
                    .leaf => |leaf| self.allocator.destroy(leaf),
                    .fringe => |fringe| self.allocator.destroy(fringe),
                }
            }
            
            self.prefixes.deinit();
            self.children.deinit();
            self.allocator.destroy(self);
        }

        /// Check if node is empty (no prefixes or children)
        pub fn isEmpty(self: *const Self) bool {
            return self.prefixes.len() == 0 and self.children.len() == 0;
        }

        /// Insert a prefix/value at given depth
        pub fn insertAtDepth(self: *Self, prefix: *const netip.Prefix, value: V, depth: u8) !bool {
            const bits = prefix.bits;
            const octets = prefix.addr.asSlice();
            const result = maxDepthAndLastBits(bits);
            const max_depth = result.max_depth;
            const last_bits = result.last_bits;

            var current_node = self;
            var current_depth = depth;

            while (current_depth < octets.len) : (current_depth += 1) {
                const octet = octets[current_depth];

                // Last masked octet: insert prefix into node
                if (current_depth == max_depth) {
                    const idx = art.pfxToIdx256(octet, last_bits);
                    const old_value = try current_node.prefixes.insertAt(idx, value);
                    return old_value != null;
                }

                // Check if child exists
                if (!current_node.children.testBit(octet)) {
                    // Insert path compressed as leaf or fringe
                    if (isFringe(current_depth, bits)) {
                        const fringe = try self.allocator.create(FringeNode(V));
                        fringe.* = .{ .value = value };
                        const old_child = try current_node.children.insertAt(octet, .{ .fringe = fringe });
                        return old_child != null;
                    } else {
                        const leaf = try self.allocator.create(LeafNode(V));
                        leaf.* = .{ .prefix = prefix.*, .value = value };
                        const old_child = try current_node.children.insertAt(octet, .{ .leaf = leaf });
                        return old_child != null;
                    }
                }

                // Get existing child
                const child = current_node.children.mustGet(octet);

                switch (child) {
                    .node => |node_ptr| {
                        current_node = node_ptr;
                        continue;
                    },
                    .leaf => |leaf_ptr| {
                        // Override if same prefix
                        if (leaf_ptr.prefix.eql(prefix.*)) {
                            leaf_ptr.value = value;
                            return true; // exists
                        }

                        // Create new node and push leaf down
                        const new_node = try Node(V).init(self.allocator);
                        _ = try new_node.insertAtDepth(&leaf_ptr.prefix, leaf_ptr.value, current_depth + 1);
                        
                        const old_child = try current_node.children.insertAt(octet, .{ .node = new_node });
                        // Free the old leaf that was replaced
                        if (old_child) |old| {
                            switch (old) {
                                .leaf => |old_leaf| self.allocator.destroy(old_leaf),
                                .fringe => |old_fringe| self.allocator.destroy(old_fringe),
                                .node => |old_node| old_node.deinit(),
                            }
                        }
                        current_node = new_node;
                    },
                    .fringe => |fringe_ptr| {
                        // Override if inserting another fringe
                        if (isFringe(current_depth, bits)) {
                            fringe_ptr.value = value;
                            return true; // exists
                        }

                        // Create new node and push fringe down as default route (idx=1)
                        const new_node = try Node(V).init(self.allocator);
                        _ = try new_node.prefixes.insertAt(1, fringe_ptr.value);
                        
                        const old_child = try current_node.children.insertAt(octet, .{ .node = new_node });
                        // Free the old fringe that was replaced
                        if (old_child) |old| {
                            switch (old) {
                                .leaf => |old_leaf| self.allocator.destroy(old_leaf),
                                .fringe => |old_fringe| self.allocator.destroy(old_fringe),
                                .node => |old_node| old_node.deinit(),
                            }
                        }
                        current_node = new_node;
                    },
                }
            }

            unreachable;
        }
    };
}

/// Path-compressed leaf node with prefix and value
pub fn LeafNode(comptime V: type) type {
    return struct {
        prefix: netip.Prefix,
        value: V,
    };
}

/// Path-compressed fringe node with only value (no prefix)
/// Prefix is defined by position in trie
pub fn FringeNode(comptime V: type) type {
    return struct {
        value: V,
    };
}

/// Child type for type-safe path compression
pub fn ChildNode(comptime V: type) type {
    return union(enum) {
        node: *Node(V),
        leaf: *LeafNode(V),
        fringe: *FringeNode(V),
    };
}

/// Calculate max depth and last bits from prefix length
/// Go BART: bits >> 3, uint8(bits & 7)
pub fn maxDepthAndLastBits(bits: u8) struct { max_depth: u8, last_bits: u8 } {
    // maxDepth: range from 0..4 or 0..16 !ATTENTION: not 0..3 or 0..15
    // lastBits: range from 0..7
    return .{ 
        .max_depth = bits >> 3,      // bits / 8
        .last_bits = bits & 7,       // bits % 8
    };
}

/// Check if this is a fringe node position
/// Fringes are at special positions: /8, /16, /24, ... /128
pub fn isFringe(depth: u8, bits: u8) bool {
    const result = maxDepthAndLastBits(bits);
    if (result.max_depth == 0) return false;
    return depth == result.max_depth - 1 and result.last_bits == 0;
}

test "ART Node basic operations" {
    const testing = std.testing;
    const IPAddr = netip.IPAddr;
    const Prefix = netip.Prefix;

    const node = try Node(u32).init(testing.allocator);
    defer node.deinit();

    // Test empty
    try testing.expect(node.isEmpty());

    // Test insert simple prefix
    const addr1 = IPAddr{ .v4 = .{ 10, 0, 0, 0 } };
    const pfx1 = Prefix.init(&addr1, 8);
    try testing.expect(try node.insertAtDepth(&pfx1, 100, 0) == false); // New

    try testing.expect(!node.isEmpty());

    // Test insert deeper prefix
    const addr2 = IPAddr{ .v4 = .{ 10, 1, 0, 0 } };
    const pfx2 = Prefix.init(&addr2, 16);
    try testing.expect(try node.insertAtDepth(&pfx2, 200, 0) == false); // New

    // Test overwrite
    try testing.expect(try node.insertAtDepth(&pfx1, 150, 0) == true); // Exists
}

test "ART maxDepthAndLastBits" {
    const testing = std.testing;

    // Test various prefix lengths
    const test1 = maxDepthAndLastBits(0);
    try testing.expectEqual(@as(u8, 0), test1.max_depth);
    try testing.expectEqual(@as(u8, 0), test1.last_bits);

    const test2 = maxDepthAndLastBits(8);
    try testing.expectEqual(@as(u8, 1), test2.max_depth);  // 8 >> 3 = 1
    try testing.expectEqual(@as(u8, 0), test2.last_bits);  // 8 & 7 = 0

    const test3 = maxDepthAndLastBits(12);
    try testing.expectEqual(@as(u8, 1), test3.max_depth);  // 12 >> 3 = 1
    try testing.expectEqual(@as(u8, 4), test3.last_bits);  // 12 & 7 = 4

    const test4 = maxDepthAndLastBits(24);
    try testing.expectEqual(@as(u8, 3), test4.max_depth);  // 24 >> 3 = 3
    try testing.expectEqual(@as(u8, 0), test4.last_bits);  // 24 & 7 = 0
    
    const test5 = maxDepthAndLastBits(16);
    try testing.expectEqual(@as(u8, 2), test5.max_depth);  // 16 >> 3 = 2
    try testing.expectEqual(@as(u8, 0), test5.last_bits);  // 16 & 7 = 0
}

test "ART isFringe" {
    const testing = std.testing;

    // /8 at depth 0 is a fringe (max_depth=1, depth=0 == 1-1, last_bits=0)
    try testing.expect(isFringe(0, 8));

    // /16 at depth 1 is a fringe (max_depth=2, depth=1 == 2-1, last_bits=0)
    try testing.expect(isFringe(1, 16));

    // /24 at depth 2 is a fringe (max_depth=3, depth=2 == 3-1, last_bits=0)
    try testing.expect(isFringe(2, 24));

    // /16 at depth 0 is not a fringe (depth=0 != max_depth-1=1)
    try testing.expect(!isFringe(0, 16));

    // /12 at depth 0 is not a fringe (last_bits = 4, not 0)
    try testing.expect(!isFringe(0, 12));
} 