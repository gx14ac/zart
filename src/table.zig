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
        
        /// Update or set the value at pfx with a callback function.
        /// The callback function is called with (value, ok) and returns a new value.
        ///
        /// If the pfx does not already exist, it is set with the new value.
        pub fn update(self: *Self, pfx: *const Prefix, cb: fn (V, bool) V) V {
            if (!pfx.isValid()) {
                return cb(undefined, false);
            }
            const canonical_pfx = pfx.masked();
            const ip = &canonical_pfx.addr;
            const is4 = ip.is4();
            const root_node = self.rootNodeByVersion(is4);
            const result = root_node.update(&canonical_pfx, cb);
            if (!result.was_present) {
                self.sizeUpdate(is4, 1);
            }
            return result.value;
        }
        
        /// Delete removes a pfx from the tree.
        pub fn delete(self: *Self, pfx: *const Prefix) void {
            _ = self.getAndDelete(pfx);
        }
        
        /// GetAndDelete removes a pfx from the tree and returns its value.
        pub fn getAndDelete(self: *Self, pfx: *const Prefix) ?V {
            return self.getAndDeleteInternal(pfx);
        }
        
        /// getAndDeleteInternal is the internal implementation of getAndDelete
        fn getAndDeleteInternal(self: *Self, pfx: *const Prefix) ?V {
            if (!pfx.isValid()) {
                return null;
            }
            
            // canonicalize prefix
            const canonical_pfx = pfx.masked();
            
            // values derived from pfx
            const ip = canonical_pfx.addr;
            const is4 = ip.is4();
            const root_node = self.rootNodeByVersion(is4);
            
            const deleted_val = root_node.delete(&canonical_pfx);
            if (deleted_val != null) {
                self.sizeUpdate(is4, -1);
            }
            return deleted_val;
        }
        
        /// Get gets the value at pfx.
        pub fn get(self: *const Self, pfx: *const Prefix) ?V {
            std.debug.print("GET START: pfx={s}\n", .{pfx.*});
            if (!pfx.isValid()) {
                return null;
            }
            const canonical_pfx = pfx.masked();
            const ip = &canonical_pfx.addr;
            const is4 = ip.is4();
            const root_node = self.rootNodeByVersionConst(is4);
            return root_node.get(&canonical_pfx);
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